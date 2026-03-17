# LLM WATCHDOG v14.4
# Monitors all services, restarts on crash, wake-proxy forwards original request after startup
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

function Log($msg) {
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Add-Content $watchdogLog $line
}

# Read config written by win_deploy.ps1
$cfg = $null
if (Test-Path "$W\config.json") {
    try { $cfg = Get-Content "$W\config.json" -Raw | ConvertFrom-Json } catch {}
}
$IDLE_LLM   = if ($cfg -and $cfg.idleLlm)   { $cfg.idleLlm }   else { 600 }
$IDLE_ASR   = if ($cfg -and $cfg.idleAsr)   { $cfg.idleAsr }   else { 300 }
$IDLE_OCR   = if ($cfg -and $cfg.idleOcr)   { $cfg.idleOcr }   else { 300 }
$IDLE_EMBED = if ($cfg -and $cfg.idleEmbed) { $cfg.idleEmbed } else { 900 }
$launchOcr   = $cfg -and $cfg.launchOcr
$launchEmbed = $cfg -and $cfg.launchEmbed
$launchAsr   = $cfg -and $cfg.launchAsr

Log "Watchdog v14.4 started."
Log ("Idle timeouts: LLM=" + $IDLE_LLM + "s ASR=" + $IDLE_ASR + "s OCR=" + $IDLE_OCR + "s Embed=" + $IDLE_EMBED + "s")

# =============================================================================
# HELPERS
# =============================================================================
function Get-ServiceStatus($port) {
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://localhost:$port/health")
        $req.Timeout = 3000; $req.Method = "GET"
        try {
            $resp = $req.GetResponse()
            $sr = [System.IO.StreamReader]::new($resp.GetResponseStream())
            $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return ($body | ConvertFrom-Json -EA SilentlyContinue).status
        } catch [System.Net.WebException] {
            $wr = $_.Exception.Response
            if ($wr) {
                $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                $b2 = $sr2.ReadToEnd(); $sr2.Close()
                return ($b2 | ConvertFrom-Json -EA SilentlyContinue).status
            }
            return "down"
        }
    } catch { return "down" }
}

function Wait-ServiceReady($port, $timeoutSec) {
    $t = 0
    while ($t -lt $timeoutSec) {
        Start-Sleep -s 2; $t += 2
        $st = Get-ServiceStatus $port
        if ($st -eq "ok") { return $true }
        if ($st -and $st -ne "loading" -and $st -ne "down") { return $false }
    }
    return $false
}

function Start-PythonService($scriptPath, $logPath) {
    $errLog = $logPath -replace "\.log$", "_err.log"
    Start-Process "python" -ArgumentList $scriptPath -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errLog
}

function Forward-Request($port, $method, $path, $body, $contentType) {
    # Forward original request to the now-running service
    try {
        $uri = "http://localhost:$port$path"
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = $method
        $req.Timeout = 120000
        if ($contentType) { $req.ContentType = $contentType }
        if ($body -and $body.Length -gt 0) {
            $req.ContentLength = $body.Length
            $stream = $req.GetRequestStream()
            $stream.Write($body, 0, $body.Length)
            $stream.Close()
        }
        try {
            $resp = $req.GetResponse()
            $sr = [System.IO.StreamReader]::new($resp.GetResponseStream())
            $rb = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return @{ code = 200; body = $rb; ct = $resp.ContentType }
        } catch [System.Net.WebException] {
            $wr = $_.Exception.Response
            if ($wr) {
                $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                $rb2 = $sr2.ReadToEnd(); $sr2.Close()
                return @{ code = [int]$wr.StatusCode; body = $rb2; ct = "application/json" }
            }
            return @{ code = 503; body = '{"error":"service unavailable"}'; ct = "application/json" }
        }
    } catch {
        return @{ code = 500; body = '{"error":"forward failed"}'; ct = "application/json" }
    }
}

