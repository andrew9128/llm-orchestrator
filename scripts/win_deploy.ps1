# LLM WIN DEPLOY v13.4
# Usage:
#   win_deploy.ps1                   -- deploy (default)
#   win_deploy.ps1 --stop            -- stop server + watchdog
#   win_deploy.ps1 --status          -- show status
#   win_deploy.ps1 --restart         -- stop + deploy
#   win_deploy.ps1 -Gpus 2           -- use 2 GPUs (RTX first, then by VRAM)
#   win_deploy.ps1 -Gpus all         -- use all GPUs
param(
    [string]$Action = "--deploy",
    [string]$Gpus   = "1"
)
if ($args.Count -gt 0 -and $Action -eq "--deploy") { $Action = $args[0] }

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$W = "$env:USERPROFILE\llm_native"

# =============================================================================
# STOP
# =============================================================================
function Invoke-Stop {
    Write-Host "Stopping LLM server and watchdog..." -ForegroundColor Yellow
    $killed = 0
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue
        $killed++
    }
    Write-Host "  Stopped $killed llama process(es)" -ForegroundColor Green
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped watchdog (PID $($_.ProcessId))" -ForegroundColor Green
    }
    Write-Host "Done." -ForegroundColor Green
}

# =============================================================================
# STATUS
# =============================================================================
function Invoke-Status {
    Write-Host "-- LLM STATUS --" -ForegroundColor Cyan
    $proc = Get-Process | Where-Object { $_.Name -match "llama" }
    if ($proc) { Write-Host "  llama-server: RUNNING (PID $($proc.Id))" -ForegroundColor Green }
    else        { Write-Host "  llama-server: NOT RUNNING" -ForegroundColor Red }
    $wd = Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
    }
    if ($wd) { Write-Host "  watchdog: RUNNING (PID $($wd.ProcessId))" -ForegroundColor Green }
    else      { Write-Host "  watchdog: NOT RUNNING" -ForegroundColor Yellow }
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $h = ($r.Content | ConvertFrom-Json).status
        Write-Host "  API: $h -- http://localhost:8010/v1" -ForegroundColor Green
    } catch { Write-Host "  API: unreachable" -ForegroundColor Red }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
}

