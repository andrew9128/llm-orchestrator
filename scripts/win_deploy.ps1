$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v11.2 (CUDA+Vulkan Fallback) ---" -ForegroundColor Cyan

Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 1. VCRedist
Write-Host "[1/5] Installing Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements

$tag = "b5248"

function Download-And-Test($url, $label) {
    Write-Host "  Trying $label ..." -ForegroundColor Yellow
    if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
    New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
    curl.exe -L $url -o "$W\engine.zip" --silent
    Expand-Archive -Path "$W\engine.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\engine.zip"
    $exe = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    if (!$exe) { Write-Host "  exe not found!" -ForegroundColor Red; return $null }
    # Тест - запускаем с --version и ловим вывод
    $testOut = & $exe --version 2>&1
    Write-Host "  Test output: $testOut" -ForegroundColor Gray
    if ($LASTEXITCODE -ne 0 -or ($testOut -match "error|failed|missing" -and $testOut -notmatch "version")) {
        Write-Host "  $label FAILED (exit code $LASTEXITCODE)" -ForegroundColor Red
        return $null
    }
    Write-Host "  $label OK!" -ForegroundColor Green
    return $exe
}

# 2. Пробуем CUDA 12.4, потом Vulkan
Write-Host "[2/5] Downloading and testing engine builds..." -ForegroundColor Yellow
$exePath = $null

$exePath = Download-And-Test "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" "CUDA 12.4"

if (!$exePath) {
    $exePath = Download-And-Test "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" "Vulkan"
}

if (!$exePath) {
    Write-Host "All builds failed! Cannot continue." -ForegroundColor Red
    exit 1
}

$binDir = Split-Path $exePath -Parent
Write-Host "  Using exe: $exePath" -ForegroundColor Green

# 3. Определяем устройство
Write-Host "[3/5] Detecting devices..." -ForegroundColor Yellow
$deviceArg = ""
try {
    $listOut = & $exePath --list-devices 2>&1
    Write-Host "  Devices:" -ForegroundColor Gray
    $listOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    # Ищем строку с 5060 - формат обычно: "  CUDA0: NVIDIA GeForce RTX 5060"
    $line = $listOut | Where-Object { $_ -match "5060" } | Select-Object -First 1
    if ($line -match "^\s*(\w+)\s*:") {
        $deviceName = $Matches[1]
        Write-Host "  Using device: $deviceName" -ForegroundColor Green
        $deviceArg = "--device $deviceName"
    }
} catch { Write-Host "  list-devices error: $_" -ForegroundColor Yellow }

# 4. Модель
$m = "$W\models\saiga.gguf"
if (!(Test-Path $m) -or (Get-Item $m).Length -lt 4GB) {
    Write-Host "[4/5] Downloading model..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination $m -Priority High
} else {
    Write-Host "[4/5] Model exists, skipping." -ForegroundColor Green
}

# 5. Запуск
Write-Host "[5/5] Starting server..." -ForegroundColor Yellow
$cmd = "Set-Location '$binDir'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size 8192 --host 0.0.0.0 $deviceArg > '$W\server.log' 2>&1"
Write-Host "  CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

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
        Write-Host "  (no log - exe crashed on launch, missing DLL?)" -ForegroundColor Red
        # Запускаем напрямую для видимой ошибки
        Write-Host "  Direct run attempt:" -ForegroundColor Yellow
        Set-Location $binDir
        & .\llama-server.exe --model $m --port 8010 --n-gpu-layers 1 2>&1 | Select-Object -First 20
    }
}
