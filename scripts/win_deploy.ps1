$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v12.0 (Smart GPU/Model Select) ---" -ForegroundColor Cyan

Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin")        { Remove-Item -Recurse -Force "$W\bin" }
if (Test-Path "$W\bin_vulkan") { Remove-Item -Recurse -Force "$W\bin_vulkan" }
New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
$tag = "b5248"

# ─── МОДЕЛИ (имя, url, min_vram_mb, q, context) ────────────────────────────
$MODELS = @(
  [PSCustomObject]@{ name="qvikhr-1.7b"; file="qvikhr-1.7b-q4.gguf";   minVram=2000;  ctx=32768; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="qvikhr-4b";   file="qvikhr-4b-q4.gguf";     minVram=3500;  ctx=16384; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-mis7b"; file="saiga-mistral7b-q4.gguf";minVram=5500;  ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-8b";    file="saiga-llama3-8b-q4.gguf";minVram=5500;  ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="qvikhr-8b";   file="qvikhr-8b-q4.gguf";     minVram=5500;  ctx=16384; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-yagpt"; file="saiga-yandex-8b-q4.gguf";minVram=5500;  ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_yandexgpt_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-gem12"; file="saiga-gemma3-12b-q4.gguf";minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-nem12"; file="saiga-nemo-12b-q4.gguf"; minVram=9000;  ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q4_K.gguf" }
)

# ─── 1. VCRedist ────────────────────────────────────────────────────────────
Write-Host "[1/6] Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null

# ─── 2. CUDA ENGINE + DLL FIX ───────────────────────────────────────────────
Write-Host "[2/6] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
Expand-Archive "$W\engine.zip" "$W\bin" -Force; Remove-Item "$W\engine.zip"

$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
$binDir  = Split-Path $exePath -Parent

# КЛЮЧЕВОЕ: копируем ВСЕ .dll из zip в папку с exe
Write-Host "  Copying all DLLs to exe dir..." -ForegroundColor Gray
Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
    if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force }
}
$dllCount = (Get-ChildItem $binDir -Filter "*.dll").Count
Write-Host "  DLLs in exe dir: $dllCount" -ForegroundColor Gray

# Тест CUDA
$p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow `
     -RedirectStandardOutput "$W\ver_out.txt" -RedirectStandardError "$W\ver_err.txt"
Write-Host "  CUDA test exit: $($p.ExitCode)" -ForegroundColor Gray
$useCuda = ($p.ExitCode -eq 0)

if (!$useCuda) {
    Write-Host "  CUDA failed, downloading Vulkan..." -ForegroundColor Yellow
    curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
    Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force; Remove-Item "$W\vk.zip"
    $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $binDir  = Split-Path $exePath -Parent
}
Write-Host "  Engine: $exePath" -ForegroundColor Green

# ─── 3. ОПРЕДЕЛЯЕМ GPU + VRAM ───────────────────────────────────────────────
Write-Host "[3/6] Detecting GPU & VRAM..." -ForegroundColor Yellow
Start-Process $exePath "--list-devices" -Wait -NoNewWindow `
    -RedirectStandardOutput "$W\dev_out.txt" -RedirectStandardError "$W\dev_err.txt" -ErrorAction SilentlyContinue
$devLines = @()
if (Test-Path "$W\dev_out.txt") { $devLines += Get-Content "$W\dev_out.txt" }
if (Test-Path "$W\dev_err.txt") { $devLines += Get-Content "$W\dev_err.txt" }
$devLines | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

# Парсим VRAM лучшей карты (RTX > GTX, больше VRAM предпочтительнее)
$bestDevice = ""; $bestVram = 0
foreach ($line in $devLines) {
    # Формат: "Vulkan0: NVIDIA GeForce RTX 5060 (7807 MiB, 7807 MiB free)"
    if ($line -match "^(\s*)([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB") {
        $devName  = $Matches[2]
        $gpuLabel = $Matches[3]
        $vram     = [int]$Matches[4]
        Write-Host "    Parsed: $devName | $gpuLabel | $vram MiB" -ForegroundColor Gray
        if ($vram -gt $bestVram) { $bestVram = $vram; $bestDevice = $devName }
    }
}

