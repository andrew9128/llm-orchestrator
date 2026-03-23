# LLM WIN DEPLOY
# Modes: chat | voice | doc | full | code
# Ports: LLM 8010->18010  ASR 8011->18011  OCR 8013->18013  Embed 8014->18014
# All services: wake on demand, sleep on idle, via proxy
param(
    [string]$Action = "--deploy",
    [string]$Gpus   = "1",
    [string]$Mode   = "chat"
)
if ($args.Count -gt 0 -and $Action -eq "--deploy") { $Action = $args[0] }

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$W = "$env:USERPROFILE\llm_native"

$IDLE_LLM   = 600
$IDLE_ASR   = 300
$IDLE_OCR   = 300
$IDLE_EMBED = 900

# =============================================================================
# STOP
# =============================================================================
function Invoke-Stop {
    Write-Host "Stopping all services..." -ForegroundColor Yellow
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -EA SilentlyContinue
        Write-Host "  Stopped $($_.Name) PID $($_.Id)" -ForegroundColor Green
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "proxy_service|asr_service|ocr_service|embed_service|run_llm|watchdog"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
    }
    foreach ($port in 8010, 8011, 8013, 8014, 18010, 18011, 18013, 18014) {
        try {
            $conn = Get-NetTCPConnection -LocalPort $port -EA SilentlyContinue | Where-Object State -eq "Listen" | Select-Object -First 1
            if ($conn -and $conn.OwningProcess -gt 4) {
                Stop-Process -Id $conn.OwningProcess -Force -EA SilentlyContinue
                Write-Host "  Freed port $port" -ForegroundColor Green
            }
        } catch {}
    }
    Remove-Item "$W\*.trigger" -EA SilentlyContinue
    Start-Sleep -s 2
    Write-Host "Done." -ForegroundColor Green
}

# =============================================================================
# STATUS
# =============================================================================
function Invoke-Status {
    Write-Host "--- LLM ORCHESTRATOR STATUS ---" -ForegroundColor Cyan
    $portMap = @{
        8010="LLM"
        8011="ASR (GigaAM-v3 ONNX)"
        8013="OCR (RapidOCR ONNX)"
        8014="Embed (multilingual-e5 ONNX)"
    }
    foreach ($port in 8010, 8011, 8013, 8014) {
        $st = ""
        try {
            $r = [System.Net.HttpWebRequest]::Create("http://localhost:$port/health")
            $r.Timeout = 3000; $r.Method = "GET"
            try {
                $rsp = $r.GetResponse()
                $sr = [System.IO.StreamReader]::new($rsp.GetResponseStream())
                $st = ($sr.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                $sr.Close(); $rsp.Close()
            } catch [System.Net.WebException] {
                $wr = $_.Exception.Response
                if ($wr) {
                    $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                    $st = ($sr2.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                    $sr2.Close()
                }
            }
        } catch {}
        $color = switch ($st) { "ok" {"Green"} "loading" {"Yellow"} "stopped" {"Yellow"} default {"Red"} }
        if (-not $st) { $st = "NOT RUNNING" }
        Write-Host "  $($portMap[$port]) [$port]: $st" -ForegroundColor $color
    }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)")   { Write-Host "  Model:   $($Matches[1])" -ForegroundColor Cyan }
        if ($run -match "--ctx-size\s+(\d+)") { Write-Host "  Context: $($Matches[1]) tokens" -ForegroundColor Cyan }
    }
}

# =============================================================================
# STAMPS
# =============================================================================
function Get-Stamp($name) {
    $f = "$W\stamp_$name.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Set-Stamp($name, $value) { $value | Out-File "$W\stamp_$name.txt" -Encoding UTF8 -NoNewline }

# =============================================================================
# HELPERS
# =============================================================================
function Install-Pkg($pkgId, $label) {
    Write-Host "  Checking $label..." -ForegroundColor Gray
    & winget install -e --id $pkgId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Download-File($url, $dest, $label) {
    Remove-Item $dest -EA SilentlyContinue
    Write-Host "  Downloading $label..." -ForegroundColor Cyan
 
    # Определить прокси-аргументы
    $proxyArgs = @()
    $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if ($sysProxy) {
        $proxyUri = $sysProxy.GetProxy([uri]$url)
        if ($proxyUri -and $proxyUri.AbsoluteUri -ne $url) {
            $proxyArgs = @("--proxy", $proxyUri.AbsoluteUri)
            Write-Host "  Using system proxy: $($proxyUri.AbsoluteUri)" -ForegroundColor Gray
        }
    }
 
    # Попытка 1: оригинальный URL (HuggingFace)
    & curl.exe -L --retry 3 --retry-delay 5 --connect-timeout 60 --max-time 3600 `
        --ssl-no-revoke -H "User-Agent: Mozilla/5.0" `
        @proxyArgs "$url" -o "$dest"
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1KB) {
        Write-Host "  OK!" -ForegroundColor Green; return $true
    }
    Remove-Item $dest -EA SilentlyContinue
 
    # Попытка 2: hf-mirror.com
    $mirror1 = $url -replace "huggingface\.co","hf-mirror.com"
    if ($mirror1 -ne $url) {
        Write-Host "  Trying hf-mirror.com..." -ForegroundColor Yellow
        & curl.exe -L --retry 3 --retry-delay 5 --connect-timeout 60 --max-time 3600 `
            --ssl-no-revoke -H "User-Agent: Mozilla/5.0" `
            @proxyArgs "$mirror1" -o "$dest"
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1KB) {
            Write-Host "  OK (hf-mirror)!" -ForegroundColor Green; return $true
        }
        Remove-Item $dest -EA SilentlyContinue
    }
 
    # Попытка 3: ModelScope (URL передаётся снаружи через $msUrl)
    # (см. Select-BestModel — каждая модель имеет msUrl)
    return $false
}

