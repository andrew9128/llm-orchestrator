$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- LLM Orchestrator v6.4 (8GB VRAM Fix) ---" -ForegroundColor Cyan

# 1. Folders
$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 2. BITS Downloader
function DL-File($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { return }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High
}

# 3. Engine (CUDA 12.4 for Blackwell/Ampere)
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
DL-File $bin_url "$W\llama.zip"
if (Test-Path "$W\llama.zip") {
    Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 4. Model (Saiga 8B GGUF) - FIXED URL (Capital K)
$model_url = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf"
DL-File $model_url "$W\models\saiga.gguf"

# 5. Optimization for 8GB VRAM (RTX 5060)
# Force q4_0 cache to fit 16k context into 8GB memory safely.
$start_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$W\models\saiga.gguf' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable"
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. Task Setup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Native-API" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "DONE! API: http://localhost:8010/v1" -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