# =============================================================================
# WAKE PROXY - listens on a port, wakes service, waits, forwards request
# =============================================================================
function Start-WakeProxy($proxyPort, $targetPort, $serviceName, $startScript, $startLog, $stateFile) {
    # Run in a background job so watchdog loop continues
    $scriptBlock = {
        param($proxyPort, $targetPort, $serviceName, $startScript, $startLog, $stateFile, $W, $watchdogLog)

        function LogP($msg) {
            $ts = Get-Date -Format "HH:mm:ss"
            Add-Content $watchdogLog "[$ts] [$serviceName] $msg"
        }

        $listener = $null
        try {
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add("http://+:$proxyPort/")
            $listener.Start()
            LogP "Wake proxy listening on :$proxyPort"

            while ($listener.IsListening) {
                $ctx = $null
                try { $ctx = $listener.GetContext() } catch { break }

                LogP "Wake trigger -> starting $serviceName"
                $errLog = $startLog -replace "\.log$", "_err.log"
                Start-Process "python" -ArgumentList $startScript -WindowStyle Hidden `
                    -RedirectStandardOutput $startLog -RedirectStandardError $errLog
                "STARTING" | Out-File $stateFile -Encoding UTF8 -NoNewline

                # Wait up to 5 min for service to become ready
                $ready = $false
                $elapsed = 0
                while ($elapsed -lt 300) {
                    Start-Sleep -s 2; $elapsed += 2
                    try {
                        $hReq = [System.Net.HttpWebRequest]::Create("http://localhost:$targetPort/health")
                        $hReq.Timeout = 3000; $hReq.Method = "GET"
                        try {
                            $hResp = $hReq.GetResponse()
                            $hSr = [System.IO.StreamReader]::new($hResp.GetResponseStream())
                            $hBody = $hSr.ReadToEnd(); $hSr.Close(); $hResp.Close()
                            $hSt = ($hBody | ConvertFrom-Json -EA SilentlyContinue).status
                        } catch [System.Net.WebException] {
                            $hWr = $_.Exception.Response
                            if ($hWr) {
                                $hSr2 = [System.IO.StreamReader]::new($hWr.GetResponseStream())
                                $hSt = ($hSr2.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                                $hSr2.Close()
                            } else { $hSt = "down" }
                        }
                        if ($hSt -eq "ok") { $ready = $true; break }
                    } catch {}
                }

                if ($ready) {
                    LogP "$serviceName is READY, forwarding request"
                    "READY" | Out-File $stateFile -Encoding UTF8 -NoNewline

                    # Read original request body
                    $origBody = $null
                    try {
                        $origLen = $ctx.Request.ContentLength64
                        if ($origLen -gt 0) {
                            $origBody = [byte[]]::new($origLen)
                            $ctx.Request.InputStream.Read($origBody, 0, $origLen) | Out-Null
                        }
                    } catch {}

                    # Forward to actual service
                    $fwdUrl = "http://localhost:$targetPort" + $ctx.Request.Url.PathAndQuery
                    try {
                        $fwdReq = [System.Net.HttpWebRequest]::Create($fwdUrl)
                        $fwdReq.Method = $ctx.Request.HttpMethod
                        $fwdReq.Timeout = 120000
                        $fwdReq.ContentType = $ctx.Request.ContentType
                        if ($origBody -and $origBody.Length -gt 0) {
                            $fwdReq.ContentLength = $origBody.Length
                            $fwdStream = $fwdReq.GetRequestStream()
                            $fwdStream.Write($origBody, 0, $origBody.Length)
                            $fwdStream.Close()
                        }
                        try {
                            $fwdResp = $fwdReq.GetResponse()
                            $fwdSr = [System.IO.StreamReader]::new($fwdResp.GetResponseStream())
                            $fwdBody = [System.Text.Encoding]::UTF8.GetBytes($fwdSr.ReadToEnd())
                            $fwdSr.Close(); $fwdResp.Close()
                            $ctx.Response.StatusCode = 200
                            $ctx.Response.ContentType = "application/json"
                            $ctx.Response.ContentLength64 = $fwdBody.Length
                            $ctx.Response.OutputStream.Write($fwdBody, 0, $fwdBody.Length)
                        } catch [System.Net.WebException] {
                            $fwdWr = $_.Exception.Response
                            $fwdCode = if ($fwdWr) { [int]$fwdWr.StatusCode } else { 503 }
                            $fwdErrBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"service error"}')
                            $ctx.Response.StatusCode = $fwdCode
                            $ctx.Response.ContentLength64 = $fwdErrBytes.Length
                            $ctx.Response.OutputStream.Write($fwdErrBytes, 0, $fwdErrBytes.Length)
                        }
                    } catch {
                        $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"forward error"}')
                        $ctx.Response.StatusCode = 500
                        $ctx.Response.ContentLength64 = $errBytes.Length
                        $ctx.Response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                    }
                } else {
                    LogP "$serviceName failed to start in time"
                    "STOPPED" | Out-File $stateFile -Encoding UTF8 -NoNewline
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"service failed to start"}')
                    $ctx.Response.StatusCode = 503
                    $ctx.Response.ContentLength64 = $errBytes.Length
                    $ctx.Response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                }

                try { $ctx.Response.OutputStream.Close() } catch {}

                # Stop proxy - watchdog will create new one next time service goes idle
                $listener.Stop()
                break
            }
        } catch {
            LogP ("Wake proxy error: " + $_.Exception.Message)
        } finally {
            if ($listener -and $listener.IsListening) { try { $listener.Stop() } catch {} }
        }
    }

    Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
        $proxyPort, $targetPort, $serviceName, $startScript, $startLog, $stateFile, $W, $watchdogLog
    ) | Out-Null
}

# =============================================================================
# SERVICE DEFINITIONS
# =============================================================================
$services = [ordered]@{}
$services[8010] = @{
    name      = "LLM"
    idleTime  = $IDLE_LLM
    type      = "llm"
    lastSeen  = [datetime]::Now
    wasUp     = $false
    failCount = 0
    proxyPort = $null
}
if ($launchOcr) {
    $services[8013] = @{
        name      = "OCR"
        idleTime  = $IDLE_OCR
        type      = "python"
        script    = "$W\ocr_service.py"
        log       = "$W\ocr.log"
        state     = "$W\state_8013.txt"
        lastSeen  = [datetime]::Now
        wasUp     = $false
        failCount = 0
        proxyPort = $null
    }
}
if ($launchEmbed) {
    $services[8014] = @{
        name      = "Embedding"
        idleTime  = $IDLE_EMBED
        type      = "python"
        script    = "$W\embed_service.py"
        log       = "$W\embed.log"
        state     = "$W\state_8014.txt"
        lastSeen  = [datetime]::Now
        wasUp     = $false
        failCount = 0
        proxyPort = $null
    }
}
if ($launchAsr) {
    $services[8011] = @{
        name      = "ASR"
        idleTime  = $IDLE_ASR
        type      = "python"
        script    = "$W\asr_service.py"
        log       = "$W\asr.log"
        state     = "$W\state_8011.txt"
        lastSeen  = [datetime]::Now
        wasUp     = $false
        failCount = 0
        proxyPort = $null
    }
}

# Wake proxy ports: service port -> proxy port (offset +40)
$wakeProxyMap = @{ 8010 = 8050; 8011 = 8051; 8013 = 8053; 8014 = 8054 }

# =============================================================================
# MAIN LOOP
# =============================================================================
while ($true) {
    Start-Sleep -s 10

    # Clean up finished jobs to avoid accumulation
    Get-Job -State Completed -EA SilentlyContinue | Remove-Job -EA SilentlyContinue

    foreach ($port in @($services.Keys)) {
        $svc = $services[$port]
        $st = Get-ServiceStatus $port

        if ($st -eq "ok" -or $st -eq "loading model" -or $st -eq "loading") {
            if (-not $svc.wasUp) { Log ("[" + $svc.name + "] UP") }
            $svc.wasUp = $true
            $svc.failCount = 0
            $svc.lastSeen = [datetime]::Now
            $svc.proxyPort = $null

            # Check idle timeout - unload if idle too long
            $idleSec = ([datetime]::Now - $svc.lastSeen).TotalSeconds
            # (lastSeen is updated by the service itself via last_req; we just track uptime here)
            continue
        }

        if (-not $svc.wasUp) { continue }  # never came up, skip

        # Service went down
        $svc.failCount++
        $svc.wasUp = $false

        if ($svc.type -eq "llm") {
            Log ("[" + $svc.name + "] DOWN (fail " + $svc.failCount + ") - restarting")
            Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -s 2
            if (Test-Path "$W\run.ps1") {
                if ($svc.failCount -ge 4) {
                    $ctx2 = 8192
                    if ((Get-Content "$W\run.ps1" -Raw) -match "--ctx-size (\d+)") { $ctx2 = [int]$Matches[1] }
                    $newCtx2 = $ctx2; $steps = @(32768,16384,8192,4096,2048)
                    foreach ($s2 in $steps) { if ($s2 -lt $ctx2) { $newCtx2 = $s2; break } }
                    Log ("[LLM] Reducing ctx: " + $ctx2 + " -> " + $newCtx2)
                    $rc = Get-Content "$W\run.ps1" -Raw
                    $rc = $rc -replace "--ctx-size \d+", "--ctx-size $newCtx2"
                    [System.IO.File]::WriteAllText("$W\run.ps1", $rc, [System.Text.UTF8Encoding]::new($false))
                    $svc.failCount = 0
                }
                Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
                Log "[LLM] Restart issued"
            }
        } else {
            # Python service went idle or crashed - set STOPPED, start wake proxy
            Log ("[" + $svc.name + "] stopped -> STOPPED, starting wake proxy on :" + $wakeProxyMap[$port])
            "STOPPED" | Out-File $svc.state -Encoding UTF8 -NoNewline

            $proxyPort = $wakeProxyMap[$port]

            # Kill anything on proxy port first
            try {
                $conn2 = Get-NetTCPConnection -LocalPort $proxyPort -EA SilentlyContinue | Where-Object State -eq "Listen" | Select-Object -First 1
                if ($conn2 -and $conn2.OwningProcess -gt 4) { Stop-Process -Id $conn2.OwningProcess -Force -EA SilentlyContinue }
            } catch {}
            Start-Sleep -s 1

            Start-WakeProxy $proxyPort $port $svc.name $svc.script $svc.log $svc.state
            $svc.proxyPort = $proxyPort
            Log ("[" + $svc.name + "] Wake proxy started :" + $proxyPort + " -> :" + $port)
        }
    }
}