function Pip-Install($pkg, $stampKey) {
    $pkgName = ($pkg -split "==|>=|<=|~=|\[")[0] -replace "[^a-zA-Z0-9_-]",""
    $installed = ("" + (& python -m pip show $pkgName 2>$null | Select-String "^Version:")).Trim() -replace "(?i)version:\s*",""
    $stamp = Get-Stamp $stampKey
    if ($installed -and $stamp -eq $installed) {
        Write-Host "  $pkgName $installed (cached)" -ForegroundColor Green
        return $installed
    }
    Write-Host "  Installing $pkg..." -ForegroundColor Gray
    & python -m pip install --quiet --prefer-binary $pkg 2>&1 | Out-Null
    $installed = ("" + (& python -m pip show $pkgName 2>$null | Select-String "^Version:")).Trim() -replace "(?i)version:\s*",""
    if ($installed) { Set-Stamp $stampKey $installed }
    return $installed
}

function Get-CtxSize($vramMb) {
    if ($vramMb -ge 32000) { return 32768 }
    if ($vramMb -ge 22000) { return 24576 }
    if ($vramMb -ge 14000) { return 16384 }
    if ($vramMb -ge 9000)  { return 16384 }
    if ($vramMb -ge 6000)  { return 8192 }
    return 8192
}

function Get-FreeSpaceGb($path) {
    try {
        $drive = (Split-Path $path -Qualifier).TrimEnd(':')
        $d = Get-PSDrive -Name $drive -EA SilentlyContinue
        if ($d -and $d.Free) { return [math]::Round($d.Free / 1GB, 1) }
        $wmi = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${drive}:'" -EA SilentlyContinue
        if ($wmi) { return [math]::Round($wmi.FreeSpace / 1GB, 1) }
    } catch {}
    return 999
}

function Get-FreeRamGb {
    try {
        $os = Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue
        if ($os) { return [math]::Round($os.FreePhysicalMemory / 1MB, 1) }
    } catch {}
    return 999
}

function Download-Model($hfUrl, $msUrl, $dest, $label) {
    # Пробуем HF + зеркала через Download-File
    if (Download-File $hfUrl $dest $label) { return $true }
 
    # Попытка 4: ModelScope
    if ($msUrl) {
        Write-Host "  Trying ModelScope..." -ForegroundColor Yellow
        $proxyArgs = @()
        $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        if ($sysProxy) {
            $proxyUri = $sysProxy.GetProxy([uri]$msUrl)
            if ($proxyUri -and $proxyUri.AbsoluteUri -ne $msUrl) {
                $proxyArgs = @("--proxy", $proxyUri.AbsoluteUri)
            }
        }
        & curl.exe -L --retry 3 --retry-delay 5 --connect-timeout 60 --max-time 3600 `
            --ssl-no-revoke -H "User-Agent: Mozilla/5.0" `
            @proxyArgs "$msUrl" -o "$dest"
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1KB) {
            Write-Host "  OK (ModelScope)!" -ForegroundColor Green; return $true
        }
        Remove-Item $dest -EA SilentlyContinue
    }
 
    return $false
}

