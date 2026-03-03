# LLM WIN DEPLOY v13.3 - smart quant selection
param(
    [string]$Action = "--deploy",
    [string]$Gpus   = "1"   # "1"=best single GPU, "2"/"3"/...=N GPUs, "all"=all GPUs
)
if ($args.Count -gt 0 -and $Action -eq "--deploy") { $Action = $args[0] }

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$W = "$env:USERPROFILE\llm_native"

# ── STOP ─────────────────────────────────────────────────────────────────────
function Invoke-Stop {
    Write-Host "Stopping LLM server and watchdog..." -ForegroundColor Yellow
    $killed = 0
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue; $killed++
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

# ── STATUS ────────────────────────────────────────────────────────────────────
function Invoke-Status {
    Write-Host "── LLM STATUS ──────────────────────────────" -ForegroundColor Cyan
    $proc = Get-Process | Where-Object { $_.Name -match "llama" }
    if ($proc) { Write-Host "  llama-server: RUNNING (PID $($proc.Id))" -ForegroundColor Green }
    else        { Write-Host "  llama-server: NOT RUNNING" -ForegroundColor Red }
    $wd = Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
    }
    if ($wd) { Write-Host "  watchdog:     RUNNING (PID $($wd.ProcessId))" -ForegroundColor Green }
    else      { Write-Host "  watchdog:     NOT RUNNING" -ForegroundColor Yellow }
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $h = ($r.Content | ConvertFrom-Json).status
        Write-Host "  API health:   $h" -ForegroundColor Green
        Write-Host "  API URL:      http://localhost:8010/v1" -ForegroundColor Green
    } catch { Write-Host "  API health:   unreachable" -ForegroundColor Red }
    $wlog = "$W\watchdog.log"
    if (Test-Path $wlog) {
        Write-Host ""
        Write-Host "  Last watchdog entries:" -ForegroundColor Gray
        Get-Content $wlog -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    Write-Host "────────────────────────────────────────────" -ForegroundColor Cyan
}

