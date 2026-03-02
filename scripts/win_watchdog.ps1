# LLM WATCHDOG - runs in background, restarts server if it crashes
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

function Log($msg) {
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content $watchdogLog $line
}

function Start-LLMServer($runScript) {
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", $runScript
}

function Test-Health {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $h = ($r.Content | ConvertFrom-Json).status
        return $h
    } catch { return "down" }
}

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

Log "Watchdog started. Monitoring http://localhost:8010/health"

$failCount = 0
$wasRunning = $false

while ($true) {
    Start-Sleep -s 10
    $status = Test-Health

    if ($status -eq "ok" -or $status -eq "loading model") {
        if (!$wasRunning) { Log "Server is UP (status: $status)" }
        $wasRunning = $true
        $failCount = 0
        continue
    }

    # Server is down
    $failCount++
    Log "Server DOWN (status: $status) - fail #$failCount"

    if ($failCount -ge 2) {
        Log "Restarting server..."
        Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -s 2

        $runScript = "$W\run.ps1"
        if (!(Test-Path $runScript)) { Log "run.ps1 not found, cannot restart"; continue }

        # If crashed more than once in a row - reduce context
        if ($failCount -ge 4) {
            $ctx = Get-CurrentCtx
            $newCtx = Reduce-Ctx $ctx
            Log "Reducing context: $ctx -> $newCtx"
            $content = Get-Content $runScript -Raw
            $content = $content -replace "--ctx-size \d+", "--ctx-size $newCtx"
            [System.IO.File]::WriteAllText($runScript, $content, [System.Text.UTF8Encoding]::new($false))
            $failCount = 0
        }

        Start-LLMServer $runScript
        Log "Restart issued. Waiting 20s..."
        Start-Sleep -s 20
        $wasRunning = $false
    }
}