# =============================================================================
# MODEL CATALOG  (hf= HuggingFace,  ms= ModelScope)
# Размеры в байтах взяты из ModelScope (SHA256 верифицированы)
# =============================================================================
function Select-BestModel($vramMb, $deployMode, $freeVramMb = 0, $freeDiskGb = 999) {
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{
            name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3000; sizeGb=2.1
            hf="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf"
            ms=$null
        }
    }
 
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 700 }
    if ($deployMode -eq "doc")   { $specialMb = 100 }
    if ($deployMode -eq "full")  { $specialMb = 700 }
    $effectiveVram = if ($freeVramMb -gt 200) { $freeVramMb } else { [int]($vramMb * 0.80) }
    $budget = $effectiveVram - 800 - $specialMb
 
    # ms-URL формат: https://modelscope.cn/models/{owner}/{repo}/resolve/master/{file}
    $MS = "https://modelscope.cn/models"
 
    $catalog = @(
        # ── T-pro 32B ──────────────────────────────────────────────────────────
        [PSCustomObject]@{
            name="t-pro-2.0-q8"; file="t-pro-2.0-q8.gguf"; minVram=36000; sizeGb=32.44
            hf="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf"
            ms="$MS/t-tech/T-pro-it-2.0-GGUF/resolve/master/T-pro-it-2.0-Q8_0.gguf"
        }
        [PSCustomObject]@{
            name="t-pro-2.0-q6"; file="t-pro-2.0-q6.gguf"; minVram=27000; sizeGb=25.04
            hf="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf"
            ms="$MS/t-tech/T-pro-it-2.0-GGUF/resolve/master/T-pro-it-2.0-Q6_K.gguf"
        }
        [PSCustomObject]@{
            name="t-pro-2.0-q5"; file="t-pro-2.0-q5.gguf"; minVram=23000; sizeGb=21.63
            hf="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf"
            ms="$MS/t-tech/T-pro-it-2.0-GGUF/resolve/master/T-pro-it-2.0-Q5_K_M.gguf"
        }
        [PSCustomObject]@{
            name="t-pro-2.0-q4"; file="t-pro-2.0-q4.gguf"; minVram=19000; sizeGb=18.41
            hf="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf"
            ms="$MS/t-tech/T-pro-it-2.0-GGUF/resolve/master/T-pro-it-2.0-Q4_K_M.gguf"
        }
        # ── Saiga Gemma3 12B  (только HF, на ModelScope нет) ───────────────────
        [PSCustomObject]@{
            name="saiga-gem12-q8"; file="saiga-gem12-q8.gguf"; minVram=14500; sizeGb=13.77
            hf="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf"
            ms=$null
        }
        [PSCustomObject]@{
            name="saiga-gem12-q6"; file="saiga-gem12-q6.gguf"; minVram=11000; sizeGb=10.62
            hf="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf"
            ms=$null
        }
        [PSCustomObject]@{
            name="saiga-gem12-q5"; file="saiga-gem12-q5.gguf"; minVram=9500; sizeGb=9.26
            hf="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf"
            ms=$null
        }
        [PSCustomObject]@{
            name="saiga-gem12-q4"; file="saiga-gem12-q4.gguf"; minVram=7800; sizeGb=7.73
            hf="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf"
            ms=$null
        }
        # ── Saiga Nemo 12B ─────────────────────────────────────────────────────
        [PSCustomObject]@{
            name="saiga-nem12-q6"; file="saiga-nem12-q6.gguf"; minVram=11000; sizeGb=9.37
            hf="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf"
            ms="$MS/QuantFactory/saiga_nemo_12b-GGUF/resolve/master/saiga_nemo_12b.Q6_K.gguf"
        }
        [PSCustomObject]@{
            name="saiga-nem12-q5"; file="saiga-nem12-q5.gguf"; minVram=9500; sizeGb=8.13
            hf="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf"
            ms="$MS/QuantFactory/saiga_nemo_12b-GGUF/resolve/master/saiga_nemo_12b.Q5_K_M.gguf"
        }
        [PSCustomObject]@{
            name="saiga-nem12-q4"; file="saiga-nem12-q4.gguf"; minVram=7800; sizeGb=6.97
            hf="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf"
            ms="$MS/QuantFactory/saiga_nemo_12b-GGUF/resolve/master/saiga_nemo_12b.Q4_K_M.gguf"
        }
        # ── T-lite 2.1 8B ──────────────────────────────────────────────────────
        [PSCustomObject]@{
            name="t-lite-2.1-q8"; file="t-lite-2.1-q8.gguf"; minVram=10000; sizeGb=8.11
            hf="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q8_0.gguf"
            ms="$MS/t-tech/T-lite-it-2.1-GGUF/resolve/master/T-lite-it-2.1-Q8_0.gguf"
        }
        [PSCustomObject]@{
            name="t-lite-2.1-q6"; file="t-lite-2.1-q6.gguf"; minVram=8200; sizeGb=6.27
            hf="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q6_K.gguf"
            ms="$MS/t-tech/T-lite-it-2.1-GGUF/resolve/master/T-lite-it-2.1-Q6_K.gguf"
        }
        [PSCustomObject]@{
            name="t-lite-2.1-q5"; file="t-lite-2.1-q5.gguf"; minVram=6500; sizeGb=5.45
            hf="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q5_K_M.gguf"
            ms="$MS/t-tech/T-lite-it-2.1-GGUF/resolve/master/T-lite-it-2.1-Q5_K_M.gguf"
        }
        [PSCustomObject]@{
            name="t-lite-2.1-q4"; file="t-lite-2.1-q4.gguf"; minVram=5200; sizeGb=4.68
            hf="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q4_K_M.gguf"
            ms="$MS/t-tech/T-lite-it-2.1-GGUF/resolve/master/T-lite-it-2.1-Q4_K_M.gguf"
        }
        # ── YandexGPT 5 Lite 8B ────────────────────────────────────────────────
        [PSCustomObject]@{
            name="yagpt-8b-q8"; file="yagpt-8b-q8.gguf"; minVram=10000; sizeGb=8.19
            hf="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf"
            ms=$null
        }
        [PSCustomObject]@{
            name="yagpt-8b-q4"; file="yagpt-8b-q4.gguf"; minVram=5200; sizeGb=4.58
            hf="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf"
            ms="$MS/yandex/YandexGPT-5-Lite-8B-instruct-GGUF/resolve/master/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf"
        }
        # ── QVikhr 4B ──────────────────────────────────────────────────────────
        [PSCustomObject]@{
            name="qvikhr-4b-q8"; file="qvikhr-4b-q8.gguf"; minVram=5200; sizeGb=3.99
            hf="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf"
            ms="$MS/prithivMLmods/QVikhr-3-4B-it-F32-GGUF/resolve/master/QVikhr-3-4B-it-F32-Q8_0.gguf"
        }
        [PSCustomObject]@{
            name="qvikhr-4b-q5"; file="qvikhr-4b-q5.gguf"; minVram=4000; sizeGb=2.69
            hf="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf"
            ms="$MS/prithivMLmods/QVikhr-3-4B-it-F32-GGUF/resolve/master/QVikhr-3-4B-it-F32-Q5_0.gguf"
        }
        [PSCustomObject]@{
            name="qvikhr-4b-q4"; file="qvikhr-4b-q4.gguf"; minVram=3400; sizeGb=2.33
            hf="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf"
            ms="$MS/prithivMLmods/QVikhr-3-4B-it-F32-GGUF/resolve/master/QVikhr-3-4B-it-F32-Q4_K_M.gguf"
        }
        # ── QVikhr 1.7B ────────────────────────────────────────────────────────
        [PSCustomObject]@{
            name="qvikhr-1b-q8"; file="qvikhr-1b-q8.gguf"; minVram=2200; sizeGb=1.71
            hf="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf"
            ms="$MS/Vikhrmodels/QVikhr-3-1.7B-Instruction-noreasoning-GGUF/resolve/master/QVikhr-3-1.7B-Instruction-noreasoning-Q8_0.gguf"
        }
        [PSCustomObject]@{
            name="qvikhr-1b-q4"; file="qvikhr-1b-q4.gguf"; minVram=1800; sizeGb=0.98
            hf="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf"
            ms="$MS/Vikhrmodels/QVikhr-3-1.7B-Instruction-noreasoning-GGUF/resolve/master/QVikhr-3-1.7B-Instruction-noreasoning-Q4_K_M.gguf"
        }
    )
 
    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (-not $best) {
        Write-Host "  WARNING: budget ${budget}MB too low, using smallest" -ForegroundColor Yellow
        $best = $catalog | Select-Object -Last 1
    }
    if ($freeDiskGb -lt 990) {
        $best = $catalog | Where-Object { $_.minVram -le $budget -and $_.sizeGb -le ($freeDiskGb - 1.5) } | Select-Object -First 1
        if (-not $best) {
            Write-Host "  WARN: disk ${freeDiskGb}GB free. Trying smallest model..." -ForegroundColor Red
            $best = $catalog | Where-Object { $_.sizeGb -le ($freeDiskGb - 1.5) } | Sort-Object sizeGb | Select-Object -First 1
        }
    }
    if (-not $best) {
        Write-Host "  WARNING: budget ${budget}MB too low, using smallest" -ForegroundColor Yellow
        $best = $catalog | Select-Object -Last 1
    }
    return $best
}

