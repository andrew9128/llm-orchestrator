$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "--- LLM Orchestrator v9.0 (RTX 5060 Optimized) ---" -ForegroundColor Cyan

# 1. ПАПКИ
$W = "$env:USERPROFILE\llm_native"
$B = "$W\bin"; $M = "$W\models"
if (!(Test-Path $B)) { New-Item -ItemType Directory -Path $B -Force | Out-Null }
if (!(Test-Path $M)) { New-Item -ItemType Directory -Path $M -Force | Out-Null }

# 2. ДВИЖОК (CUDA 12.4 для Blackwell/50-й серии)
if (!(Test-Path "$B\llama-server.exe")) {
    Write-Host "Downloading Engine..." -ForegroundColor Yellow
    $tag = "b4594"
    $url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    curl.exe -L "$url" -o "$W\l.zip"
    Expand-Archive -Path "$W\l.zip" -DestinationPath "$B" -Force
    Remove-Item "$W\l.zip"
}

# 3. МОДЕЛЬ (Saiga 8B - 5.5GB)
if (!(Test-Path "$M\saiga.gguf") -or (Get-Item "$M\saiga.gguf").Length -lt 4GB) {
    Write-Host "Downloading Model (Saiga 8B)... This takes 5-10 mins." -ForegroundColor Yellow
    Import-Module BitsTransfer
    # BITS — самый надежный способ в Windows для 5ГБ+ файлов
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination "$M\saiga.gguf" -Priority High
}

# 4. НАСТРОЙКА ДЛЯ 8GB VRAM (RTX 5060)
# --cache-type-kv fp8_e5m2 сжимает память в 2 раза.
# --device 1 выбирает твою вторую карту (RTX 5060), игнорируя старую 1080.
$cmd = "cd /d `"$B`" `n .\llama-server.exe --model `"$M\saiga.gguf`" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv fp8_e5m2 --host 0.0.0.0 --device 1 --log-disable"
$cmd | Out-File "$W\run.bat" -Encoding ascii

# 5. ЗАПУСК
Write-Host "Starting Background Server on GPU 1 (RTX 5060)..." -ForegroundColor Green
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
Start-Process "cmd.exe" -ArgumentList "/c `"$W\run.bat`"" -WindowStyle Hidden

Write-Host "DONE! API: http://localhost:8010/v1" -ForegroundColor Green
