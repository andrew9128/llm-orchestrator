$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v11.1 (CUDA Auto-Detect + Debug) ---" -ForegroundColor Cyan

Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 1. VCRedist
Write-Host "[1/5] Installing Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

# 2. CUDA
Write-Host "[2/5] Detecting CUDA version..." -ForegroundColor Yellow
$tag = "b5248"
$buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
try {
    $smiOut = & nvidia-smi 2>&1 | Select-String "CUDA Version"
    if ($smiOut -match "CUDA Version:\s*([\d]+)\.") {
        $major = [int]$Matches[1]
        Write-Host "    CUDA major: $major" -ForegroundColor Green
        if ($major -le 11) {
            $buildUrl = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu11.7-x64.zip"
            Write-Host "    Using CUDA 11.7 build" -ForegroundColor Green
        } else {
            Write-Host "    Using CUDA 12.4 build (compatible with CUDA $major)" -ForegroundColor Green
        }
    }
} catch { Write-Host "    nvidia-smi failed, using CUDA 12.4" -ForegroundColor Yellow }

# 3. Скачиваем
Write-Host "[3/5] Downloading Engine..." -ForegroundColor Yellow
curl.exe -L "$buildUrl" -o "$W\engine.zip"
Expand-Archive -Path "$W\engine.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\engine.zip"

# Ищем exe
Write-Host "    Searching for llama-server.exe..." -ForegroundColor Yellow
$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (!$exePath) {
    Write-Host "    llama-server.exe NOT FOUND! Contents of bin:" -ForegroundColor Red
    Get-ChildItem "$W\bin" -Recurse | ForEach-Object { Write-Host "      $_" }
    exit 1
}
Write-Host "    Found: $exePath" -ForegroundColor Green

# 4. Авто-определяем устройство
Write-Host "[4/5] Detecting device name..." -ForegroundColor Yellow
$deviceArg = ""
try {
    $listOut = & $exePath --list-devices 2>&1
    Write-Host "    --list-devices output:" -ForegroundColor Gray
    $listOut | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
    $line = $listOut | Where-Object { $_ -match "5060" } | Select-Object -First 1
    if ($line -match ":\s*(\S+)" ) {
        $deviceName = $Matches[1].Trim(" :`"'")
        Write-Host "    Using device: $deviceName" -ForegroundColor Green
        $deviceArg = "--device $deviceName"
    } else {
        Write-Host "    RTX 5060 not found in list, no --device arg" -ForegroundColor Yellow
    }
} catch { Write-Host "    list-devices failed: $_" -ForegroundColor Yellow }

# 5. МОДЕЛЬ
$m = "$W\models\saiga.gguf"
if (!(Test-Path $m) -or (Get-Item $m).Length -lt 4GB) {
    Write-Host "[5/5] Downloading Russian Model (via BITS)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination $m -Priority High
} else {
    Write-Host "[5/5] Model already exists, skipping." -ForegroundColor Green
}

# 6. ЗАПУСК
$binDir = Split-Path $exePath -Parent
$cmd = "Set-Location '$binDir'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --host 0.0.0.0 $deviceArg > '$W\server.log' 2>&1"
Write-Host "    CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

Write-Host "Starting Server..." -ForegroundColor Green
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
Start-Sleep -s 15

if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "--- SUCCESS! ---" -ForegroundColor Green
    Write-Host "API: http://localhost:8010/v1"
} else {
    Write-Host "ERROR: Server crashed. Log:" -ForegroundColor Red
    if (Test-Path "$W\server.log") {
        Get-Content "$W\server.log" -Tail 30
    } else {
        Write-Host "  (log file missing - server never started)" -ForegroundColor Red
    }
}
