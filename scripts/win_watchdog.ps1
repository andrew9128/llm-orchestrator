# LLM WATCHDOG v14.2
# On-demand lifecycle for all services (LLM, ASR, OCR, Embedding)
# Key fix: wake-proxy listens on STOPPED ports, catches requests, creates trigger
# Flow: READY -> idle -> STOPPED -> wake-proxy on port -> trigger -> LOADING -> READY
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

# =============================================================================
# HELPERS
# =============================================================================
function Log($msg) {
    $ts = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content $watchdogLog $line -ErrorAction SilentlyContinue
}

function Test-Port($port) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        return ($r.Content | ConvertFrom-Json).status
    } catch { return "down" }
}

function Get-CurrentCtx {
    if (Test-Path "$W\run.ps1") {
        $c = Get-Content "$W\run.ps1" -Raw
        if ($c -match "--ctx-size (\d+)") { return [int]$Matches[1] }
    }
    return 8192
}

function Reduce-Ctx($current) {
    $steps = @(65536, 32768, 16384, 8192, 4096, 2048)
    foreach ($s in $steps) { if ($s -lt $current) { return $s } }
    return 2048
}

function Update-CtxInRunScript($newCtx) {
    if (Test-Path "$W\run.ps1") {
        $c = Get-Content "$W\run.ps1" -Raw
        $c = $c -replace "--ctx-size \d+", "--ctx-size $newCtx"
        [System.IO.File]::WriteAllText("$W\run.ps1", $c, [System.Text.UTF8Encoding]::new($false))
    }
}

function Set-State($port, $stateVal) {
    $stateVal | Out-File "$W\state_$port.txt" -Encoding UTF8 -NoNewline
}

function Start-LLMServer {
    if (!(Test-Path "$W\run.ps1")) { Log "run.ps1 not found"; return $false }
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
    return $true
}

function Stop-LLMServer {
    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 3
    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-SpecialSvc($scriptFile, $port) {
    if (!(Test-Path $scriptFile)) { Log "[$port] Script not found: $scriptFile"; return $false }
    $log = "$W\svc_$port.log"; $err = "$W\svc_${port}_err.log"
    Start-Process "python" -ArgumentList $scriptFile -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -s 2
        if ((Test-Port $port) -eq "ok") { return $true }
    }
    Log "[$port] Did not become healthy in 30s"
    return $false
}

