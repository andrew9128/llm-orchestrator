$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ВЕРСИЯ 7.5 - THE FINAL FIX
Write-Host "--- Smart LLM Orchestrator v7.5 (STABILITY FIRST) ---" -ForegroundColor Cyan

# 1. ЧИСТКА
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null

# 2. УСТАНОВКА КРИТИЧЕСКИХ БИБЛИОТЕК MICROSOFT
# Без этого .exe файлы на Windows просто не запускаются (дают пустой лог)
Write-Host "Checking Microsoft Visual C++ Runtime..." -ForegroundColor Yellow
winget install -e --id Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements --quiet

function Download-Safe($url, $out, $minSize) {
    if ((Test-Path $out) -and ((Get-Item $out).Length -gt $minSize)) { return }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High
}

# 3. СКАЧИВАЕМ ДВИЖОК VULKAN (Для Blackwell 5060 это лучший выбор)
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
Download-Safe $bin_url "$W\llama.zip" 10MB
Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force

# 4. МОДЕЛЬ
Download-Safe "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" "$W\models\saiga.gguf" 4000MB

# 5. КОМАНДА ЗАПУСКА (Оптимизация под 8GB VRAM)
$ModelPath = "$W\models\saiga.gguf"
$LogFile = "$W\server.log"
$start_cmd = @"
Set-Location '$W\bin'
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 8192 --cache-type-kv q4_0 --host 0.0.0.0 > '$LogFile' 2>&1
"@
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. ЗАПУСК
Write-Host "Starting server on GPU 1 (RTX 5060)..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"

Start-Sleep -Seconds 10
if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "SUCCESS: API IS ALIVE! http://localhost:8010/v1" -ForegroundColor Green
} else {
    Write-Host "ERROR: Server failed to start. Last log lines:" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }
}