# =============================================================================
# PROXY SCRIPT  (wake-on-demand + idle-shutdown + "stopped" health)
# =============================================================================
function Write-ProxyScript {
    $script = @'
import sys, os, time, json, subprocess, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen, Request
from urllib.error import URLError

PUB_PORT     = int(sys.argv[1])
INT_PORT     = int(sys.argv[2])
SVC_NAME     = sys.argv[3]
SVC_SCRIPT   = sys.argv[4]
W            = sys.argv[5]
IDLE_TIMEOUT = int(sys.argv[6]) if len(sys.argv) > 6 else 0
LOG          = os.path.join(W, 'watchdog.log')

last_req = [time.time()]
_child   = [None]

def plog(m):
    ts = time.strftime('%H:%M:%S')
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(f'[{ts}] [{SVC_NAME}] {m}\n')
    except: pass

def get_status():
    try:
        r = urlopen(f'http://localhost:{INT_PORT}/health', timeout=2)
        return json.loads(r.read()).get('status', 'unknown')
    except URLError as e:
        if hasattr(e, 'code'):
            try: return json.loads(e.read()).get('status', 'error')
            except: return 'error'
        return 'down'
    except: return 'down'

def start_service():
    plog(f'Waking on :{INT_PORT}')
    log_path = os.path.join(W, SVC_NAME.lower() + '_svc.log')
    err_path = os.path.join(W, SVC_NAME.lower() + '_err.log')
    _child[0] = subprocess.Popen(
        [sys.executable, SVC_SCRIPT],
        stdout=open(log_path, 'a'), stderr=open(err_path, 'a'),
        creationflags=0x08000000
    )

def stop_service():
    plog(f'Idle {IDLE_TIMEOUT}s -> stopping')
    if _child[0]:
        try: _child[0].terminate()
        except: pass
        _child[0] = None
    # kill llama-server if this is the LLM proxy
    try:
        subprocess.run(['taskkill', '/F', '/IM', 'llama-server.exe'],
                       capture_output=True, creationflags=0x08000000)
    except: pass

def wait_ready(timeout=300):
    t = 0
    while t < timeout:
        time.sleep(2); t += 2
        st = get_status()
        if st == 'ok': plog('UP'); return True
        if st not in ('loading', 'down', 'stopped', 'unknown'):
            plog(f'startup error: {st}'); return False
        if t % 30 == 0: plog(f'loading... {t}s')
    plog('timed out'); return False

def idle_watcher():
    if IDLE_TIMEOUT <= 0: return
    while True:
        time.sleep(15)
        if get_status() != 'ok': continue
        if time.time() - last_req[0] > IDLE_TIMEOUT:
            stop_service()

threading.Thread(target=idle_watcher, daemon=True).start()

def forward(handler, body_bytes):
    path = handler.path
    ct = handler.headers.get('Content-Type', '')
    try:
        req = Request(f'http://localhost:{INT_PORT}{path}',
                      data=body_bytes if body_bytes else None,
                      method=handler.command)
        if ct: req.add_header('Content-Type', ct)
        req.add_header('Content-Length', str(len(body_bytes) if body_bytes else 0))
        resp = urlopen(req, timeout=120)
        data = resp.read()
        handler.send_response(resp.status)
        handler.send_header('Content-Type', resp.headers.get('Content-Type', 'application/json'))
        handler.send_header('Content-Length', str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)
    except URLError as e:
        code = e.code if hasattr(e, 'code') else 503
        try: data = e.read()
        except: data = b'{"error":"upstream error"}'
        handler.send_response(code)
        handler.send_header('Content-Type', 'application/json')
        handler.send_header('Content-Length', str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)
    except Exception as ex:
        msg = json.dumps({'error': str(ex)}).encode()
        handler.send_response(500)
        handler.send_header('Content-Type', 'application/json')
        handler.send_header('Content-Length', str(len(msg)))
        handler.end_headers()
        handler.wfile.write(msg)

_start_lock = threading.Lock()

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def _read_body(self):
        cl = int(self.headers.get('Content-Length', 0))
        return self.rfile.read(cl) if cl > 0 else b''
    def do_GET(self):  self._handle()
    def do_POST(self): self._handle()
    def do_PUT(self):  self._handle()
    def _handle(self):
        if '/health' in self.path:
            st = get_status()
            # "down" -> "stopped" so clients know proxy is alive but service is sleeping
            if st in ('down', 'unknown', '') or not st: st = 'stopped'
            data = json.dumps({'status': st}).encode()
            code = 200 if st == 'ok' else 503
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        last_req[0] = time.time()
        body = self._read_body()
        st = get_status()
        if st not in ('ok', 'loading'):
            with _start_lock:
                if get_status() not in ('ok', 'loading'):
                    plog('Request -> waking service')
                    start_service()
            ok = wait_ready(300)
            if not ok:
                msg = b'{"error":"service failed to start"}'
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)
                return
        elif st == 'loading':
            wait_ready(300)
        forward(self, body)

plog(f'Proxy :{PUB_PORT} -> :{INT_PORT} idle={IDLE_TIMEOUT}s')
HTTPServer(('0.0.0.0', PUB_PORT), ProxyHandler).serve_forever()
'@
    $script | Out-File "$W\proxy_service.py" -Encoding UTF8
}

