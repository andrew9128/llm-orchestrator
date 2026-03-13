# Monitors LLM + optional special services (ASR / OCR / Embedding)
# Lifecycle: READY -> IDLE (timeout) -> STOPPED -> wake.trigger -> LOADING -> READY
# On crash: auto-restart with ctx reduction fallback
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

# =============================================================================
# LOGGING
# =============================================================================
function Log($msg) {
    $ts = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content $watchdogLog $line -ErrorAction SilentlyContinue
}

# =============================================================================
# HEALTH CHECK
# =============================================================================
function Test-Port($port) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        $status = ($r.Content | ConvertFrom-Json).status
        return $status
    } catch { return "down" }
}

# =============================================================================
# CTX MANAGEMENT
# =============================================================================
function Get-CurrentCtx {
    $runFile = "$W\run.ps1"
    if (Test-Path $runFile) {
        $content = Get-Content $runFile -Raw
        if ($content -match "--ctx-size (\d+)") { return [int]$Matches[1] }
    }
    return 8192
}

function Reduce-Ctx($current) {
    $steps = @(65536, 32768, 16384, 8192, 4096, 2048)
    foreach ($s in $steps) { if ($s -lt $current) { return $s } }
    return 2048
}

function Update-CtxInRunScript($newCtx) {
    $runFile = "$W\run.ps1"
    if (Test-Path $runFile) {
        $content = Get-Content $runFile -Raw
        $content = $content -replace "--ctx-size \d+", "--ctx-size $newCtx"
        [System.IO.File]::WriteAllText($runFile, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

# =============================================================================
# PROCESS MANAGEMENT
# =============================================================================
function Start-LLMServer {
    $runScript = "$W\run.ps1"
    if (!(Test-Path $runScript)) { Log "run.ps1 not found, cannot start LLM"; return $false }
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", $runScript
    return $true
}

function Stop-LLMServer {
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -s 3
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue
    }
}

function Start-SpecialService($scriptFile, $port) {
    if (!(Test-Path $scriptFile)) { return $false }
    $logFile = "$W\svc_$port.log"
    $errFile = "$W\svc_${port}_err.log"
    Start-Process "python" -ArgumentList $scriptFile -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $errFile
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -s 2
        $h = Test-Port $port
        if ($h -eq "ok") { return $true }
    }
    return $false
}

function Stop-SpecialService($port) {
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "service.py"
    } | ForEach-Object {
        $cmdl = $_.CommandLine
        if ($cmdl -match "asr_service|ocr_service|embed_service") {
            $checkPort = 0
            if ($cmdl -match "asr_service")  { $checkPort = 8011 }
            if ($cmdl -match "ocr_service")  { $checkPort = 8013 }
            if ($cmdl -match "embed_service"){ $checkPort = 8014 }
            if ($checkPort -eq $port) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# =============================================================================
# LOAD CONFIG
# =============================================================================
function Load-Config {
    $cfgFile = "$W\config.json"
    if (Test-Path $cfgFile) {
        try { return Get-Content $cfgFile -Raw | ConvertFrom-Json }
        catch {}
    }
    # defaults
    return [PSCustomObject]@{
        mode        = "chat"
        idleLlm     = 600
        idleAsr     = 300
        idleOcr     = 300
        idleEmbed   = 900
        launchAsr   = $false
        launchOcr   = $false
        launchEmbed = $false
    }
}

# =============================================================================
# WRITE STATE FILE
# =============================================================================
function Set-State($port, $state) {
    $state | Out-File "$W\state_$port.txt" -Encoding UTF8 -NoNewline
}

# =============================================================================
# MAIN LOOP
# =============================================================================
Log "Watchdog started. On-demand lifecycle enabled."

$cfg = Load-Config
Log "Mode: $($cfg.mode) | LLM idle: $($cfg.idleLlm)s"

# Per-service state tracking
$svcPorts = @(8010)
if ($cfg.launchAsr)   { $svcPorts += 8011 }
if ($cfg.launchOcr)   { $svcPorts += 8013 }
if ($cfg.launchEmbed) { $svcPorts += 8014 }

$scriptMap = @{
    8011 = "$W\asr_service.py"
    8013 = "$W\ocr_service.py"
    8014 = "$W\embed_service.py"
}
$idleMap = @{
    8010 = $cfg.idleLlm
    8011 = $cfg.idleAsr
    8013 = $cfg.idleOcr
    8014 = $cfg.idleEmbed
}

# Track per-port state
$state        = @{}   # "READY" | "STOPPED" | "LOADING"
$failCount    = @{}   # consecutive health failures
$wasRunning   = @{}   # was previously up
$lastSeen     = @{}   # last time health returned ok (for idle detection)
$serverLog    = "$W\server.log"

foreach ($port in $svcPorts) {
    $state[$port]      = "READY"
    $failCount[$port]  = 0
    $wasRunning[$port] = $false
    $lastSeen[$port]   = (Get-Date)
}

$loopCount = 0

while ($true) {
    Start-Sleep -s 10
    $loopCount++

    # Reload config occasionally to pick up changes
    if ($loopCount % 30 -eq 0) {
        $cfg = Load-Config
        foreach ($port in $svcPorts) { $idleMap[$port] = $cfg.idleLlm }
        $idleMap[8011] = $cfg.idleAsr
        $idleMap[8013] = $cfg.idleOcr
        $idleMap[8014] = $cfg.idleEmbed
    }

    foreach ($port in $svcPorts) {
        $currentState = $state[$port]
        $idle         = $idleMap[$port]

        # ---- STOPPED state: check wake trigger ----
        if ($currentState -eq "STOPPED") {
            $triggerFile = "$W\wake_$port.trigger"
            if (Test-Path $triggerFile) {
                Remove-Item $triggerFile -ErrorAction SilentlyContinue
                Log "[$port] Wake trigger detected - restarting service"
                $state[$port] = "LOADING"
                Set-State $port "LOADING"
                if ($port -eq 8010) {
                    $ok = Start-LLMServer
                    if (!$ok) { $state[$port] = "STOPPED"; continue }
                } else {
                    $scriptFile = $scriptMap[$port]
                    $ok = Start-SpecialService $scriptFile $port
                    if (!$ok) { Log "[$port] Failed to restart service"; continue }
                }
                $state[$port]      = "READY"
                $failCount[$port]  = 0
                $lastSeen[$port]   = (Get-Date)
                $wasRunning[$port] = $false
                Set-State $port "READY"
                Log "[$port] Service restarted after wake trigger"
            }
            # Also check: if LLM is STOPPED but someone sent a request,
            # server.log will show a recent write (attempt to connect)
            if ($port -eq 8010 -and (Test-Path $serverLog)) {
                $logAge = ((Get-Date) - (Get-Item $serverLog).LastWriteTime).TotalSeconds
                if ($logAge -lt 15) {
                    # Recent write could mean a connection attempt - auto-wake LLM
                    $health = Test-Port 8010
                    if ($health -eq "down") {
                        Log "[8010] Recent server.log activity while STOPPED - auto-waking LLM"
                        $state[8010] = "LOADING"
                        Set-State 8010 "LOADING"
                        $ok = Start-LLMServer
                        if ($ok) {
                            $state[8010]     = "READY"
                            $failCount[8010] = 0
                            $lastSeen[8010]  = (Get-Date)
                            Set-State 8010 "READY"
                            Log "[8010] LLM auto-woken from recent activity"
                        }
                    }
                }
            }
            continue
        }

        # ---- LOADING state: wait for health ----
        if ($currentState -eq "LOADING") {
            $h = Test-Port $port
            if ($h -eq "ok" -or $h -eq "loading model") {
                $state[$port]      = "READY"
                $failCount[$port]  = 0
                $lastSeen[$port]   = (Get-Date)
                $wasRunning[$port] = $true
                Set-State $port "READY"
                Log "[$port] Service is now READY"
            }
            continue
        }

        # ---- READY state: health check + idle detection ----
        $h = Test-Port $port

        if ($h -eq "ok" -or $h -eq "loading model") {
            if (!$wasRunning[$port]) { Log "[$port] Service UP (status: $h)" }
            $wasRunning[$port] = $true
            $failCount[$port]  = 0
            $lastSeen[$port]   = (Get-Date)

            # Check idle: use server.log last-write for LLM (more accurate than health polls)
            if ($port -eq 8010 -and (Test-Path $serverLog)) {
                $idleSeconds = ((Get-Date) - (Get-Item $serverLog).LastWriteTime).TotalSeconds
                if ($idleSeconds -gt $idle) {
                    Log "[8010] LLM idle for $([int]$idleSeconds)s (timeout=$idle s) - unloading"
                    Stop-LLMServer
                    $state[8010] = "STOPPED"
                    Set-State 8010 "STOPPED"
                    Log "[8010] LLM STOPPED - VRAM released. Will restart on wake.trigger or activity."
                }
            } elseif ($port -ne 8010) {
                # Special services: idle tracked by their own Python watcher (os._exit(0))
                # Watchdog detects death and marks STOPPED
            }
            continue
        }

        # ---- Health failed ----
        if ($state[$port] -eq "STOPPED") { continue }  # expected, skip

        $failCount[$port]++
        Log "[$port] health=$h fail #$($failCount[$port])"

        if ($failCount[$port] -ge 2) {
            # Check if this is idle-expected death (special services kill themselves)
            if ($port -ne 8010 -and $wasRunning[$port]) {
                Log "[$port] Service stopped (idle self-exit or crash) - marking STOPPED"
                $state[$port] = "STOPPED"
                Set-State $port "STOPPED"
                $failCount[$port] = 0
                $wasRunning[$port] = $false
                continue
            }

            # LLM crash - restart
            if ($port -eq 8010) {
                Log "[8010] Restarting LLM..."
                Stop-LLMServer

                if ($failCount[$port] -ge 4) {
                    $ctx = Get-CurrentCtx
                    if ($ctx -gt 2048) {
                        $newCtx = Reduce-Ctx $ctx
                        Log "[8010] Reducing ctx: $ctx -> $newCtx"
                        Update-CtxInRunScript $newCtx
                        $failCount[$port] = 0
                    } else {
                        Log "[8010] ctx already at minimum (2048). Will still retry."
                    }
                }

                $ok = Start-LLMServer
                if ($ok) {
                    $state[$port]      = "LOADING"
                    $wasRunning[$port] = $false
                    Set-State $port "LOADING"
                    Log "[8010] Restart issued. Waiting for READY..."
                    Start-Sleep -s 20
                }
            }
        }
    }
}