# ── DEPLOY ────────────────────────────────────────────────────────────────────
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY ---" -ForegroundColor Cyan

    function Install-IfMissing($id, $label) {
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
        return (if (Test-Path $dest) { (Get-Item $dest).Length } else { 0 })
    }

    # ── Выбор лучшего quant по VRAM ─────────────────────────────────────────
    # Возвращает PSCustomObject {name, file, url, minVram} с наилучшим квантом
    # который влезает в доступную память
    function Select-BestModel($vramMb) {
        # Таблица: каждая запись = один вариант (модель + quant)
        # Отсортировано от лучшего к худшему quality
        # minVram = минимум VRAM в МБ с учётом KV-кеша и overhead
        $catalog = @(
            # Каталог отсортирован от лучшего к худшему.
            # Философия: лучше маленькая модель с точным квантом, чем большая с плохим.
            # q8_0=отличное, q6_K=отличное, q5_K=хорошее, q4_K=ok
            # minVram = модель + 1.8GB (overhead + минимальный KV-кеш)

            # ── 12b, 32GB+ → q8_0 lossless ─────────────────────────────────
            [PSCustomObject]@{ name="saiga-nem12-q8";  file="saiga-nem12-q8.gguf";  minVram=31800; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q8_0.gguf" }
            [PSCustomObject]@{ name="saiga-gem12-q8";  file="saiga-gem12-q8.gguf";  minVram=31800; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q8_0.gguf" }
            # ── 12b, 22GB+ → q8_0 ──────────────────────────────────────────
            [PSCustomObject]@{ name="saiga-nem12-q8";  file="saiga-nem12-q8.gguf";  minVram=22000; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q8_0.gguf" }
            [PSCustomObject]@{ name="saiga-gem12-q8";  file="saiga-gem12-q8.gguf";  minVram=22000; quant="q8_0"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q8_0.gguf" }
            # ── 12b, 14GB+ → q6_K отличное ──────────────────────────────────
            [PSCustomObject]@{ name="saiga-nem12-q6";  file="saiga-nem12-q6.gguf";  minVram=14000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q6_K.gguf" }
            [PSCustomObject]@{ name="saiga-gem12-q6";  file="saiga-gem12-q6.gguf";  minVram=14000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q6_K.gguf" }
            # ── 12b, 11GB+ → q6_K (KV tight but ok) ────────────────────────
            [PSCustomObject]@{ name="saiga-nem12-q6";  file="saiga-nem12-q6.gguf";  minVram=11000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/model-q6_K.gguf" }
            [PSCustomObject]@{ name="saiga-gem12-q6";  file="saiga-gem12-q6.gguf";  minVram=11000; quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/model-q6_K.gguf" }
            # ── 8b, 9.5GB+ → q6_K отличное ──────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-8b-q6";    file="qvikhr-8b-q6.gguf";   minVram=9500;  quant="q6_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q6_k.gguf" }
            [PSCustomObject]@{ name="saiga-8b-q6";     file="saiga-8b-q6.gguf";    minVram=9500;  quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q6_K.gguf" }
            # ── 7b, 8.5GB+ → q6_K отличное ──────────────────────────────────
            [PSCustomObject]@{ name="saiga-mis7b-q6";  file="saiga-mis7b-q6.gguf"; minVram=8500;  quant="q6_K"; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/model-q6_K.gguf" }
            # ── 4b, 6.8GB+ → q8_0 отличное (лучше чем 8b q5 на 8GB!) ───────
            [PSCustomObject]@{ name="qvikhr-4b-q8";    file="qvikhr-4b-q8.gguf";   minVram=6800;  quant="q8_0"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q8_0.gguf" }
            # ── 4b, 5.5GB+ → q6_K отличное ──────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-4b-q6";    file="qvikhr-4b-q6.gguf";   minVram=5500;  quant="q6_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q6_k.gguf" }
            # ── 4b, 4.5GB+ → q5_K хорошее ───────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-4b-q5";    file="qvikhr-4b-q5.gguf";   minVram=4500;  quant="q5_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q5_k_m.gguf" }
            # ── 1.7b, 3.5GB+ → q8_0 отличное ────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-1.7b-q8";  file="qvikhr-1.7b-q8.gguf"; minVram=3500;  quant="q8_0"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q8_0.gguf" }
            # ── 1.7b, 2.5GB+ → q6_K отличное ────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-1.7b-q6";  file="qvikhr-1.7b-q6.gguf"; minVram=2500;  quant="q6_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q6_k.gguf" }
            # ── fallback ─────────────────────────────────────────────────────
            [PSCustomObject]@{ name="qvikhr-1.7b-q4";  file="qvikhr-1.7b-q4.gguf"; minVram=1800;  quant="q4_K"; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
        )        )
        # Берём лучший (первый) который влезает по VRAM
        $available = $vramMb - 1200  # запас 1.2GB на KV-кеш и overhead
        $best = $catalog | Where-Object { $_.minVram -le $available } | Select-Object -First 1
        if (!$best) { $best = $catalog | Select-Object -Last 1 }
        return $best
    }

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 2
    @("$W\bin","$W\bin_vulkan") | ForEach-Object { if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue } }
    New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
    $tag = "b5248"

    Write-Host "[1/7] System dependencies..." -ForegroundColor Yellow
    Install-IfMissing "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime"
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (!$pyOk) {
        Write-Host "  Installing Python..." -ForegroundColor Yellow
        Install-IfMissing "Python.Python.3.12" "Python 3.12"
        $pyExe = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($pyExe) { $env:PATH = "$((Split-Path $pyExe -Parent));$($env:PATH)" }
    }
    Write-Host "  Python: $(& python --version 2>&1)" -ForegroundColor Green

    Write-Host "[2/7] CUDA DLLs + huggingface-hub..." -ForegroundColor Yellow
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
    Write-Host "  DLLs: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green

    Write-Host "[4/7] Testing engine..." -ForegroundColor Yellow
    $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
    if ($p.ExitCode -ne 0) {
        Write-Host "  CUDA failed, falling back to Vulkan..." -ForegroundColor Yellow
        curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
        Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force; Remove-Item "$W\vk.zip"
        $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Using Vulkan" -ForegroundColor Yellow
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

    # ── Multi-GPU mode ───────────────────────────────────────────────────────
    # Собираем все устройства из --list-devices вывода
    $allDevices = @()
    foreach ($line in $devLines) {
        if ($line -match "^\s*([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB") {
            $allDevices += [PSCustomObject]@{ name=$Matches[1]; label=$Matches[2]; vram=[int]$Matches[3] }
        }
    }
    # Сортируем: RTX первыми, потом по VRAM убыванию
    $allDevices = $allDevices | Sort-Object { if ($_.label -match "RTX") { 0 } else { 1 } }, { -$_.vram }

    $gpuMode = $Gpus.ToLower()
    $selectedDevices = @()
    if ($gpuMode -eq "all") {
        $selectedDevices = $allDevices
    } elseif ($gpuMode -match "^\d+$") {
        $n = [int]$gpuMode
        $selectedDevices = $allDevices | Select-Object -First $n
    } else {
        $selectedDevices = @($allDevices | Where-Object { $_.name -eq $bestDevice })
    }
    if (!$selectedDevices -or $selectedDevices.Count -eq 0) {
        $selectedDevices = @($allDevices | Select-Object -First 1)
    }

    $totalVram = ($selectedDevices | Measure-Object -Property vram -Sum).Sum
    $deviceList = ($selectedDevices | ForEach-Object { $_.name }) -join ","
    $deviceArg = if ($deviceList) { "--device $deviceList" } else { "" }

    Write-Host "  GPU mode: --gpus $Gpus | Using: $deviceList | Total VRAM: $totalVram MiB" -ForegroundColor Green
    # Переопределяем bestVram как суммарный VRAM выбранных карт
    $bestVram = $totalVram

    Write-Host "[6/7] Selecting best model + quant for $bestVram MiB..." -ForegroundColor Yellow
    $candidate = Select-BestModel $bestVram
    Write-Host "  Best fit: $($candidate.name) ($($candidate.quant)) — needs $($candidate.minVram) MiB" -ForegroundColor Cyan

    # Контекст под VRAM
    if ($bestVram -ge 32000)     { $ctxSize = 32768 }
    elseif ($bestVram -ge 22000) { $ctxSize = 24576 }
    elseif ($bestVram -ge 14000) { $ctxSize = 16384 }
    elseif ($bestVram -ge 9000)  { $ctxSize = 16384 }
    elseif ($bestVram -ge 6000)  { $ctxSize = 8192 }
    elseif ($bestVram -ge 3000)  { $ctxSize = 8192 }
    else                          { $ctxSize = 4096 }

    $m = "$W\models\$($candidate.file)"
    if ((Test-Path $m) -and ((Get-Item $m -EA SilentlyContinue).Length -gt 100MB)) {
        Write-Host "  Cached: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
    } else {
        Write-Host "  Downloading $($candidate.name)..." -ForegroundColor Yellow
        $sz = Download-Model $candidate.url $m
        if ($sz -le 100MB) {
            Write-Host "  Download failed ($sz bytes), falling back to q4..." -ForegroundColor Yellow
            Remove-Item $m -ErrorAction SilentlyContinue
            # Fallback: ищем ближайший q4 вариант той же или меньшей модели
            $fallbackUrl = $candidate.url -replace "q[5-8]_[K0](_[Mm])?", "q4_K"
            $fallbackFile = $candidate.file -replace "q[5-8]", "q4"
            $m = "$W\models\$fallbackFile"
            $sz = Download-Model $fallbackUrl $m
            if ($sz -le 100MB) { Write-Host "All downloads failed!" -ForegroundColor Red; exit 1 }
        }
        Write-Host "  Downloaded: $([math]::Round($sz/1MB))MB" -ForegroundColor Green
    }
    Write-Host "  Model: $($candidate.name) | quant: $($candidate.quant) | ctx: $ctxSize" -ForegroundColor Green

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
        Write-Host "SUCCESS! http://localhost:8010/v1 | $($candidate.name) ($($candidate.quant)) | $bestDevice ($bestVram MiB) | ctx $ctxSize" -ForegroundColor Green
        $wdScript = "$W\watchdog.ps1"
        curl.exe -L "https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_watchdog.ps1" -o $wdScript --silent
        Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript
        Write-Host "Watchdog started. Commands:" -ForegroundColor Cyan
        Write-Host "  Status:  powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor White
        Write-Host "  Stop:    powershell -EP Bypass -File win_deploy.ps1 --stop" -ForegroundColor White
    } else {
        Write-Host "FAILED. Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    }
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
switch ($Action) {
    { $_ -in "--stop",    "stop",    "-stop"    } { Invoke-Stop   }
    { $_ -in "--status",  "status",  "-status"  } { Invoke-Status }
    { $_ -in "--restart", "restart", "-restart" } { Invoke-Stop; Start-Sleep -s 3; Invoke-Deploy }
    default                                        { Invoke-Deploy }
}