# =============================================================================
# HELPERS (global scope - no nesting issues)
# =============================================================================
function Install-Pkg($id, $label) {
    Write-Host "  Checking $label..." -ForegroundColor Gray
    & winget install -e --id $id --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Download-Model($url, $dest) {
    Remove-Item $dest -ErrorAction SilentlyContinue
    $hfRepo = ""; $hfFile = ""
    if ($url -match "huggingface\.co/([^/]+/[^/]+)/resolve/[^/]+/(.+)") {
        $hfRepo = $Matches[1]; $hfFile = $Matches[2]
    }
    if ($hfRepo) {
        Write-Host "  Trying huggingface-hub..." -ForegroundColor Gray
        $dlDir = Split-Path $dest -Parent
        & python -c "
from huggingface_hub import hf_hub_download
import shutil
p = hf_hub_download(repo_id='$hfRepo', filename='$hfFile', local_dir=r'$dlDir')
if p != r'$dest': shutil.move(p, r'$dest')
" 2>&1 | Out-Null
    }
    if (!(Test-Path $dest) -or (Get-Item $dest -EA SilentlyContinue).Length -lt 100MB) {
        Write-Host "  Trying curl..." -ForegroundColor Gray
        curl.exe -L --retry 3 $url -o $dest
    }
    if (Test-Path $dest) { return (Get-Item $dest).Length }
    return 0
}

function Select-BestModel($vramMb) {
    # Philosophy: smaller model with precise quant > larger model with bad quant
    # q8_0 = excellent, q6_K = excellent, q5_K = good, q4_K = ok
    # minVram = model size + 1.8 GB (overhead + min KV cache)
    $catalog = @(
        [PSCustomObject]@{ name="saiga-nem12-q8"; file="saiga-nem12-q8.gguf"; minVram=31800; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8"; file="saiga-gem12-q8.gguf"; minVram=31800; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q8"; file="saiga-nem12-q8.gguf"; minVram=22000; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8"; file="saiga-gem12-q8.gguf"; minVram=22000; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q6"; file="saiga-nem12-q6.gguf"; minVram=13000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6"; file="saiga-gem12-q6.gguf"; minVram=13000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q5"; file="saiga-nem12-q5.gguf"; minVram=11000; quant="q5_K"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5"; file="saiga-gem12-q5.gguf"; minVram=11000; quant="q5_K"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q4"; file="saiga-nem12-q4.gguf"; minVram=10000; quant="q4_K"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4"; file="saiga-gem12-q4.gguf"; minVram=10000; quant="q4_K"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q8";   file="qvikhr-8b-q8.gguf";  minVram=11000; quant="q8_0"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-8b-q8";    file="saiga-8b-q8.gguf";   minVram=11000; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q5";   file="qvikhr-8b-q5.gguf";  minVram=9000;  quant="q5_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q5_k_m.gguf" }
        [PSCustomObject]@{ name="saiga-8b-q5";    file="saiga-8b-q5.gguf";   minVram=9000;  quant="q5_K"; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-mis7b-q5"; file="saiga-mis7b-q5.gguf"; minVram=8000; quant="q5_K"; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/saiga_mistral_7b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q8";   file="qvikhr-4b-q8.gguf";  minVram=6800;  quant="q8_0"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q4";   file="qvikhr-8b-q4.gguf";  minVram=6500;  quant="q4_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
        [PSCustomObject]@{ name="saiga-8b-q4";    file="saiga-8b-q4.gguf";   minVram=6500;  quant="q4_K"; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q5";   file="qvikhr-4b-q5.gguf";  minVram=5000;  quant="q5_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q5_k_m.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4";   file="qvikhr-4b-q4.gguf";  minVram=4000;  quant="q4_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
        [PSCustomObject]@{ name="qvikhr-1.7b-q8"; file="qvikhr-1.7b-q8.gguf"; minVram=3200; quant="q8_0"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1.7b-q4"; file="qvikhr-1.7b-q4.gguf"; minVram=2000; quant="q4_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
    )
    $budget = $vramMb - 1200
    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (!$best) { $best = $catalog | Select-Object -Last 1 }
    return $best
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY v13.4 (GPUs: $Gpus) ---" -ForegroundColor Cyan

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 2
    @("$W\bin","$W\bin_vulkan") | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
    }
    New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
    $tag = "b5248"

    # [1] System deps
    Write-Host "[1/7] System dependencies..." -ForegroundColor Yellow
    Install-Pkg "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime"
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (!$pyOk) {
        Write-Host "  Installing Python 3.12..." -ForegroundColor Yellow
        Install-Pkg "Python.Python.3.12" "Python 3.12"
        $pyExe = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($pyExe) { $env:PATH = "$((Split-Path $pyExe -Parent));$($env:PATH)" }
    }
    Write-Host "  Python: $(& python --version 2>&1)" -ForegroundColor Green

    # [2] CUDA DLLs
    Write-Host "[2/7] CUDA DLLs + huggingface-hub..." -ForegroundColor Yellow
    $cudaDllDir = "$W\cuda_dlls"
    New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
    & python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
    & python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
    & python -m pip install --quiet huggingface-hub 2>&1 | Out-Null
    $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
    Write-Host "  CUDA DLLs: $($cudaDlls.Count) | hf-hub: OK" -ForegroundColor Green

    # [3] Engine
    Write-Host "[3/7] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
    curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
    Expand-Archive "$W\engine.zip" "$W\bin" -Force
    Remove-Item "$W\engine.zip"
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $binDir  = Split-Path $exePath -Parent
    Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
        if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force }
    }
    $cudaDlls | ForEach-Object { Copy-Item $_.FullName $binDir -Force }
    Write-Host "  DLLs in bin: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green

    # [4] Test engine
    Write-Host "[4/7] Testing engine..." -ForegroundColor Yellow
    $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
    if ($p.ExitCode -ne 0) {
        Write-Host "  CUDA failed, switching to Vulkan..." -ForegroundColor Yellow
        curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
        Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
        Remove-Item "$W\vk.zip"
        $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Write-Host "  Using Vulkan" -ForegroundColor Yellow
    } else { Write-Host "  CUDA OK!" -ForegroundColor Green }

    # [5] GPU detection + multi-GPU selection
    Write-Host "[5/7] Detecting GPUs (mode: -Gpus $Gpus)..." -ForegroundColor Yellow
    Start-Process $exePath "--list-devices" -Wait -NoNewWindow -RedirectStandardOutput "$W\do.txt" -RedirectStandardError "$W\de.txt" -ErrorAction SilentlyContinue
    $devLines = @()
    if (Test-Path "$W\do.txt") { $devLines += Get-Content "$W\do.txt" }
    if (Test-Path "$W\de.txt") { $devLines += Get-Content "$W\de.txt" }
    $devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    $allDevices = @()
    foreach ($line in $devLines) {
        if ($line -match "^\s*([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB") {
            $allDevices += [PSCustomObject]@{
                name  = $Matches[1]
                label = $Matches[2]
                vram  = [int]$Matches[3]
            }
        }
    }
    # Sort: RTX first, then by VRAM descending
    $allDevices = @($allDevices | Sort-Object @{Expression={if($_.label -match "RTX"){0}else{1}}}, @{Expression={-$_.vram}})

    $selectedDevices = @()
    $gpuMode = $Gpus.ToLower().Trim()
    if ($gpuMode -eq "all") {
        $selectedDevices = $allDevices
    } elseif ($gpuMode -match "^\d+$") {
        $n = [int]$gpuMode
        $selectedDevices = @($allDevices | Select-Object -First $n)
    } else {
        $selectedDevices = @($allDevices | Select-Object -First 1)
    }
    if ($selectedDevices.Count -eq 0 -and $allDevices.Count -gt 0) {
        $selectedDevices = @($allDevices | Select-Object -First 1)
    }

    $totalVram  = ($selectedDevices | Measure-Object -Property vram -Sum).Sum
    $deviceList = ($selectedDevices | ForEach-Object { $_.name }) -join ","
    $deviceArg  = if ($deviceList) { "--device $deviceList" } else { "" }
    Write-Host "  Using: $deviceList | Total VRAM: $totalVram MiB" -ForegroundColor Green

    # [6] Model + quant
    Write-Host "[6/7] Selecting model for $totalVram MiB..." -ForegroundColor Yellow
    $candidate = Select-BestModel $totalVram
    Write-Host "  Best fit: $($candidate.name) ($($candidate.quant)) minVram=$($candidate.minVram) MiB" -ForegroundColor Cyan

    if ($totalVram -ge 32000)     { $ctxSize = 32768 }
    elseif ($totalVram -ge 22000) { $ctxSize = 24576 }
    elseif ($totalVram -ge 14000) { $ctxSize = 16384 }
    elseif ($totalVram -ge 9000)  { $ctxSize = 16384 }
    elseif ($totalVram -ge 6000)  { $ctxSize = 8192 }
    elseif ($totalVram -ge 3000)  { $ctxSize = 8192 }
    else                           { $ctxSize = 4096 }

    $m = "$W\models\$($candidate.file)"
    $existOk = (Test-Path $m) -and ((Get-Item $m -EA SilentlyContinue).Length -gt 100MB)
    if ($existOk) {
        $sizeMb = [math]::Round((Get-Item $m).Length / 1MB)
        Write-Host "  Cached: $($candidate.name) ($sizeMb MB)" -ForegroundColor Green
    } else {
        Write-Host "  Downloading $($candidate.name)..." -ForegroundColor Yellow
        $sz = Download-Model $candidate.url $m
        if ($sz -le 100MB) {
            Write-Host "  Download failed - trying q4 fallback..." -ForegroundColor Yellow
            Remove-Item $m -ErrorAction SilentlyContinue
            $fbUrl  = $candidate.url  -replace "q[5-8]_[K0](_[Mm])?", "q4_K_M"
            $fbFile = $candidate.file -replace "q[5-8]", "q4"
            $m = "$W\models\$fbFile"
            $sz = Download-Model $fbUrl $m
            if ($sz -le 100MB) { Write-Host "All downloads failed!" -ForegroundColor Red; exit 1 }
        }
        $sizeMb = [math]::Round($sz / 1MB)
        Write-Host "  Downloaded: $sizeMb MB" -ForegroundColor Green
    }
    Write-Host "  Model: $($candidate.name) | quant: $($candidate.quant) | ctx: $ctxSize" -ForegroundColor Green

    # [7] Start server
    Write-Host "[7/7] Starting server..." -ForegroundColor Yellow
    $cmd = "Set-Location $binDir; .\llama-server.exe --model $m --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --no-warmup > $W\server.log 2>&1"
    Write-Host "  CMD: $cmd" -ForegroundColor Gray
    [System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

    $ok = $false
    for ($i = 1; $i -le 80; $i++) {
        Start-Sleep -s 3
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $h = ($r.Content | ConvertFrom-Json).status
            Write-Host "  [$i] $h" -ForegroundColor Yellow
            if ($h -eq "ok" -or $h -eq "loading model") { $ok = $true; break }
        } catch { Write-Host "  [$i] waiting..." -ForegroundColor Gray }
    }

    if ($ok) {
        Write-Host "SUCCESS! http://localhost:8010/v1" -ForegroundColor Green
        Write-Host "  Model:   $($candidate.name) ($($candidate.quant))" -ForegroundColor Green
        Write-Host "  GPUs:    $deviceList ($totalVram MiB)" -ForegroundColor Green
        Write-Host "  Context: $ctxSize tokens" -ForegroundColor Green
        $wdScript = "$W\watchdog.ps1"
        curl.exe -L "https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_watchdog.ps1" -o $wdScript --silent
        Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript
        Write-Host "Watchdog started." -ForegroundColor Cyan
        Write-Host "Stop: powershell -EP Bypass -File win_deploy.ps1 --stop" -ForegroundColor Gray
    } else {
        Write-Host "FAILED. Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
        else { Write-Host "(no log)" -ForegroundColor Red }
    }
}

# =============================================================================
# MAIN
# =============================================================================
switch ($Action) {
    { $_ -in "--stop",    "stop"    } { Invoke-Stop }
    { $_ -in "--status",  "status"  } { Invoke-Status }
    { $_ -in "--restart", "restart" } { Invoke-Stop; Start-Sleep -s 3; Invoke-Deploy }
    default                           { Invoke-Deploy }
}
