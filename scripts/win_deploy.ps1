$ErrorActionPreference = 'Stop'
$W = "$env:USERPROFILE\llm_native"
$LogFile = "$W\server_final.log"

# Заголовок для проверки версии
Write-Host "--- Smart LLM Orchestrator v6.8 (ELITE FIX) ---" -ForegroundColor Cyan

# 1. ЗАЧИСТКА ВСЕГО СТАРОГО
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null

# 2. УСТАНОВКА VCRedist (Критично для работы .exe)
Write-Host "Installing Microsoft C++ Runtime..." -ForegroundColor Yellow
winget install -e --id Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements | Out-Null

# 3. ВЫБОР ДВИЖКА (Vulkan для Blackwell - это гарантия запуска)
# CUDA-бинарники часто бьются или не находят DLL. Vulkan встроен в драйвер 581.57.
Write-Host "Downloading Llama.cpp (Vulkan Edition for Blackwell stability)..." -ForegroundColor Cyan
$tag = "b4594"
$url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
curl.exe -L "$url" -o "$W\llama.zip"
Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\llama.zip"

# 4. ЗАПУСК
$ModelPath = "$W\models\saiga.gguf"
$start_script = @"
Set-Location '$W\bin'
# Для Vulkan используем --device
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 > '$LogFile' 2>&1
"@
$start_script | Out-File "$W\start.ps1" -Encoding UTF8 -Force

Write-Host "Starting server on GPU 1 (RTX 5060)..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"

Write-Host "Wait 20s. If it fails again, run: cat $LogFile" -ForegroundColor Gray
