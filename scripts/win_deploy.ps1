$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v12.4 ---" -ForegroundColor Cyan

function Install-IfMissing($id, $label) {
    Write-Host "  Checking $label..." -ForegroundColor Gray
    & winget install -e --id $id --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -s 2
$W = "$env:USERPROFILE\llm_native"
@("$W\bin","$W\bin_vulkan") | ForEach-Object { if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue } }
New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
$tag = "b5248"

$MODELS = @(
  [PSCustomObject]@{ name="qvikhr-1.7b";  file="qvikhr-1.7b.gguf";    minVram=2000; ctx=4096;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="qvikhr-4b";    file="qvikhr-4b.gguf";      minVram=3500; ctx=8192;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-mis7b";  file="saiga-mistral7b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-8b";     file="saiga-llama3-8b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="qvikhr-8b";    file="qvikhr-8b.gguf";      minVram=5500; ctx=16384; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-gem12";  file="saiga-gemma3-12b.gguf";minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-nem12";  file="saiga-nemo-12b.gguf";  minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q4_K.gguf" }
)

# ── 1. Системные зависимости ────────────────────────────────────────────────
Write-Host "[1/7] Installing system dependencies..." -ForegroundColor Yellow
Install-IfMissing "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime"
Install-IfMissing "Git.Git"                        "Git"

# Python
$pyOk = $false
try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
if (!$pyOk) {
    Write-Host "  Python not found - installing..." -ForegroundColor Yellow
    Install-IfMissing "Python.Python.3.12" "Python 3.12"
    # Ищем python.exe вручную если PATH ещё не обновился
    $pyExe = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($pyExe) { $env:PATH = "$((Split-Path $pyExe -Parent));$($env:PATH)" }
}
try { Write-Host "  Python: $(& python --version 2>&1)" -ForegroundColor Green } catch { Write-Host "  Python still not found!" -ForegroundColor Red }

# ── 2. CUDA DLLs через pip ──────────────────────────────────────────────────
Write-Host "[2/7] Installing CUDA runtime DLLs via pip..." -ForegroundColor Yellow
$cudaDllDir = "$W\cuda_dlls"
New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
& python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
& python -m pip install --quiet --target $cudaDllDir `
    nvidia-cuda-runtime-cu12 `
    nvidia-cublas-cu12 `
    nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
$cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
Write-Host "  CUDA DLLs downloaded: $($cudaDlls.Count)" -ForegroundColor Green
$cudaDlls | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Gray }

# ── 3. CUDA Engine ──────────────────────────────────────────────────────────
Write-Host "[3/7] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
Expand-Archive "$W\engine.zip" "$W\bin" -Force
Remove-Item "$W\engine.zip"
$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
$binDir = Split-Path $exePath -Parent
# Копируем DLL из архива
Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
    if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force }
}
# Копируем CUDA DLL из pip
$cudaDlls | ForEach-Object { Copy-Item $_.FullName $binDir -Force }
Write-Host "  Total DLLs in exe dir: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green

# ── 4. Тест CUDA, фоллбэк на Vulkan ────────────────────────────────────────
Write-Host "[4/7] Testing engine..." -ForegroundColor Yellow
$p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
Write-Host "  exit: $($p.ExitCode)" -ForegroundColor Gray
if ($p.ExitCode -ne 0) {
    Write-Host "  CUDA failed, falling back to Vulkan..." -ForegroundColor Yellow
    curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
    Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force; Remove-Item "$W\vk.zip"
    $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $binDir = Split-Path $exePath -Parent
    Write-Host "  Using Vulkan: $exePath" -ForegroundColor Yellow
} else { Write-Host "  CUDA OK!" -ForegroundColor Green }

# ── 5. Определяем GPU ───────────────────────────────────────────────────────
Write-Host "[5/7] Detecting GPU..." -ForegroundColor Yellow
Start-Process $exePath "--list-devices" -Wait -NoNewWindow -RedirectStandardOutput "$W\do.txt" -RedirectStandardError "$W\de.txt" -ErrorAction SilentlyContinue
$devLines = @()
if (Test-Path "$W\do.txt") { $devLines += Get-Content "$W\do.txt" }
if (Test-Path "$W\de.txt") { $devLines += Get-Content "$W\de.txt" }
$devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
$bestDevice = ""; $bestVram = 0; $bestIsRTX = $false
foreach ($line in $devLines) {
    if ($line -match "^\s*([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB") {
        $dn = $Matches[1]; $label = $Matches[2]; $vr = [int]$Matches[3]
        $isRTX = $label -match "RTX"
        if ((!$bestIsRTX -and $isRTX) -or ($isRTX -eq $bestIsRTX -and $vr -gt $bestVram)) {
            $bestVram = $vr; $bestDevice = $dn; $bestIsRTX = $isRTX
        }
    }
}
if (!$bestDevice -and $devLines) {
    $fl = $devLines | Where-Object { $_ -match "([A-Za-z]+\d+)\s*:" } | Select-Object -First 1
    if ($fl -match "([A-Za-z]+\d+)\s*:") { $bestDevice = $Matches[1] }
}
Write-Host "  Selected: $bestDevice | VRAM: $bestVram MiB | RTX: $bestIsRTX" -ForegroundColor Green
$deviceArg = if ($bestDevice) { "--device $bestDevice" } else { "" }

# ── 6. Выбор модели ─────────────────────────────────────────────────────────
Write-Host "[6/7] Selecting model for $bestVram MiB VRAM..." -ForegroundColor Yellow
$availVram = $bestVram - 1200
$candidate = $MODELS | Where-Object { $_.minVram -le $availVram } | Select-Object -Last 1
if (!$candidate) { $candidate = $MODELS[0] }
if ($bestVram -ge 20000)     { $ctxSize = 65536 }
elseif ($bestVram -ge 14000) { $ctxSize = 32768 }
elseif ($bestVram -ge 10000) { $ctxSize = 16384 }
elseif ($bestVram -ge 6000)  { $ctxSize = 8192 }
else                          { $ctxSize = 4096 }
Write-Host "  Model: $($candidate.name) | ctx: $ctxSize" -ForegroundColor Green

$m = "$W\models\$($candidate.file)"
Write-Host "[7/7] Checking model..." -ForegroundColor Yellow
$needDl = (!(Test-Path $m)) -or ((Get-Item $m -ErrorAction SilentlyContinue).Length -lt 100MB)
if ($needDl) {
    Write-Host "  Downloading $($candidate.name)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    try { Start-BitsTransfer -Source $candidate.url -Destination $m -Priority High -ErrorAction Stop }
    catch {
        Write-Host "  BITS failed, trying curl..." -ForegroundColor Yellow
        Remove-Item $m -ErrorAction SilentlyContinue
        curl.exe -L $candidate.url -o $m
    }
    if (Test-Path $m) { Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green }
    else { Write-Host "  ERROR: download failed!" -ForegroundColor Red; exit 1 }
} else { Write-Host "  Exists: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green }

$cmd = "Set-Location $binDir; .\llama-server.exe --model $m --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg > $W\server.log 2>&1"
Write-Host "CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

$ok = $false
for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -s 3
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        $h = ($r.Content | ConvertFrom-Json).status
        Write-Host "  [$i] status: $h" -ForegroundColor Yellow
        if ($h -eq "ok") { $ok = $true; break }
    } catch { Write-Host "  [$i] waiting..." -ForegroundColor Gray }
}

if ($ok) {
    Write-Host "SUCCESS! http://localhost:8010/v1 | $($candidate.name) | $bestDevice ($bestVram MiB)" -ForegroundColor Green
} else {
    Write-Host "FAILED. Log:" -ForegroundColor Red
    if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    else { Write-Host "(no log)" -ForegroundColor Red }
}
