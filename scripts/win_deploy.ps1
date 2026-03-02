$ErrorActionPreference = 'SilentlyContinue'
Write-Host "--- 🚀 LLM Orchestrator: Windows Auto-Deploy ---" -ForegroundColor Cyan

# 1. Установка Ollama
if (!(Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "[1/5] Установка Ollama через winget..." -ForegroundColor Yellow
    winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 2. Запуск движка
if (!(Get-Process "ollama" -ErrorAction SilentlyContinue)) {
    Write-Host "[2/5] Запуск движка Ollama..." -ForegroundColor Yellow
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -s 5
}

# 3. Установка Python
if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[3/5] Установка Python 3.11..." -ForegroundColor Yellow
    winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 4. Загрузка модели Saiga
Write-Host "[4/5] Загрузка модели Saiga Llama 3 8B (Русская)..." -ForegroundColor Yellow
& ollama pull saiga_llama3:8b

# 5. Установка интерфейса Open WebUI
Write-Host "[5/5] Установка и запуск Open WebUI..." -ForegroundColor Yellow
& python -m pip install --upgrade pip
& pip install open-webui

Write-Host "--- ✅ ВСЁ ГОТОВО! Открываю чат... ---" -ForegroundColor Green
Start-Process "http://localhost:8080"
& open-webui serve
