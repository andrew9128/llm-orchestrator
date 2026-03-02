$ErrorActionPreference = 'Stop'
# Отключаем прогресс-бар PowerShell, который вешает систему при больших загрузках
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "!!! ПОЛНАЯ ЗАЧИСТКА И УСТАНОВКА LLAMA.CPP !!!" -ForegroundColor Red

# 1. ОСТАНОВКА И УДАЛЕНИЕ СТАРОГО
Stop-Process -Name "ollama*" -ErrorAction SilentlyContinue
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue

$Paths = @("$env:USERPROFILE\.ollama", "$env:LOCALAPPDATA\Programs\Ollama")
foreach ($path in $Paths) { if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue } }

# 2. ПОДГОТОВКА ПАПОК
$WorkDir = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$WorkDir\bin")) { New-Item -ItemType Directory -Path "$WorkDir\bin" -Force }
Set-Location $WorkDir

# 3. СКАЧИВАЕМ ДВИЖЕК (если нет)
if (!(Test-Path "$WorkDir\bin\llama-server.exe")) {
    Write-Host "[1/3] Скачивание движка llama.cpp (CUDA 12)..." -ForegroundColor Cyan
    $ZipFile = "$WorkDir\llama_bin.zip"
    $LlamaUrl = "https://github.com/ggerganov/llama.cpp/releases/download/b4594/llama-b4594-bin-win-cuda-cu12.4-x64.zip"
    # Используем curl.exe для скорости и стабильности
    curl.exe -L "$LlamaUrl" -o "$ZipFile"
    Expand-Archive -Path $ZipFile -DestinationPath "$WorkDir\bin" -Force
    Remove-Item $ZipFile
}

# 4. СКАЧИВАЕМ МОДЕЛЬ (САМЫЙ ВАЖНЫЙ ЭТАП)
$ModelPath = "$WorkDir\saiga_llama3_8b.gguf"
if (!(Test-Path $ModelPath)) {
    Write-Host "[2/3] Скачивание Saiga Llama 3 8B (5.5GB). Пожалуйста, подождите..." -ForegroundColor Yellow
    $ModelUrl = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf"
    # curl.exe покажет прогресс в консоли и не упадет по таймауту
    curl.exe -L "$ModelUrl" -o "$ModelPath"
}

# 5. ЗАПУСК API
Write-Host "[3/3] Запуск API сервера на порту 8010..." -ForegroundColor Green
Write-Host "Для проверки в новом окне: curl http://localhost:8010/v1/models" -ForegroundColor Gray

cd "$WorkDir\bin"
# n-gpu-layers 99 выносит всё на твою RTX 5070
.\llama-server.exe --model "$ModelPath" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --host 0.0.0.0