# =============================================================================
# SERVICE WRITERS
# =============================================================================
function Write-AsrService {
    $script = @"
import json, base64, tempfile, os, time, threading, soundfile as sf
from http.server import HTTPServer, BaseHTTPRequestHandler
import onnx_asr

_model = [None]
def _load():
    _model[0] = onnx_asr.load_model('gigaam-v3-e2e-rnnt')
threading.Thread(target=_load, daemon=True).start()

def transcribe(path):
    m = _model[0]
    audio, sr = sf.read(path, dtype='float32', always_2d=False)
    if audio.ndim > 1: audio = audio.mean(axis=1)
    for fn, args in [
        (getattr(m,'recognize',None), (audio,)),
        (getattr(m,'recognize',None), (audio, sr)),
        (getattr(m,'transcribe',None), (audio,)),
        (getattr(m,'transcribe_file',None), (path,)),
        (m if callable(m) else None, (audio,)),
        (m if callable(m) else None, (path,)),
    ]:
        if fn is None: continue
        try:
            r = fn(*args)
            if isinstance(r, str): return r
            if hasattr(r, 'text'): return r.text
            if hasattr(r, '__iter__'):
                return ' '.join(x.text for x in r if hasattr(x,'text'))
        except (TypeError, AttributeError): continue
    return 'ERROR: no API. methods=' + str([x for x in dir(m) if not x.startswith('_')])

class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a): pass
    def do_GET(self):
        st = 'ok' if _model[0] else 'loading'
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'status': st}).encode())
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n))
        audio = base64.b64decode(body.get('audio',''))
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
            f.write(audio); tmp = f.name
        try:
            text = transcribe(tmp) if _model[0] else 'ERROR: loading'
        except Exception as e: text = 'ERROR: ' + str(e)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
        self.send_response(200); self.send_header('Content-Type','application/json; charset=utf-8'); self.end_headers()
        self.wfile.write(json.dumps({'text': text}, ensure_ascii=False).encode('utf-8'))

HTTPServer(('0.0.0.0', 18011), H).serve_forever()
"@
    $script | Out-File "$W\asr_service.py" -Encoding UTF8
}

function Write-OcrService {
    $lines = @(
        "import sys, json, base64, tempfile, os, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'",
        "_ocr = [None]; ready = [False]; err_msg = [None]",
        "def load_model():",
        "    try:",
        "        from rapidocr import RapidOCR, LangRec, EngineType, OCRVersion",
        "        import onnxruntime as ort",
        "        use_gpu = 'CUDAExecutionProvider' in ort.get_available_providers()",
        "        cuda_engine = getattr(EngineType, 'CUDA', EngineType.ONNXRUNTIME)",
        "        _ocr[0] = RapidOCR(params={",
        "            'Rec.lang_type': LangRec.ESLAV,",
        "            'Rec.engine_type': cuda_engine if use_gpu else EngineType.ONNXRUNTIME,",
        "            'Rec.ocr_version': OCRVersion.PPOCRV5,",
        "            'Det.engine_type': cuda_engine if use_gpu else EngineType.ONNXRUNTIME,",
        "        })",
        "        if use_gpu: print('OCR: CUDA ESLAV PP-OCRv5', flush=True)",
        "        else: print('OCR: CPU ESLAV PP-OCRv5', flush=True)",
        "        ready[0] = True",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "def do_ocr(image_path):",
        "    result = _ocr[0](image_path)",
        "    if not result: return ''",
        "    txts = getattr(result, 'txts', None)",
        "    if txts: return chr(10).join(t for t in txts if t and t.strip())",
        "    if hasattr(result, '__iter__'):",
        "        rows = list(result)",
        "        if rows and isinstance(rows[0], (list,tuple)) and len(rows[0]) > 1:",
        "            return chr(10).join(r[1] for r in rows if r and len(r) > 1 and r[1])",
        "    return ''",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if '/health' in self.path:",
        "            self.send_response(200 if ready[0] else 503)",
        "            self.send_header('Content-Type','application/json'); self.end_headers()",
        "            st = 'ok' if ready[0] else ('error: '+err_msg[0][:100] if err_msg[0] else 'loading')",
        "            self.wfile.write(json.dumps({'status': st}).encode('utf-8'))",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode('utf-8')); return",
        "        n = int(self.headers.get('Content-Length', 0))",
        "        body = json.loads(self.rfile.read(n))",
        "        img = base64.b64decode(body.get('image', ''))",
        "        ext = body.get('ext', '.png')",
        "        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:",
        "            f.write(img); tmp = f.name",
        "        try: text = do_ocr(tmp)",
        "        except Exception as e: text = 'ERROR: ' + str(e)",
        "        finally: os.unlink(tmp)",
        "        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "        self.wfile.write(json.dumps({'text': text}).encode('utf-8'))",
        "threading.Thread(target=load_model, daemon=True).start()",
        "HTTPServer(('0.0.0.0', 18013), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\ocr_service.py" -Encoding UTF8 -NoNewline
}

function Write-EmbedService {
    $script = @"
import json, threading, traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
_model = [None]; _err = [None]

def _load():
    try:
        from fastembed import TextEmbedding
        _model[0] = TextEmbedding(
            'intfloat/multilingual-e5-large',
            providers=['CUDAExecutionProvider', 'CPUExecutionProvider']
        )
        print('Embed: multilingual-e5-large CUDA ready', flush=True)
    except Exception as e:
        _err[0] = str(e)
        print(f'Embed error: {e}', flush=True)

threading.Thread(target=_load, daemon=True).start()

class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a): pass
    def do_GET(self):
        st = 'ok' if _model[0] else ('error: '+_err[0] if _err[0] else 'loading')
        self.send_response(200 if _model[0] else 503)
        self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'status': st}).encode())
    def do_POST(self):
        if not _model[0]:
            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({'error': _err[0] or 'loading'}).encode()); return
        try:
            n = int(self.headers.get('Content-Length', 0))
            texts = json.loads(self.rfile.read(n))['input']
            if isinstance(texts, str): texts = [texts]
            vecs = list(_model[0].embed(texts))
            data = [{'index': i, 'embedding': v.tolist()} for i, v in enumerate(vecs)]
            out = json.dumps({'object':'list','data':data}, ensure_ascii=False).encode('utf-8')
            self.send_response(200); self.send_header('Content-Type','application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(out))); self.end_headers()
            self.wfile.write(out)
        except Exception as e:
            msg = json.dumps({'error': traceback.format_exc()}).encode()
            self.send_response(500); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(msg))); self.end_headers()
            self.wfile.write(msg)

