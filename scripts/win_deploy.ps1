$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v12.8 ---" -ForegroundColor Cyan

function Install-IfMissing($id, $label) {
    Write-Host "  Checking $label..." -ForegroundColor Gray
    & winget install -e --id $id --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Download-Model($url, $dest) {
    Remove-Item $dest -ErrorAction SilentlyContinue
    # Метод 1: huggingface-hub (надёжнее всего для LFS)
    $hfRepo = ""; $hfFile = ""
    if ($url -match "huggingface\.co/([^/]+/[^/]+)/resolve/[^/]+/(.+)") {
        $hfRepo = $Matches[1]; $hfFile = $Matches[2]
    }
    if ($hfRepo) {
        Write-Host "  Trying huggingface-hub..." -ForegroundColor Gray
        $dlDir = Split-Path $dest -Parent
        $dlName = Split-Path $dest -Leaf
        $result = & python -c "from huggingface_hub import hf_hub_download; import shutil; p=hf_hub_download(repo_id=$hfRepo, filename=$hfFile, local_dir=r$dlDir); print(p)" 2>&1
        Write-Host "  hf result: $result" -ForegroundColor Gray
        # hf_hub_download сохраняет с оригинальным именем, переименуем
        $downloaded = Get-ChildItem $dlDir -Filter "*.gguf" | Where-Object { $_.Length -gt 100MB } | Select-Object -First 1
        if ($downloaded -and $downloaded.FullName -ne $dest) {
            Move-Item $downloaded.FullName $dest -Force
        }
    }
    # Метод 2: curl прямой
    if (!(Test-Path $dest) -or (Get-Item $dest -EA SilentlyContinue).Length -lt 100MB) {
        Write-Host "  Trying curl..." -ForegroundColor Gray
        curl.exe -L --retry 3 $url -o $dest
    }
    $size = if (Test-Path $dest) { (Get-Item $dest).Length } else { 0 }
    return $size
}

Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -s 2
$W = "$env:USERPROFILE\llm_native"
@("$W\bin","$W\bin_vulkan") | ForEach-Object { if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue } }
New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
$tag = "b5248"

# minVram в MB. Порядок важен: от меньшей к большей
$MODELS = @(
  [PSCustomObject]@{ name="qvikhr-1.7b";  file="qvikhr-1.7b.gguf";    minVram=2000; ctx=4096;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="qvikhr-4b";    file="qvikhr-4b.gguf";      minVram=3500; ctx=8192;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-8b";     file="saiga-llama3-8b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-mis7b";  file="saiga-mistral7b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="qvikhr-8b";    file="qvikhr-8b.gguf";      minVram=5500; ctx=16384; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-gem12";  file="saiga-gemma3-12b.gguf";minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-nem12";  file="saiga-nemo-12b.gguf";  minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q4_K.gguf" }
)

Write-Host "[1/7] System dependencies..." -ForegroundColor Yellow
Install-IfMissing "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime"
$pyOk = $false
try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
if (!$pyOk) {
    Write-Host "  Python not found - installing..." -ForegroundColor Yellow
    Install-IfMissing "Python.Python.3.12" "Python 3.12"
    $pyExe = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($pyExe) { $env:PATH = "$((Split-Path $pyExe -Parent));$($env:PATH)" }
}
Write-Host "  Python: $(& python --version 2>&1)" -ForegroundColor Green

Write-Host "[2/7] CUDA DLLs + huggingface-hub via pip..." -ForegroundColor Yellow
$cudaDllDir = "$W\cuda_dlls"
New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
& python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
& python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
& python -m pip install --quiet huggingface-hub 2>&1 | Out-Null
$cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
Write-Host "  CUDA DLLs: $($cudaDlls.Count) | hf-hub: installed" -ForegroundColor Green

Write-Host "[3/7] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
Expand-Archive "$W\engine.zip" "$W\bin" -Force; Remove-Item "$W\engine.zip"
$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
$binDir = Split-Path $exePath -Parent
Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object { if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force } }
$cudaDlls | ForEach-Object { Copy-Item $_.FullName $binDir -Force }
Write-Host "  DLLs in exe dir: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green

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

