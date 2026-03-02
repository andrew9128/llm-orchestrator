$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- Smart LLM Orchestrator v7.6 (Blackwell Stabilizer) ---" -ForegroundColor Cyan

# 1. ЧИСТКА
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null

# 2. ИСПРАВЛЕННАЯ УСТАНОВКА VCREDIST
Write-Host "Installing Microsoft Visual C++ Runtime..." -ForegroundColor Yellow
# Используем --silent вместо --quiet
winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

function Download-Safe($url, $out, $minSize) {
    if ((Test-Path $out) -and ((Get-Item $out).Length -gt $minSize)) { return }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High
}

# 3. ДВИЖОК VULKAN
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
Download-Safe $bin_url "$W\llama.zip" 10MB
Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force

# 4. МОДЕЛЬ
Download-Safe "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" "$W\models\saiga.gguf" 4000MB

# 5. КОМАНДА ЗАПУСКА (Специально для GPU 1)
$ModelPath = "$W\models\saiga.gguf"
$LogFile = "$W\server.log"
# Добавляем --device 1 для Vulkan, чтобы выбрать RTX 5060
$start_cmd = @"
Set-Location '$W\bin'
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 8192 --cache-type-kv q4_0 --host 0.0.0.0 --device 1 --log-disable > '$LogFile' 2>&1
"@
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. ЗАПУСК
Write-Host "Starting server on RTX 5060 (Vulkan)..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"

Start-Sleep -Seconds 10
if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "SUCCESS: API IS ALIVE! http://localhost:8010/v1" -ForegroundColor Green
} else {
    Write-Host "ERROR: Server failed to start. Check log below:" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile }
}
