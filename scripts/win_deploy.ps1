$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v11.0 (CUDA Auto-Detect) ---" -ForegroundColor Cyan

Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 1. VCRedist
Write-Host "[1/5] Installing Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

# 2. Определяем версию CUDA через nvidia-smi
Write-Host "[2/5] Detecting CUDA version..." -ForegroundColor Yellow
$cudaVer = ""
try {
    $smiOut = & nvidia-smi 2>&1 | Select-String "CUDA Version"
    if ($smiOut -match "CUDA Version:\s*([\d]+)\.([\d]+)") {
        $cudaVer = "cu$($Matches[1]).$($Matches[2])"
        Write-Host "    Detected: $cudaVer" -ForegroundColor Green
    }
} catch {}

# Маппинг на доступные билды (llama.cpp предоставляет cu12.4, cu12.6, cu11.7)
$tag = "b5248"
if ($cudaVer -match "cu12\.[6-9]|cu12\.[1-9][0-9]|cu13") {
    $buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    Write-Host "    Using CUDA 12.4 build (compatible)" -ForegroundColor Green
} elseif ($cudaVer -match "cu12\.[0-5]") {
    $buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    Write-Host "    Using CUDA 12.4 build" -ForegroundColor Green
} elseif ($cudaVer -match "cu11") {
    $buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu11.7-x64.zip"
    Write-Host "    Using CUDA 11.7 build" -ForegroundColor Green
} else {
    Write-Host "    CUDA not detected, falling back to Vulkan" -ForegroundColor Red
    $buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip"
}

# 3. Скачиваем движок
Write-Host "[3/5] Downloading Engine..." -ForegroundColor Yellow
curl.exe -L "$buildUrl" -o "$W\engine.zip"
Expand-Archive -Path "$W\engine.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\engine.zip"

# 4. Авто-определяем имя устройства RTX 5060
Write-Host "[4/5] Detecting device name..." -ForegroundColor Yellow
$deviceName = ""
try {
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $listOut = & $exePath --list-devices 2>&1
    # Ищем строку с RTX 5060 и берём имя устройства
    $line = $listOut | Where-Object { $_ -match "5060" } | Select-Object -First 1
    if ($line -match "^\s*([^\s:]+)") {
        $deviceName = $Matches[1].Trim()
        Write-Host "    Found device: $deviceName" -ForegroundColor Green
    }
} catch {}

if (!$deviceName) {
    Write-Host "    Could not detect device, using default (all GPUs)" -ForegroundColor Yellow
}

# 5. МОДЕЛЬ
$m = "$W\models\saiga.gguf"
if (!(Test-Path $m) -or (Get-Item $m).Length -lt 4GB) {
    Write-Host "[5/5] Downloading Russian Model (via BITS)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination $m -Priority High
} else {
    Write-Host "[5/5] Model already exists, skipping download." -ForegroundColor Green
}

# 6. ЗАПУСК
$devArg = if ($deviceName) { "--device $deviceName" } else { "" }
$cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --host 0.0.0.0 $devArg > '$W\server.log' 2>&1"
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

Write-Host "Starting Server..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
Start-Sleep -s 12

if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "--- SUCCESS! ---" -ForegroundColor Green
    Write-Host "API: http://localhost:8010/v1"
} else {
    Write-Host "ERROR: Server crashed. Log:" -ForegroundColor Red
    Get-Content "$W\server.log" -Tail 20
}
