$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v10.1 (RTX 5060 / Vulkan Fix) ---" -ForegroundColor Cyan

# 1. ЧИСТКА
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 2. VCRedist
Write-Host "[1/4] Installing Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

# 3. ДВИЖОК VULKAN
Write-Host "[2/4] Downloading Vulkan Engine..." -ForegroundColor Yellow
$tag = "b4594"
$url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
curl.exe -L "$url" -o "$W\vulkan.zip"
Expand-Archive -Path "$W\vulkan.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\vulkan.zip"

# 4. МОДЕЛЬ
$m = "$W\models\saiga.gguf"
if (!(Test-Path $m) -or (Get-Item $m).Length -lt 4GB) {
    Write-Host "[3/4] Downloading Russian Model (via BITS)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination $m -Priority High
}

# 5. ЗАПУСК
# --device 0 = RTX 5060 (первая карта в списке Vulkan!)
# --cache-type-kv УБРАН (не поддерживается в b4594)
$run_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --host 0.0.0.0 --device 0 --log-disable > '$W\server.log' 2>&1"
$run_cmd | Out-File "$W\run.ps1" -Encoding UTF8 -Force

Write-Host "[4/4] Starting Server on GPU 0 (RTX 5060)..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
Start-Sleep -s 10

if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "--- SUCCESS! ---" -ForegroundColor Green
    Write-Host "API: http://localhost:8010/v1"
} else {
    Write-Host "ERROR: Server crashed. Log:" -ForegroundColor Red
    Get-Content "$W\server.log" -Tail 20
}