function Stop-SpecialSvc($port) {
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "svc_service_$port|asr_service|ocr_service|embed_service"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # Also kill any wake-proxy on this port
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "wake_proxy" -and $_.CommandLine -match "$port"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# WAKE PROXY
# Starts a tiny Python HTTP server on $port while service is STOPPED.
# Any incoming request → creates wake_PORT.trigger → returns 503
# Proxy exits when real service comes up (port re-bound by real service)
# =============================================================================
function Write-WakeProxy($port, $svcName) {
    $proxyScript = "$W\wake_proxy_$port.py"
    $triggerFile = "$W\wake_$port.trigger"
    # Use string formatting to embed values safely
    $py = @"
import socket, os, time, threading, sys

PORT = $port
TRIGGER = r'$triggerFile'
W = r'$W'
NAME = '$svcName'
state_file = os.path.join(W, f'state_{PORT}.txt')

def write_trigger():
    with open(TRIGGER, 'w') as f:
        f.write('wake')

def check_real_service():
    # Exit when real service takes over the port
    time.sleep(5)
    while True:
        try:
            import urllib.request
            r = urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health', timeout=2)
            data = r.read().decode()
            if 'ok' in data and 'wake_proxy' not in data:
                sys.exit(0)
        except Exception:
            pass
        time.sleep(3)

# Start checker thread
t = threading.Thread(target=check_real_service, daemon=True)
t.start()

# Simple raw socket server - no port conflict with real service
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(('0.0.0.0', PORT))
except OSError:
    sys.exit(0)  # Real service already on port

srv.listen(5)
srv.settimeout(120)

triggered = False

while True:
    try:
        conn, addr = srv.accept()
        try:
            data = conn.recv(4096).decode('utf-8', errors='ignore')
            if '/health' in data and not triggered:
                # Health check: return "starting"
                body = '{\"status\":\"starting\",\"msg\":\"' + NAME + ' is waking up, retry in 30s\"}'
            else:
                # Any other request: trigger wake + 503
                if not triggered:
                    write_trigger()
                    triggered = True
                body = '{\"error\":\"service starting\",\"retry_after\":30}'
            headers = f'HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'
            conn.sendall((headers + body).encode())
        except Exception:
            pass
        finally:
            conn.close()
        
        if triggered:
            # Wrote trigger, give watchdog time to start real service, then exit
            time.sleep(10)
            srv.close()
            sys.exit(0)
    except socket.timeout:
        # No requests for 2 min - exit, real service probably not needed
        srv.close()
        sys.exit(0)
    except Exception:
        sys.exit(0)
"@
    [System.IO.File]::WriteAllText($proxyScript, $py, [System.Text.UTF8Encoding]::new($false))
    return $proxyScript
}

function Start-WakeProxy($port, $svcName) {
    # Kill any existing proxy on this port
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "wake_proxy_$port"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -s 1

    $proxyScript = Write-WakeProxy $port $svcName
    $proxyLog = "$W\wake_proxy_$port.log"
    Start-Process "python" -ArgumentList $proxyScript -WindowStyle Hidden -RedirectStandardOutput $proxyLog -RedirectStandardError "$proxyLog.err"
    Start-Sleep -s 1
    Log "[$port] Wake proxy started (will catch requests and wake service)"
}

function Stop-WakeProxy($port) {
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "wake_proxy_$port"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# LOAD CONFIG
# =============================================================================
function Load-Config {
    if (Test-Path "$W\config.json") {
        try { return Get-Content "$W\config.json" -Raw | ConvertFrom-Json } catch {}
    }
    return [PSCustomObject]@{
        idleLlm=600; idleAsr=300; idleOcr=300; idleEmbed=900
        launchAsr=$false; launchOcr=$false; launchEmbed=$false
    }
}

# =============================================================================
# MAIN
# =============================================================================
Log "Watchdog v14.2 started."

$cfg = Load-Config
Log "Idle timeouts: LLM=$($cfg.idleLlm)s ASR=$($cfg.idleAsr)s OCR=$($cfg.idleOcr)s Embed=$($cfg.idleEmbed)s"

$scriptMap = @{
    8011 = "$W\asr_service.py"
    8013 = "$W\ocr_service.py"
    8014 = "$W\embed_service.py"
}
$nameMap = @{
    8010 = "LLM"
    8011 = "ASR"
    8013 = "OCR"
    8014 = "Embedding"
}
$idleMap = @{
    8010 = $cfg.idleLlm
    8011 = $cfg.idleAsr
    8013 = $cfg.idleOcr
    8014 = $cfg.idleEmbed
}

$svcPorts = @(8010)
if ($cfg.launchAsr)   { $svcPorts += 8011 }
if ($cfg.launchOcr)   { $svcPorts += 8013 }
if ($cfg.launchEmbed) { $svcPorts += 8014 }

$state      = @{}
$failCount  = @{}
$wasUp      = @{}
$lastSeen   = @{}
$serverLog  = "$W\server.log"

foreach ($port in $svcPorts) {
    $state[$port]     = "READY"
    $failCount[$port] = 0
    $wasUp[$port]     = $false
    $lastSeen[$port]  = (Get-Date)
}

$loopCount = 0

while ($true) {
    Start-Sleep -s 10
    $loopCount++

    # Reload config every 5 min
    if ($loopCount % 30 -eq 0) {
        $cfg = Load-Config
        $idleMap[8010] = $cfg.idleLlm
        $idleMap[8011] = $cfg.idleAsr
        $idleMap[8013] = $cfg.idleOcr
        $idleMap[8014] = $cfg.idleEmbed
    }

    foreach ($port in $svcPorts) {
        $cur   = $state[$port]
        $idle  = $idleMap[$port]
        $name  = $nameMap[$port]

        # ── STOPPED: watch for wake trigger (created by wake proxy or manually) ──
        if ($cur -eq "STOPPED") {
            $trigger = "$W\wake_$port.trigger"
            if (Test-Path $trigger) {
                Remove-Item $trigger -ErrorAction SilentlyContinue
                Log "[$port] Wake trigger → starting $name"

                # Stop wake proxy first so it frees the port
                Stop-WakeProxy $port
                Start-Sleep -s 2

                Set-State $port "LOADING"
                $state[$port] = "LOADING"

                if ($port -eq 8010) {
                    $ok = Start-LLMServer
                } else {
                    $ok = Start-SpecialSvc $scriptMap[$port] $port
                }

                if ($ok) {
                    $state[$port]    = "READY"
                    $failCount[$port] = 0
                    $lastSeen[$port] = (Get-Date)
                    $wasUp[$port]    = $false
                    Set-State $port "READY"
                    Log "[$port] $name is READY"
                } else {
                    $state[$port] = "STOPPED"
                    Set-State $port "STOPPED"
                    Log "[$port] $name failed to start after wake trigger"
                    Start-WakeProxy $port $name
                }
            }
            continue
        }

        # ── LOADING: wait for healthy ──
        if ($cur -eq "LOADING") {
            $h = Test-Port $port
            if ($h -eq "ok" -or $h -eq "loading model") {
                $state[$port]    = "READY"
                $failCount[$port] = 0
                $lastSeen[$port] = (Get-Date)
                $wasUp[$port]    = $true
                Set-State $port "READY"
                Log "[$port] $name READY"
            }
            continue
        }

        # ── READY: health check + idle detection ──
        $h = Test-Port $port

        if ($h -eq "ok" -or $h -eq "loading model") {
            if (!$wasUp[$port]) { Log "[$port] $name UP" }
            $wasUp[$port]    = $true
            $failCount[$port] = 0
            $lastSeen[$port] = (Get-Date)

            # Idle check for LLM: server.log last-write time is accurate
            if ($port -eq 8010 -and (Test-Path $serverLog)) {
                $idleSec = ((Get-Date) - (Get-Item $serverLog).LastWriteTime).TotalSeconds
                if ($idleSec -gt $idle) {
                    Log "[8010] LLM idle $([int]$idleSec)s > $idle s → unloading"
                    Stop-LLMServer
                    $state[8010]    = "STOPPED"
                    Set-State 8010 "STOPPED"
                    Log "[8010] LLM STOPPED. Starting wake proxy on port 8010..."
                    Start-WakeProxy 8010 "LLM"
                }
            }
            # Idle for special services: they self-exit via os._exit(0),
            # watchdog detects death in the next section
            continue
        }

        # ── Health failed ──
        $failCount[$port]++
        Log "[$port] $name health=$h fail#$($failCount[$port])"

        # Special services die on idle by design (os._exit) → mark STOPPED, start wake proxy
        if ($port -ne 8010) {
            if ($wasUp[$port] -or $failCount[$port] -ge 2) {
                Log "[$port] $name stopped (idle or crash) → STOPPED"
                $state[$port]    = "STOPPED"
                $failCount[$port] = 0
                $wasUp[$port]    = $false
                Set-State $port "STOPPED"
                Start-WakeProxy $port $name
            }
            continue
        }

        # LLM crash recovery
        if ($failCount[$port] -ge 2) {
            Log "[8010] LLM crash → restarting"
            Stop-LLMServer

            if ($failCount[$port] -ge 4) {
                $ctx = Get-CurrentCtx
                if ($ctx -gt 2048) {
                    $newCtx = Reduce-Ctx $ctx
                    Log "[8010] Reducing ctx $ctx → $newCtx"
                    Update-CtxInRunScript $newCtx
                    $failCount[$port] = 0
                }
            }

            $ok = Start-LLMServer
            if ($ok) {
                $state[$port] = "LOADING"
                $wasUp[$port] = $false
                Set-State $port "LOADING"
                Log "[8010] Restart issued, waiting..."
                Start-Sleep -s 20
            }
        }
    }
}
