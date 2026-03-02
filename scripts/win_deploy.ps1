$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- Smart LLM Orchestrator v6.2 (8GB VRAM Optimized) ---" -ForegroundColor Cyan

# 1. Cleanup
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 2. BITS Downloader
function Download-File-Bits($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) {
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High -DisplayName "LLM_Download"
}

# 3. Engine (CUDA 12.4 for Blackwell/Ampere)
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
Download-File-Bits $bin_url "$W\llama.zip"
if (Test-Path "$W\llama.zip") {
    Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 4. Model (Saiga 8B GGUF)
$model_url = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf"
Download-File-Bits $model_url "$W\models\saiga.gguf"

# 5. Optimization for 8GB VRAM (RTX 5060)
# Use q4_0 KV-cache to fit 16k context into 8GB memory safely.
$start_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$W\models\saiga.gguf' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable"
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. Background Task Setup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Native-Server" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- INSTALLATION COMPLETE ---" -ForegroundColor Green
Write-Host "API Endpoint: http://localhost:8010/v1"
Write-Host "The server is running hidden in the background."

# Initial start
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
