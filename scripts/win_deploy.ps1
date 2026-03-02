$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- LLM Orchestrator: Windows Auto-Deploy ---" -ForegroundColor Cyan

# 1. Install Ollama
if (!(Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "[1/5] Installing Ollama via winget..." -ForegroundColor Yellow
    winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 2. Start Engine
if (!(Get-Process "ollama" -ErrorAction SilentlyContinue)) {
    Write-Host "[2/5] Starting Ollama engine..." -ForegroundColor Yellow
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -s 5
}

# 3. Install Python
if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[3/5] Installing Python 3.11..." -ForegroundColor Yellow
    winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# 4. Pull Model
Write-Host "[4/5] Downloading model: Saiga Llama 3 8B..." -ForegroundColor Yellow
& ollama pull saiga_llama3:8b

# 5. Install UI
Write-Host "[5/5] Installing Open WebUI..." -ForegroundColor Yellow
& python -m pip install --upgrade pip
& pip install open-webui

Write-Host "--- ALL DONE! Opening browser... ---" -ForegroundColor Green
Start-Process "http://localhost:8080"
& open-webui serve