Write-Host "[6/7] Selecting and downloading model..." -ForegroundColor Yellow
$availVram = $bestVram - 1200
$candidates = @($MODELS | Where-Object { $_.minVram -le $availVram })
if (!$candidates) { $candidates = @($MODELS[0]) }
# Перебираем от лучшей к худшей пока не скачается
$candidate = $null
$m = ""
for ($ci = $candidates.Count - 1; $ci -ge 0; $ci--) {
    $c = $candidates[$ci]
    $mPath = "$W\models\$($c.file)"
    $existOk = (Test-Path $mPath) -and ((Get-Item $mPath -EA SilentlyContinue).Length -gt 100MB)
    if ($existOk) {
        Write-Host "  Using cached: $($c.name) ($([math]::Round((Get-Item $mPath).Length/1MB))MB)" -ForegroundColor Green
        $candidate = $c; $m = $mPath; break
    }
    Write-Host "  Trying to download: $($c.name)..." -ForegroundColor Yellow
    $sz = Download-Model $c.url $mPath
    Write-Host "  Size: $([math]::Round($sz/1MB))MB" -ForegroundColor Gray
    if ($sz -gt 100MB) {
        Write-Host "  Downloaded OK: $($c.name)" -ForegroundColor Green
        $candidate = $c; $m = $mPath; break
    } else {
        Write-Host "  Failed ($sz bytes), trying next model..." -ForegroundColor Yellow
        Remove-Item $mPath -ErrorAction SilentlyContinue
    }
}
if (!$candidate) { Write-Host "All model downloads failed!" -ForegroundColor Red; exit 1 }

if ($bestVram -ge 20000)     { $ctxSize = 65536 }
elseif ($bestVram -ge 14000) { $ctxSize = 32768 }
elseif ($bestVram -ge 10000) { $ctxSize = 16384 }
elseif ($bestVram -ge 6000)  { $ctxSize = 8192 }
else                          { $ctxSize = 4096 }
Write-Host "  Final: $($candidate.name) | ctx: $ctxSize" -ForegroundColor Green

Write-Host "[7/7] Starting server..." -ForegroundColor Yellow
$cmd = "Set-Location $binDir; .\llama-server.exe --model $m --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --no-warmup > $W\server.log 2>&1"
Write-Host "  CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

# Wait for server to come up
Write-Host "  Waiting for server..." -ForegroundColor Yellow
$ok = $false
for ($i = 1; $i -le 80; $i++) {
    Start-Sleep -s 3
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $h = ($r.Content | ConvertFrom-Json).status
        Write-Host "  [$i] status: $h" -ForegroundColor Yellow
        if ($h -eq "ok" -or $h -eq "loading model") { $ok = $true; break }
    } catch { Write-Host "  [$i] waiting..." -ForegroundColor Gray }
}

if ($ok) {
    Write-Host "SUCCESS! http://localhost:8010/v1 | $($candidate.name) | $bestDevice ($bestVram MiB)" -ForegroundColor Green
    $wdScript = "$W\watchdog.ps1"
    curl.exe -L "https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_watchdog.ps1" -o $wdScript --silent
    Write-Host "Starting watchdog in background..." -ForegroundColor Cyan
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript
    Write-Host "Watchdog started." -ForegroundColor Cyan
    Write-Host "To stop everything run:" -ForegroundColor Cyan
    Write-Host "  powershell -EP Bypass -c "curl.exe -L -o $env:TEMP\stop.ps1 https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_stop.ps1; & $env:TEMP\stop.ps1"" -ForegroundColor White
} else {
    Write-Host "FAILED. Log:" -ForegroundColor Red
    if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    else { Write-Host "(no log)" -ForegroundColor Red }
}
