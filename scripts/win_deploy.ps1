$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "!!! ВНИМАНИЕ: ПОЛНАЯ ЗАЧИСТКА СИСТЕМЫ !!!" -ForegroundColor Red

# 1. УБИВАЕМ ПРОЦЕССЫ
Stop-Process -Name "ollama*" -ErrorAction SilentlyContinue
Stop-Process -Name "python*" -ErrorAction SilentlyContinue
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue

# 2. УДАЛЯЕМ СОФТ
Write-Host "[1/6] Удаление Ollama, Python и Conda..." -ForegroundColor Cyan
winget uninstall -e --id Ollama.Ollama --accept-source-agreements 2>$null
winget uninstall -e --id Python.Python.3.11 --accept-source-agreements 2>$null

# 3. ЧИСТИМ ПАПКИ
$Paths = @(
    "$env:USERPROFILE\.ollama",
    "$env:USERPROFILE\.conda",
    "$env:USERPROFILE\miniconda3",
    "$env:LOCALAPPDATA\Programs\Ollama"
)
foreach ($path in $Paths) {
    if (Test-Path $path) { 
        Write-Host "Удаляю $path..." -ForegroundColor Gray
        Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue 
    }
}

Write-Host "[2/6] Подготовка чистой платформы (llama.cpp)..." -ForegroundColor Cyan
$WorkDir = "$env:USERPROFILE\llm_native"
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir }
Set-Location $WorkDir

# 4. СКАЧИВАЕМ LLAMA.CPP (CUDA 12)
# Blackwell (5070) работает через CUDA 12.x
Write-Host "[3/6] Скачивание движка llama.cpp для NVIDIA GPU..." -ForegroundColor Cyan
$ZipFile = "$WorkDir\llama_bin.zip"
$Url = "https://github.com/ggerganov/llama.cpp/releases/download/b4594/llama-b4594-bin-win-cuda-cu12.4-x64.zip"
Invoke-WebRequest -Uri $Url -OutFile $ZipFile
Expand-Archive -Path $ZipFile -DestinationPath "$WorkDir\bin" -Force
Remove-Item $ZipFile

# 5. СКАЧИВАЕМ РУССКУЮ МОДЕЛЬ (SAIGA LLAMA 3 8B) НАПРЯМУЮ
Write-Host "[4/6] Скачивание модели Saiga Llama 3 8B GGUF (5.5GB)..." -ForegroundColor Yellow
$ModelUrl = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf"
$ModelPath = "$WorkDir\saiga_llama3_8b.gguf"
if (!(Test-Path $ModelPath)) {
    Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelPath
}

# 6. ЗАПУСК API СЕРВЕРА
Write-Host "[5/6] Запуск API сервера на порту 8010..." -ForegroundColor Green
Write-Host "!!! ИНТЕРФЕЙС ОТКЛЮЧЕН. ИСПОЛЬЗУЙТЕ API (localhost:8010/v1) !!!" -ForegroundColor Cyan

# Автоматически прокидываем все слои на GPU 5070 (-ngl 99)
cd "$WorkDir\bin"
.\llama-server.exe --model "$ModelPath" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --host 0.0.0.0
