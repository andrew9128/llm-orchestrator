$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "--- LLM Orchestrator v9.1 (Vulkan Stability Fix) ---" -ForegroundColor Cyan

# 1. ПАПКИ И ЗАЧИСТКА
$W = "$env:USERPROFILE\llm_native"
$B = "$W\bin"; $M = "$W\models"
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
if (Test-Path $B) { Remove-Item -Recurse -Force $B }
New-Item -ItemType Directory -Path $B -Force | Out-Null
if (!(Test-Path $M)) { New-Item -ItemType Directory -Path $M -Force | Out-Null }

# 2. УСТАНОВКА БИБЛИОТЕК MICROSOFT (на случай ошибки VCRUNTIME)
Write-Host "Installing Microsoft Runtimes..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

# 3. ДВИЖОК (VULKAN EDITION - НЕ ТРЕБУЕТ CUDA DLL)
Write-Host "Downloading Vulkan Engine (Compatible with Blackwell)..." -ForegroundColor Yellow
$tag = "b4594"
$url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
curl.exe -L "$url" -o "$W\l.zip"
Expand-Archive -Path "$W\l.zip" -DestinationPath "$B" -Force
Remove-Item "$W\l.zip"

# 4. МОДЕЛЬ (Если еще не скачана)
if (!(Test-Path "$M\saiga.gguf") -or (Get-Item "$M\saiga.gguf").Length -lt 4GB) {
    Write-Host "Downloading Model (Saiga 8B)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination "$M\saiga.gguf" -Priority High
}

# 5. НАСТРОЙКА ДЛЯ 8GB VRAM (RTX 5060)
# --cache-type-kv q4_0 сжимает контекст в 4 раза, чтобы 16к влезло в 8ГБ.
# --device 1 выбирает твою RTX 5060.
$cmd = "cd /d `"$B`" `n .\llama-server.exe --model `"$M\saiga.gguf`" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --device 1 --log-disable"
$cmd | Out-File "$W\run.bat" -Encoding ascii

# 6. ЗАПУСК
Write-Host "Starting Background Server on RTX 5060..." -ForegroundColor Green
Start-Process "cmd.exe" -ArgumentList "/c `"$W\run.bat`"" -WindowStyle Hidden

Write-Host "DONE! API is starting at http://localhost:8010/v1" -ForegroundColor Green
Write-Host "Check in 30 seconds: curl http://localhost:8010/v1/models"