if (!$bestDevice) {
    # Fallback: берём первую карту с 5060 в названии
    $line5060 = $devLines | Where-Object { $_ -match "5060" } | Select-Object -First 1
    if ($line5060 -match "([A-Za-z]+\d+)\s*[=:]") { $bestDevice = $Matches[1] }
}

Write-Host "  Best device: $bestDevice | VRAM: $bestVram MiB" -ForegroundColor Green
$deviceArg = if ($bestDevice) { "--device $bestDevice" } else { "" }

# ─── 4. ВЫБОР МОДЕЛИ ────────────────────────────────────────────────────────
Write-Host "[4/6] Selecting model for $bestVram MiB VRAM..." -ForegroundColor Yellow

# Берём лучшую модель которая влезает (с запасом 1GB для KV-кеша)
$availVram = $bestVram - 1200
$candidate = $MODELS | Where-Object { $_.minVram -le $availVram } | Select-Object -Last 1

if (!$candidate) {
    Write-Host "  VRAM очень мало, берём минимальную модель" -ForegroundColor Yellow
    $candidate = $MODELS[0]
}

Write-Host "  Selected: $($candidate.name) (min $($candidate.minVram) MiB, ctx $($candidate.ctx))" -ForegroundColor Green

# Контекст и параметры под VRAM
$ctxSize = $candidate.ctx
if ($bestVram -ge 20000) { $ctxSize = 65536 }
elseif ($bestVram -ge 14000) { $ctxSize = 32768 }
elseif ($bestVram -ge 10000) { $ctxSize = 16384 }
elseif ($bestVram -ge 6000)  { $ctxSize = 8192 }
else                          { $ctxSize = 4096 }

Write-Host "  Context size: $ctxSize" -ForegroundColor Gray

# ─── 5. СКАЧИВАЕМ МОДЕЛЬ ────────────────────────────────────────────────────
$m = "$W\models\$($candidate.file)"
Write-Host "[5/6] Model: $($candidate.name)..." -ForegroundColor Yellow
$needDownload = $false
if (!(Test-Path $m)) { $needDownload = $true }
elseif ((Get-Item $m).Length -lt 100MB) { 
    Write-Host "  File too small (partial download?), re-downloading..." -ForegroundColor Yellow
    $needDownload = $true 
}

if ($needDownload) {
    Write-Host "  Downloading from HuggingFace..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    try {
        Start-BitsTransfer -Source $candidate.url -Destination $m -Priority High
        Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
    } catch {
        Write-Host "  BITS failed, trying curl..." -ForegroundColor Yellow
        curl.exe -L $candidate.url -o $m --progress-bar
    }
} else {
    Write-Host "  Exists: $([math]::Round((Get-Item $m).Length/1MB))MB, skipping." -ForegroundColor Green
}

# ─── 6. ЗАПУСК ──────────────────────────────────────────────────────────────
Write-Host "[6/6] Starting server..." -ForegroundColor Yellow
$cmd = "Set-Location '$binDir'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg > '$W\server.log' 2>&1"
Write-Host "  CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

# ─── HEALTHCHECK ────────────────────────────────────────────────────────────
Write-Host "  Waiting for server (healthcheck)..." -ForegroundColor Yellow
$ok = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -s 2
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $health = ($r.Content | ConvertFrom-Json).status
            if ($health -eq "ok" -or $health -eq "loading model") {
                Write-Host "  [$i/30] Status: $health" -ForegroundColor Yellow
            }
            if ($health -eq "ok") { $ok = $true; break }
        }
    } catch { }
    Write-Host "  [$i/30] waiting..." -ForegroundColor Gray
}

if ($ok) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║           SUCCESS!                       ║" -ForegroundColor Green
    Write-Host "║  API:    http://localhost:8010/v1         ║" -ForegroundColor Green
    Write-Host "║  Model:  $($candidate.name.PadRight(30))║" -ForegroundColor Green
    Write-Host "║  VRAM:   $("$bestVram MiB / ctx $ctxSize".PadRight(30))║" -ForegroundColor Green
    Write-Host "║  GPU:    $($bestDevice.PadRight(30))║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
} else {
    Write-Host "ERROR: Server didn't become healthy. Log:" -ForegroundColor Red
    if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    else { Write-Host "  (no log)" -ForegroundColor Red }
}