HTTPServer(('0.0.0.0', 18014), H).serve_forever()
"@
    $script | Out-File "$W\embed_service.py" -Encoding UTF8
}

# =============================================================================
# HEALTH POLL
# =============================================================================
function Wait-ServiceReady($port, $label, $timeoutSec) {
    $t = 0
    while ($t -lt $timeoutSec) {
        Start-Sleep -s 3; $t += 3
        $st = ""
        try {
            $r = [System.Net.HttpWebRequest]::Create("http://localhost:$port/health")
            $r.Timeout = 5000; $r.Method = "GET"
            try {
                $rsp = $r.GetResponse()
                $sr = [System.IO.StreamReader]::new($rsp.GetResponseStream())
                $st = ($sr.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                $sr.Close(); $rsp.Close()
            } catch [System.Net.WebException] {
                $wr = $_.Exception.Response
                if ($wr) {
                    $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                    $st = ($sr2.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                    $sr2.Close()
                }
            }
        } catch {}
        if ($st -eq "ok") { Write-Host ("  [$label] ready ({0}s)" -f $t) -ForegroundColor Green; return $true }
        if ($st -and $st -ne "loading" -and $st -ne "down") { Write-Host "  [$label] status: $st" -ForegroundColor Red; return $false }
        if ($t % 30 -eq 0) { Write-Host ("  [$label] loading... {0}s" -f $t) -ForegroundColor Gray }
    }
    Write-Host "  [$label] timed out after ${timeoutSec}s" -ForegroundColor Red
    return $false
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM DEPLOY ff (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan

    Invoke-Stop
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    # [1] System deps
    Write-Host "[1/8] System dependencies..." -ForegroundColor Yellow
    Install-Pkg "Microsoft.VCRedist.2015+.x64" "Visual C++ Runtime"
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $pyOk) {
        Install-Pkg "Python.Python.3.12" "Python 3.12"
        $pyExe = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "python.exe" -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($pyExe) { $env:PATH = "$((Split-Path $pyExe -Parent));$($env:PATH)" }
    }
    Write-Host "  Python: $(& python --version 2>&1)" -ForegroundColor Green
    & python -m pip install --quiet --upgrade pip 2>&1 | Out-Null

    # [2] CUDA DLLs
    Write-Host "[2/8] CUDA DLLs..." -ForegroundColor Yellow
    $cudaDllDir = "$W\cuda_dlls"
    if ((Get-Stamp "cuda_dlls_cu128") -eq "ok" -and (Test-Path $cudaDllDir) -and (Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll" -EA SilentlyContinue).Count -gt 3) {
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Write-Host "  CUDA DLLs: cached ($($cudaDlls.Count) dlls)" -ForegroundColor Green
    } else {
        New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
        & python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Set-Stamp "cuda_dlls_cu128" "ok"
        Write-Host "  CUDA DLLs: $($cudaDlls.Count) installed" -ForegroundColor Green
    }

    # [3] Engine
    Write-Host "[3/8] llama-server engine..." -ForegroundColor Yellow
    $tag = "b5248"
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ((Get-Stamp "engine") -eq $tag -and $exePath -and (Test-Path $exePath)) {
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Engine cached ($tag)" -ForegroundColor Green
    } else {
        if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" -EA SilentlyContinue }
        New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
        Download-File "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" "$W\engine.zip" "llama.cpp CUDA" | Out-Null
        Expand-Archive "$W\engine.zip" "$W\bin" -Force
        Remove-Item "$W\engine.zip" -EA SilentlyContinue
        $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
            if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force -EA SilentlyContinue }
        }
        $cudaDlls | ForEach-Object { Copy-Item $_.FullName $binDir -Force -EA SilentlyContinue }
        Set-Stamp "engine" $tag
        Write-Host "  Engine installed. DLLs: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green
    }
    $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
    if ($p.ExitCode -ne 0) {
        Write-Host "  CUDA failed - trying Vulkan..." -ForegroundColor Yellow
        if (-not (Test-Path "$W\bin_vulkan\llama-server.exe")) {
            Download-File "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" "$W\vk.zip" "llama.cpp Vulkan" | Out-Null
            New-Item -ItemType Directory -Path "$W\bin_vulkan" -Force | Out-Null
            Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
            Remove-Item "$W\vk.zip" -EA SilentlyContinue
        }
        $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Write-Host "  Using Vulkan" -ForegroundColor Yellow
    } else {
        Write-Host "  Engine: CUDA OK" -ForegroundColor Green
    }

    # [4] GPU detection
    Write-Host "[4/8] Detecting GPUs (-Gpus $Gpus)..." -ForegroundColor Yellow
    Start-Process $exePath "--list-devices" -Wait -NoNewWindow -RedirectStandardOutput "$W\do.txt" -RedirectStandardError "$W\de.txt" -EA SilentlyContinue
    $devLines = @()
    if (Test-Path "$W\do.txt") { $devLines += Get-Content "$W\do.txt" }
    if (Test-Path "$W\de.txt") { $devLines += Get-Content "$W\de.txt" }
    $devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    $allDevices = @()
    foreach ($line in $devLines) {
        if ($line -match "^\s*([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB(?:,\s*(\d+)\s*MiB\s*free)?") {
            $freeV = if ($Matches[4]) { [int]$Matches[4] } else { [int]($Matches[3] * 0.80) }
            $allDevices += [PSCustomObject]@{ name=$Matches[1]; label=$Matches[2]; vram=[int]$Matches[3]; freeVram=$freeV }
        }
    }
    $allDevices = @($allDevices | Sort-Object @{Expression={if($_.label -match "RTX"){0}else{1}}}, @{Expression={-$_.vram}})
    $gpuMode = $Gpus.ToLower().Trim()
    if ($gpuMode -eq "all") { $sel = $allDevices }
    elseif ($gpuMode -match "^\d+$") { $sel = @($allDevices | Select-Object -First ([int]$gpuMode)) }
    else { $sel = @($allDevices | Select-Object -First 1) }
    if ($sel.Count -eq 0 -and $allDevices.Count -gt 0) { $sel = @($allDevices | Select-Object -First 1) }
    $totalVram  = ($sel | Measure-Object -Property vram -Sum).Sum
    $deviceList = ($sel | ForEach-Object { $_.name }) -join ","
    $totalFreeVram = ($sel | Measure-Object -Property freeVram -Sum).Sum
    Write-Host "  Free VRAM: $totalFreeVram MiB | Total: $totalVram MiB" -ForegroundColor $(if ($totalFreeVram -lt ($totalVram * 0.3)) {"Red"} else {"Green"})
    $deviceArg  = if ($deviceList) { "--device $deviceList" } else { "" }
    Write-Host "  Using: $deviceList | Total VRAM: $totalVram MiB" -ForegroundColor Green

    # [5] Model
    Write-Host "[5/8] Selecting LLM (mode=$Mode, vram=$totalVram MiB)..." -ForegroundColor Yellow
    $freeDisk = Get-FreeSpaceGb $W
    $freeRam  = Get-FreeRamGb
    Write-Host "  Disk free: ${freeDisk}GB | RAM free: ${freeRam}GB" -ForegroundColor $(if ($freeDisk -lt 3) {"Red"} elseif ($freeDisk -lt 6) {"Yellow"} else {"Gray"})

    # RAM предупреждения по режиму
    $minRam = @{ chat=2; voice=4; doc=6; full=8 }[$Mode]
    if ($freeRam -lt $minRam) {
        Write-Host "  WARN: mode=$Mode requires ~${minRam}GB free RAM, only ${freeRam}GB available. May OOM." -ForegroundColor Red
    }

    $candidate = Select-BestModel $totalVram $Mode $totalFreeVram $freeDisk

    $ctxSize   = Get-CtxSize $totalVram
    Write-Host "  Selected: $($candidate.name) | minVram: $($candidate.minVram)MB | ctx: $ctxSize" -ForegroundColor Cyan
    $m = "$W\models\$($candidate.file)"
    if ((Test-Path $m) -and (Get-Item $m -EA SilentlyContinue).Length -gt 100MB) {
        Write-Host "  Model cached: $($candidate.name) ($([math]::Round((Get-Item $m).Length/1MB))MB)" -ForegroundColor Green
    } else {
        $freeDiskNow = Get-FreeSpaceGb $W
        $needed = $candidate.sizeGb + 1.0
        if ($freeDiskNow -lt $needed) {
            Write-Host "  ERROR: need ${needed}GB, only ${freeDiskNow}GB free on disk!" -ForegroundColor Red
            $candidate = Select-BestModel $totalVram $Mode $totalFreeVram ($freeDiskNow - 0.5)
            $m = "$W\models\$($candidate.file)"
            Write-Host "  Fallback to $($candidate.name) ($($candidate.sizeGb) GB)" -ForegroundColor Yellow
            $freeDiskNow = Get-FreeSpaceGb $W
            if ($freeDiskNow -lt ($candidate.sizeGb + 0.5)) {
                Write-Host "  FATAL: not enough disk for any model. Free at least 2GB." -ForegroundColor Red
                exit 1
            }
        }
        Write-Host "  Downloading $($candidate.name) ($($candidate.sizeGb) GB)..." -ForegroundColor Yellow
        $hfUrl = if ($candidate.hf -notmatch "\?") { "$($candidate.hf)?download=true" } else { $candidate.hf }
        $ok = Download-Model $hfUrl $candidate.ms $m $candidate.name
        if (-not $ok) {
            Remove-Item $m -EA SilentlyContinue
            Write-Host "  All sources failed - emergency fallback qvikhr-4b-q4..." -ForegroundColor Red
            $m = "$W\models\qvikhr-4b-q4.gguf"
            $MS = "https://modelscope.cn/models"
            $ok = Download-Model `
                "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf?download=true" `
                "$MS/prithivMLmods/QVikhr-3-4B-it-F32-GGUF/resolve/master/QVikhr-3-4B-it-F32-Q4_K_M.gguf" `
                $m "qvikhr-4b-q4 (emergency)"
            if (-not $ok) {
                Write-Host "FAILED: cannot download model from any source." -ForegroundColor Red; exit 1
            }
        }
        Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
    }

    # [6] ONNX packages
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[6/8] ONNX packages..." -ForegroundColor Yellow
        if ($launchAsr) {
            Pip-Install "onnx-asr" "onnx_asr" | Out-Null
            Pip-Install "soundfile" "soundfile" | Out-Null
        }
        if ($launchOcr) {
            Pip-Install "rapidocr[onnxruntime]" "rapidocr" | Out-Null
            & python -m pip uninstall -y onnxruntime 2>&1 | Out-Null
        }
        $cudaOk = (& python -c "import onnxruntime as ort; print('ok' if 'CUDAExecutionProvider' in ort.get_available_providers() else 'no')" 2>$null).Trim()
        if ($cudaOk -ne "ok") {
            Write-Host "  Force-reinstalling onnxruntime-gpu..." -ForegroundColor Gray
            & python -m pip install --quiet --force-reinstall onnxruntime-gpu 2>&1 | Out-Null
        } else {
            Write-Host "  onnxruntime-gpu CUDA: ok" -ForegroundColor Green
        }
        if ($launchEmbed) {
            Write-Host "  Installing fastembed-gpu..." -ForegroundColor Gray
            & python -m pip install --quiet --upgrade fastembed-gpu 2>&1 | Out-Null
        }
    } else {
        Write-Host "[6/8] No ONNX packages needed for chat mode." -ForegroundColor Gray
    }

    # [7] ONNX model files
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[7/8] ONNX model files..." -ForegroundColor Yellow
        if ($launchAsr) {
            if ((Get-Stamp "gigaam_v3_onnx") -ne "ok") {
                Write-Host "  Pre-downloading GigaAM-v3..." -ForegroundColor Yellow
                $result = & python -c "import onnx_asr; onnx_asr.load_model('gigaam-v3-e2e-rnnt', providers=['CPUExecutionProvider']); print('ok')" 2>&1
                if ($result -match "ok") { Set-Stamp "gigaam_v3_onnx" "ok"; Write-Host "  GigaAM-v3: ready" -ForegroundColor Green }
                else { Write-Host "  GigaAM-v3: will download on first request" -ForegroundColor Yellow }
            } else { Write-Host "  GigaAM-v3 ONNX: cached" -ForegroundColor Green }
        }
        if ($launchOcr)   { Write-Host "  OCR: auto-download on first request" -ForegroundColor Green }
        if ($launchEmbed) { Write-Host "  Embed: auto-download on first request" -ForegroundColor Green }
    } else {
        Write-Host "[7/8] No ONNX models needed." -ForegroundColor Gray
    }

    # [8] Start services
    Write-Host "[8/8] Starting services..." -ForegroundColor Yellow

    # Write all scripts first
    Write-ProxyScript
    $proxyScript = "$W\proxy_service.py"

    # run_llm.py — what the proxy executes to start llama
    $exeEsc = $exePath -replace '\\','\\\\'
    $mEsc   = $m       -replace '\\','\\\\'
    @"
import subprocess
subprocess.run([
    r'$exeEsc', '--model', r'$mEsc',
    '--port', '18010', '--n-gpu-layers', '99',
    '--ctx-size', '$ctxSize', '--host', '0.0.0.0',
    '--alias', '$($candidate.name)', '--no-warmup'
])
"@ | Out-File "$W\run_llm.py" -Encoding UTF8

    # keep run.ps1 for ctx-size reduction on crash (used by proxy restart logic)
    $cmd = "Set-Location `"$binDir`"; .\llama-server.exe --model `"$m`" --port 18010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --alias `"$($candidate.name)`" --no-warmup > `"$W\server.log`" 2>&1"
    [System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

    if ($launchAsr)   { Write-AsrService }
    if ($launchOcr)   { Write-OcrService }
    if ($launchEmbed) { Write-EmbedService }

    # Start LLM proxy (proxy will start llama on first request)
    Start-Process "python" -ArgumentList $proxyScript, "8010", "18010", "LLM", "$W\run_llm.py", $W, $IDLE_LLM `
        -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8010.log" -RedirectStandardError "$W\proxy_8010_err.log"
    Write-Host "  [LLM]   Proxy started (wakes on first request, idle=${IDLE_LLM}s)" -ForegroundColor Green

    # Start special service proxies
    if ($launchAsr) {
        Start-Process "python" -ArgumentList $proxyScript, "8011", "18011", "ASR", "$W\asr_service.py", $W, $IDLE_ASR `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8011.log" -RedirectStandardError "$W\proxy_8011_err.log"
        Write-Host "  [ASR]   Proxy started (idle=${IDLE_ASR}s)" -ForegroundColor Green
    }
    if ($launchOcr) {
        Start-Process "python" -ArgumentList $proxyScript, "8013", "18013", "OCR", "$W\ocr_service.py", $W, $IDLE_OCR `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8013.log" -RedirectStandardError "$W\proxy_8013_err.log"
        Write-Host "  [OCR]   Proxy started (idle=${IDLE_OCR}s)" -ForegroundColor Green
    }
    if ($launchEmbed) {
        Start-Process "python" -ArgumentList $proxyScript, "8014", "18014", "Embed", "$W\embed_service.py", $W, $IDLE_EMBED `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8014.log" -RedirectStandardError "$W\proxy_8014_err.log"
        Write-Host "  [Embed] Proxy started (idle=${IDLE_EMBED}s)" -ForegroundColor Green
    }

    # Save config
    [PSCustomObject]@{
        mode=$Mode; idleLlm=$IDLE_LLM; idleAsr=$IDLE_ASR; idleOcr=$IDLE_OCR; idleEmbed=$IDLE_EMBED
        modelName=$candidate.name; ctxSize=$ctxSize; deviceList=$deviceList
        launchAsr=$launchAsr; launchOcr=$launchOcr; launchEmbed=$launchEmbed
    } | ConvertTo-Json -Depth 5 | Out-File "$W\config.json" -Encoding UTF8 -NoNewline

    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"                        -ForegroundColor Green
    Write-Host "  Model:   $($candidate.name)"           -ForegroundColor Green
    Write-Host "  GPUs:    $deviceList ($totalVram MiB)" -ForegroundColor Green
    Write-Host "  Context: $ctxSize tokens"              -ForegroundColor Green
    Write-Host "  LLM:     http://localhost:8010/v1  (sleeping - wakes on request)" -ForegroundColor Green
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8011" -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8013" -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8014" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host ("  Idle timeouts: LLM={0}s  ASR={1}s  OCR={2}s  Embed={3}s" -f $IDLE_LLM, $IDLE_ASR, $IDLE_OCR, $IDLE_EMBED) -ForegroundColor Gray
    Write-Host "  Stop:    powershell -EP Bypass -File win_deploy.ps1 --stop"   -ForegroundColor Gray
    Write-Host "  Status:  powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor Gray
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
