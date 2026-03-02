$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v12.1 ---" -ForegroundColor Cyan
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin")        { Remove-Item -Recurse -Force "$W\bin" }
if (Test-Path "$W\bin_vulkan") { Remove-Item -Recurse -Force "$W\bin_vulkan" }
New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
$tag = "b5248"

$MODELS = @(
  [PSCustomObject]@{ name="qvikhr-1.7b";  file="qvikhr-1.7b.gguf";    minVram=2000; ctx=4096;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="qvikhr-4b";    file="qvikhr-4b.gguf";      minVram=3500; ctx=8192;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-mis7b";  file="saiga-mistral7b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-8b";     file="saiga-llama3-8b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="qvikhr-8b";    file="qvikhr-8b.gguf";      minVram=5500; ctx=16384; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
  [PSCustomObject]@{ name="saiga-yagpt";  file="saiga-yandex-8b.gguf"; minVram=5500; ctx=16384; url="https://huggingface.co/IlyaGusev/saiga_yandexgpt_8b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-gem12";  file="saiga-gemma3-12b.gguf";minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q4_K.gguf" }
  [PSCustomObject]@{ name="saiga-nem12";  file="saiga-nemo-12b.gguf";  minVram=9000; ctx=32768; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q4_K.gguf" }
)

Write-Host "[1/6] Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null

Write-Host "[2/6] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
Expand-Archive "$W\engine.zip" "$W\bin" -Force
Remove-Item "$W\engine.zip"
$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
$binDir = Split-Path $exePath -Parent
Write-Host "  Copying all DLLs to exe dir..." -ForegroundColor Gray
Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
    if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force }
}
Write-Host "  DLLs: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Gray
$p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
Write-Host "  CUDA exit: $($p.ExitCode)" -ForegroundColor Gray
if ($p.ExitCode -ne 0) {
    Write-Host "  CUDA failed, switching to Vulkan..." -ForegroundColor Yellow
    curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
    Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
    Remove-Item "$W\vk.zip"
    $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $binDir = Split-Path $exePath -Parent
}
Write-Host "  Engine: $exePath" -ForegroundColor Green

Write-Host "[3/6] Detecting GPU..." -ForegroundColor Yellow
Start-Process $exePath "--list-devices" -Wait -NoNewWindow -RedirectStandardOutput "$W\do.txt" -RedirectStandardError "$W\de.txt" -ErrorAction SilentlyContinue
$devLines = @()
if (Test-Path "$W\do.txt") { $devLines += Get-Content "$W\do.txt" }
if (Test-Path "$W\de.txt") { $devLines += Get-Content "$W\de.txt" }
$devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
$bestDevice = ""; $bestVram = 0
foreach ($line in $devLines) {
    if ($line -match "^\s*([A-Za-z]+\d+):\s*.+?\((\d+)\s*MiB") {
        $dn = $Matches[1]; $vr = [int]$Matches[2]
        if ($vr -gt $bestVram) { $bestVram = $vr; $bestDevice = $dn }
    }
}
if (!$bestDevice) {
    $line5060 = $devLines | Where-Object { $_ -match "5060" } | Select-Object -First 1
    if ($line5060 -match "([A-Za-z]+\d+)\s*[=:]") { $bestDevice = $Matches[1] }
}
Write-Host "  Best: $bestDevice | VRAM: $bestVram MiB" -ForegroundColor Green
$deviceArg = if ($bestDevice) { "--device $bestDevice" } else { "" }

Write-Host "[4/6] Selecting model for $bestVram MiB..." -ForegroundColor Yellow
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
Write-Host "[5/6] Model download..." -ForegroundColor Yellow
$needDl = (!(Test-Path $m)) -or ((Get-Item $m -ErrorAction SilentlyContinue).Length -lt 100MB)
if ($needDl) {
    Import-Module BitsTransfer
    try { Start-BitsTransfer -Source $candidate.url -Destination $m -Priority High }
    catch { curl.exe -L $candidate.url -o $m --progress-bar }
    Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
} else {
    Write-Host "  Exists: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
}

Write-Host "[6/6] Starting server..." -ForegroundColor Yellow
$cmd = "Set-Location $binDir; .\llama-server.exe --model $m --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg > $W\server.log 2>&1"
Write-Host "  CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

$ok = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -s 2
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $h = ($r.Content | ConvertFrom-Json).status
            Write-Host "  [$i/30] $h" -ForegroundColor Yellow
            if ($h -eq "ok") { $ok = $true; break }
        }
    } catch { Write-Host "  [$i/30] waiting..." -ForegroundColor Gray }
}

if ($ok) {
    Write-Host "SUCCESS! API: http://localhost:8010/v1 | Model: $($candidate.name) | GPU: $bestDevice ($bestVram MiB)" -ForegroundColor Green
} else {
    Write-Host "FAILED. Log:" -ForegroundColor Red
    if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    else { Write-Host "(no log)" -ForegroundColor Red }
}
