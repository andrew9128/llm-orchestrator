$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ВЕРСИЯ 7.0 - Blackwell Dual-GPU Edition
Write-Host "--- Smart LLM Orchestrator v7.0 ---" -ForegroundColor Cyan

# 1. ПОЛНАЯ ОЧИСТКА ПРЕДЫДУЩИХ ПОПЫТОК
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

# 2. ФУНКЦИЯ ЗАГРУЗКИ ЧЕРЕЗ BITS (Самый надежный метод)
function Download-File-Safe($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { return }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High
}

# 3. СКАЧИВАЕМ ДВИЖОК (CUDA 12.4 для RTX 5060)
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
Download-File-Safe $bin_url "$W\llama.zip"
Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\llama.zip"

# 4. СКАЧИВАЕМ МОДЕЛЬ
Download-File-Safe "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" "$W\models\saiga.gguf"

# 5. ГЕНЕРАЦИЯ ФАЙЛА ЗАПУСКА СПЕЦИАЛЬНО ДЛЯ GPU 1 (RTX 5060)
# Мы используем --device 1, чтобы сервер не пытался занять старую GTX 1080
$ModelPath = "$W\models\saiga.gguf"
$LogFile = "$W\server.log"

$start_cmd = @"
Set-Location '$W\bin'
# Устанавливаем путь к собственным DLL, чтобы не было 'молчаливых' вылетов
`$env:PATH = '$W\bin;' + `$env:PATH
# Принудительно выбираем вторую карту (RTX 5060)
`$env:CUDA_VISIBLE_DEVICES = '1'
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable > '$LogFile' 2>&1
"@
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. ЗАПУСК
Write-Host "Starting server on GPU 1 (RTX 5060). Check http://localhost:8010/v1" -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"
