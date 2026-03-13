# LLM WIN DEPLOY
# On-demand model lifecycle: STOPPED -> LOADING -> READY -> IDLE -> STOPPED
# All services (LLM, ASR, OCR, Embedding) start on request, unload on idle_timeout
#
# Usage:
#   win_deploy.ps1                        -- deploy chat mode (default)
#   win_deploy.ps1 -Mode voice            -- LLM + ASR (speech input)
#   win_deploy.ps1 -Mode doc              -- LLM + OCR + Embedding (RAG / documents)
#   win_deploy.ps1 -Mode code             -- Kodify-Nano-2B, optimised for code generation
#   win_deploy.ps1 -Mode full             -- LLM + ASR + OCR + Embedding
#   win_deploy.ps1 -Gpus 2               -- use 2 GPUs
#   win_deploy.ps1 -Gpus all             -- use all GPUs
#   win_deploy.ps1 --stop                -- stop all services
#   win_deploy.ps1 --status              -- show status
#   win_deploy.ps1 --restart             -- stop + deploy
param(
    [string]$Action = "--deploy",
    [string]$Gpus   = "1",
    [string]$Mode   = "chat"
)
if ($args.Count -gt 0 -and $Action -eq "--deploy") { $Action = $args[0] }

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$W = "$env:USERPROFILE\llm_native"

# Idle timeouts in seconds
$IDLE_LLM   = 600   # 10 min
$IDLE_ASR   = 300   # 5 min
$IDLE_OCR   = 300   # 5 min
$IDLE_EMBED = 900   # 15 min

# =============================================================================
# STOP
# =============================================================================
function Invoke-Stop {
    Write-Host "Stopping all LLM services..." -ForegroundColor Yellow
    $killed = 0
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue
        $killed++
    }
    Write-Host "  Stopped $killed llama process(es)" -ForegroundColor Green
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and (
            $_.CommandLine -match "watchdog" -or
            $_.CommandLine -match "asr_service" -or
            $_.CommandLine -match "ocr_service" -or
            $_.CommandLine -match "embed_service"
        )
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped PS service PID $($_.ProcessId)" -ForegroundColor Green
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and (
            $_.CommandLine -match "asr_service|ocr_service|embed_service"
        )
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped Python service PID $($_.ProcessId)" -ForegroundColor Green
    }
    Remove-Item "$W\*.trigger" -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
}

# =============================================================================
# STATUS
# =============================================================================
function Invoke-Status {
    Write-Host "--- LLM ORCHESTRATOR STATUS ---" -ForegroundColor Cyan
    $portMap = @{
        8010 = "LLM (llama-server)"
        8051 = "ASR (GigaAM)"
        8053 = "OCR (PaddleOCR)"
        8054 = "Embedding (RoSBERTa)"
    }
    foreach ($port in 8010, 8051, 8053, 8054) {
        $name = $portMap[$port]
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $h = ($r.Content | ConvertFrom-Json).status
            Write-Host "  $name [$port]: $h" -ForegroundColor Green
        } catch {
            $stateFile = "$W\state_$port.txt"
            if ((Test-Path $stateFile) -and (Get-Content $stateFile -Raw).Trim() -eq "STOPPED") {
                Write-Host "  $name [$port]: STOPPED (idle - restarts on next request)" -ForegroundColor Yellow
            } else {
                Write-Host "  $name [$port]: NOT RUNNING" -ForegroundColor Red
            }
        }
    }
    $wd = Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
    }
    if ($wd) { Write-Host "  Watchdog: RUNNING (PID $($wd.ProcessId))" -ForegroundColor Green }
    else      { Write-Host "  Watchdog: NOT RUNNING" -ForegroundColor Yellow }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)") {
            Write-Host "  Model file: $($Matches[1])" -ForegroundColor Cyan
        }
        if ($run -match "--ctx-size\s+(\d+)") {
            Write-Host "  Context:    $($Matches[1]) tokens" -ForegroundColor Cyan
        }
    }
}

# =============================================================================
# HELPERS
# =============================================================================
function Install-Pkg($pkgId, $label) {
    Write-Host "  Checking $label..." -ForegroundColor Gray
    & winget install -e --id $pkgId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Download-Model($url, $dest) {
    Remove-Item $dest -ErrorAction SilentlyContinue
    $hfRepo = ""
    $hfFile = ""
    if ($url -match "huggingface\.co/([^/]+/[^/]+)/resolve/[^/]+/(.+)") {
        $hfRepo = $Matches[1]
        $hfFile = $Matches[2]
    }
    if ($hfRepo) {
        Write-Host "  Trying huggingface-hub: $hfRepo / $hfFile" -ForegroundColor Gray
        $dlDir = Split-Path $dest -Parent
        $pyCode = @"
from huggingface_hub import hf_hub_download
import shutil, os
p = hf_hub_download(repo_id='$hfRepo', filename='$hfFile', local_dir=r'$dlDir')
if os.path.abspath(p) != os.path.abspath(r'$dest'):
    shutil.move(p, r'$dest')
print('hf-ok')
"@
        & python -c $pyCode 2>&1 | ForEach-Object {
            if ($_ -match "hf-ok") { Write-Host "  huggingface-hub: OK" -ForegroundColor Green }
        }
    }
    if (!(Test-Path $dest) -or (Get-Item $dest -EA SilentlyContinue).Length -lt 100MB) {
        Write-Host "  Trying curl fallback..." -ForegroundColor Gray
        curl.exe -L --retry 3 $url -o $dest
    }
    if (Test-Path $dest) { return (Get-Item $dest).Length }
    return 0
}

function Get-CtxSize($vramMb) {
    if ($vramMb -ge 32000) { return 32768 }
    if ($vramMb -ge 22000) { return 24576 }
    if ($vramMb -ge 14000) { return 16384 }
    if ($vramMb -ge 9000)  { return 16384 }
    if ($vramMb -ge 6000)  { return 8192 }
    if ($vramMb -ge 3000)  { return 8192 }
    return 4096
}

function Select-BestModel($vramMb, $deployMode) {
    # Reserve VRAM for special services depending on mode
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 512  }
    if ($deployMode -eq "doc")   { $specialMb = 1500 }
    if ($deployMode -eq "full")  { $specialMb = 2000 }
    # code mode: force kodify-2b-q8 regardless of VRAM
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{ name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3200; url="https://huggingface.co/MTSAIR/Kodify-Nano-GGUF/resolve/main/Kodify-Nano-q8_0.gguf" }
    }
    $budget = $vramMb - 1200 - $specialMb

    $catalog = @(
        # t-pro 32B
        [PSCustomObject]@{ name="t-pro-32b-q8"; file="t-pro-32b-q8.gguf"; minVram=36000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q6"; file="t-pro-32b-q6.gguf"; minVram=27000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q5"; file="t-pro-32b-q5.gguf"; minVram=23000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q4"; file="t-pro-32b-q4.gguf"; minVram=19000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf" }
        # saiga nemo/gemma 12B
        [PSCustomObject]@{ name="saiga-nem12-q8"; file="saiga-nem12-q8.gguf"; minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8"; file="saiga-gem12-q8.gguf"; minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q6"; file="saiga-nem12-q6.gguf"; minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6"; file="saiga-gem12-q6.gguf"; minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        # t-lite 8B + yagpt 8B + qvikhr 8B (q8 on 10 GB)
        [PSCustomObject]@{ name="t-lite-8b-q8";  file="t-lite-8b-q8.gguf";  minVram=10000; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q8";   file="yagpt-8b-q8.gguf";   minVram=10000; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q8";  file="qvikhr-8b-q8.gguf";  minVram=10000; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q8_0.gguf" }
        # saiga 12B q5 (10 GB)
        [PSCustomObject]@{ name="saiga-nem12-q5"; file="saiga-nem12-q5.gguf"; minVram=9800; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5"; file="saiga-gem12-q5.gguf"; minVram=9800; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        # t-lite 8B q6 (8 GB)
        [PSCustomObject]@{ name="t-lite-8b-q6"; file="t-lite-8b-q6.gguf"; minVram=8200; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q6_K.gguf" }
        # saiga 12B q4 (8 GB)
        [PSCustomObject]@{ name="saiga-nem12-q4"; file="saiga-nem12-q4.gguf"; minVram=8300; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4"; file="saiga-gem12-q4.gguf"; minVram=8300; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        # qvikhr 8B q5 + t-lite q5 (7 GB)
        [PSCustomObject]@{ name="qvikhr-8b-q5"; file="qvikhr-8b-q5.gguf"; minVram=6800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q5_k_m.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q5"; file="t-lite-8b-q5.gguf"; minVram=6600; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q5_K_M.gguf" }
        # saiga mistral 7B q5 (6 GB)
        [PSCustomObject]@{ name="saiga-mis7b-q5"; file="saiga-mis7b-q5.gguf"; minVram=6200; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/saiga_mistral_7b.Q5_K_M.gguf" }
        # qvikhr 4B q8 + t-lite q4 + yagpt q4 (5-6 GB)
        [PSCustomObject]@{ name="qvikhr-4b-q8"; file="qvikhr-4b-q8.gguf"; minVram=5800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q8_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q4"; file="t-lite-8b-q4.gguf"; minVram=5600; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";  file="yagpt-8b-q4.gguf";  minVram=5600; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q4"; file="qvikhr-8b-q4.gguf"; minVram=5700; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruct-GGUF/resolve/main/qvikhr-3-8b-instruct-q4_k_m.gguf" }
        # qvikhr 4B q5/q4 (4-5 GB)
        [PSCustomObject]@{ name="qvikhr-4b-q5"; file="qvikhr-4b-q5.gguf"; minVram=4300; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q5_k_m.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4"; file="qvikhr-4b-q4.gguf"; minVram=3800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" }
        [PSCustomObject]@{ name="saiga-llama8b-q4"; file="saiga-llama8b-q4.gguf"; minVram=5800; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q4_K_M.gguf" }
        # qvikhr 1.7B minimum viable
        [PSCustomObject]@{ name="qvikhr-1b-q8"; file="qvikhr-1b-q8.gguf"; minVram=2600; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4"; file="qvikhr-1b-q4.gguf"; minVram=1800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruct-GGUF/resolve/main/qvikhr-3-1.7b-instruct-q4_k_m.gguf" }
    )

    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (!$best) {
        Write-Host "  WARNING: budget $budget MB too low, selecting smallest available" -ForegroundColor Yellow
        $best = $catalog | Select-Object -Last 1
    }
    return $best
}

# =============================================================================
# PYTHON SERVICE WRITERS
# =============================================================================
function Write-AsrService {
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "IDLE_TIMEOUT = $IDLE_ASR",
        "last_req = [time.time()]",
        "model = [None]",
        "def load_model():",
        "    if model[0] is None:",
        "        import gigaam",
        "        model[0] = gigaam.load_model('ctc')",
        "    return model[0]",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if self.path == '/health':",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'status':'ok'}).encode())",
        "    def do_POST(self):",
        "        last_req[0] = time.time()",
        "        n = int(self.headers.get('Content-Length',0))",
        "        body = json.loads(self.rfile.read(n))",
        "        audio = base64.b64decode(body.get('audio',''))",
        "        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:",
        "            f.write(audio); tmp = f.name",
        "        try:",
        "            text = load_model().transcribe(tmp)",
        "            if not isinstance(text, str): text = str(text)",
        "        except Exception as e: text = 'ERROR: ' + str(e)",
        "        finally: os.unlink(tmp)",
        "        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "        self.wfile.write(json.dumps({'text': text}).encode())",
        "def watcher():",
        "    while True:",
        "        time.sleep(30)",
        "        if time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
        "load_model()",
        "HTTPServer(('0.0.0.0', 8051), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\asr_service.py" -Encoding UTF8 -NoNewline
}

function Write-OcrService {
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "import paddle",
        "# ФИКС: Отключаем экспериментальный движок PIR, который дает ошибку на 5080",
        "paddle.set_flags({'FLAGS_enable_pir_api': 0})",
        "os.environ['PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK'] = 'True'",
        "IDLE_TIMEOUT = $IDLE_OCR",
        "last_req = [time.time()]",
        "ocr = [None]",
        "def load_model():",
        "    if ocr[0] is None:",
        "        from paddleocr import PaddleOCR",
        "        # ФИКС: Явно выключаем mkldnn и включаем gpu",
        "        ocr[0] = PaddleOCR(use_textline_orientation=True, lang='ru', use_gpu=True, enable_mkldnn=False)", 
        "    return ocr[0]",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if self.path == '/health':",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'status':'ok'}).encode())",
        "    def do_POST(self):",
        "        last_req[0] = time.time()",
        "        n = int(self.headers.get('Content-Length',0))",
        "        body = json.loads(self.rfile.read(n))",
        "        img_data = body.get('image') or body.get('audio')",
        "        if not img_data: ",
        "             self.send_response(400); self.end_headers(); return",
        "        img = base64.b64decode(img_data)",
        "        ext = body.get('ext', '.png')",
        "        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:",
        "            f.write(img); tmp = f.name",
        "        try:",
        "            r = load_model().ocr(tmp)", 
        "            lines = [line[1][0] for page in r for line in page] if r else []",
        "            text = '\n'.join(lines)",
        "        except Exception as e: text = 'ERROR: ' + str(e)",
        "        finally: ",
        "            if os.path.exists(tmp): os.unlink(tmp)",
        "        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "        self.wfile.write(json.dumps({'text': text}).encode())",
        "def watcher():",
        "    while True:",
        "        time.sleep(30)",
        "        if time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
        "load_model()",
        "HTTPServer(('0.0.0.0', 8053), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\ocr_service.py" -Encoding UTF8 -NoNewline
}

function Write-EmbedService {
    $lines = @(
        "import sys, json, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "IDLE_TIMEOUT = $IDLE_EMBED",
        "last_req = [time.time()]",
        "model = [None]",
        "def load_model():",
        "    if model[0] is None:",
        "        from sentence_transformers import SentenceTransformer",
        "        model[0] = SentenceTransformer('ai-forever/ru-en-RoSBERTa')",
        "    return model[0]",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if self.path == '/health':",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'status':'ok'}).encode())",
        "    def do_POST(self):",
        "        last_req[0] = time.time()",
        "        n = int(self.headers.get('Content-Length',0))",
        "        body = json.loads(self.rfile.read(n))",
        "        texts = body.get('input', [])",
        "        if isinstance(texts, str): texts = [texts]",
        "        vecs = load_model().encode(texts).tolist()",
        "        data = [{'index': i, 'embedding': v} for i, v in enumerate(vecs)]",
        "        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "        self.wfile.write(json.dumps({'object':'list','data':data}).encode())",
        "def watcher():",
        "    while True:",
        "        time.sleep(60)",
        "        if time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
        "load_model()",
        "HTTPServer(('0.0.0.0', 8054), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\embed_service.py" -Encoding UTF8 -NoNewline
}

function Start-SpecialService($scriptPath, $logPath, $port, $packages) {
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (!$pyOk) { Write-Host "  Python not found, skipping port $port" -ForegroundColor Red; return }
    if ($packages) {
        $pkgList = $packages.Split(" ")
        & python -m pip install --quiet $pkgList 2>&1 | Out-Null
        & python -m pip install --quiet "urllib3<2.0" "requests" 2>&1 | Out-Null
    }
    $errLog = $logPath -replace "\.log$", "_err.log"
    Start-Process "python" -ArgumentList $scriptPath -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errLog
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -s 2
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            $h = ($r.Content | ConvertFrom-Json).status
            if ($h -eq "ok") { Write-Host "  Port $port UP" -ForegroundColor Green; return }
        } catch {}
        Write-Host "  [$i] waiting port $port..." -ForegroundColor Gray
    }
    Write-Host "  WARNING: port $port not up in time" -ForegroundColor Yellow
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY V  (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    On-demand: all services start on request, auto-unload on idle" -ForegroundColor Gray

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

    # [2] CUDA DLLs + hf-hub
    Write-Host "[2/7] CUDA DLLs + huggingface-hub..." -ForegroundColor Yellow
    $cudaDllDir = "$W\cuda_dlls"
    New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
    & python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
    & python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
    & python -m pip install --quiet huggingface-hub 2>&1 | Out-Null
    $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
    Write-Host "  CUDA DLLs: $($cudaDlls.Count) | hf-hub: OK" -ForegroundColor Green

    # [3] Engine
    Write-Host "[3/7] Downloading CUDA 12.4 Engine ($tag)..." -ForegroundColor Yellow
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
        Write-Host "  CUDA failed - trying Vulkan fallback..." -ForegroundColor Yellow
        curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
        Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
        Remove-Item "$W\vk.zip"
        $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Write-Host "  Using Vulkan" -ForegroundColor Yellow
    } else { Write-Host "  CUDA OK" -ForegroundColor Green }

    # [5] GPU detection
    Write-Host "[5/7] Detecting GPUs (-Gpus $Gpus)..." -ForegroundColor Yellow
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

    # [6] Model selection
    Write-Host "[6/7] Selecting model (mode=$Mode, vram=$totalVram MiB)..." -ForegroundColor Yellow
    $candidate = Select-BestModel $totalVram $Mode
    $ctxSize   = Get-CtxSize $totalVram
    Write-Host "  Selected: $($candidate.name) | minVram: $($candidate.minVram) MB | ctx: $ctxSize" -ForegroundColor Cyan

    $m = "$W\models\$($candidate.file)"
    $existOk = (Test-Path $m) -and ((Get-Item $m -EA SilentlyContinue).Length -gt 100MB)
    if ($existOk) {
        Write-Host "  Cached: $($candidate.name) ($([math]::Round((Get-Item $m).Length / 1MB)) MB)" -ForegroundColor Green
    } else {
        Write-Host "  Downloading $($candidate.name)..." -ForegroundColor Yellow
        $sz = Download-Model $candidate.url $m
        if ($sz -le 100MB) {
            Write-Host "  Download failed - trying q4 fallback..." -ForegroundColor Yellow
            Remove-Item $m -ErrorAction SilentlyContinue
            $fbUrl  = $candidate.url  -replace "Q[5-9]_[K0](_[Mm])?", "Q4_K_M"
            $fbFile = $candidate.file -replace "q[5-9]", "q4"
            $m = "$W\models\$fbFile"
            if (!(Test-Path $m) -or (Get-Item $m -EA SilentlyContinue).Length -lt 100MB) {
                $sz = Download-Model $fbUrl $m
            }
            if ($sz -le 100MB) {
                Write-Host "  Trying emergency fallback qvikhr-4b-q4..." -ForegroundColor Red
                $m = "$W\models\qvikhr-4b-q4.gguf"
                $sz = Download-Model "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruct-GGUF/resolve/main/qvikhr-3-4b-instruct-q4_k_m.gguf" $m
                if ($sz -le 100MB) { Write-Host "All downloads failed. Check network." -ForegroundColor Red; exit 1 }
            }
        }
        Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length / 1MB)) MB" -ForegroundColor Green
    }

    # [7] Start LLM server + watchdog + special services
    Write-Host "[7/7] Starting services..." -ForegroundColor Yellow
    $cmd = "Set-Location `"$binDir`"; .\llama-server.exe --model `"$m`" --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --no-warmup > `"$W\server.log`" 2>&1"
    [System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

    # Config for watchdog
    $cfgObj = [PSCustomObject]@{
        mode        = $Mode
        idleLlm     = $IDLE_LLM
        idleAsr     = $IDLE_ASR
        idleOcr     = $IDLE_OCR
        idleEmbed   = $IDLE_EMBED
        modelName   = $candidate.name
        ctxSize     = $ctxSize
        deviceList  = $deviceList
        launchAsr   = ($Mode -in @("voice","full"))
        launchOcr   = ($Mode -in @("doc","full"))
        launchEmbed = ($Mode -in @("doc","full"))
    }
    $cfgObj | ConvertTo-Json -Depth 5 | Out-File "$W\config.json" -Encoding UTF8 -NoNewline

    # Clear stale state files
    foreach ($port in 8010, 8051, 8053, 8054) {
        "STARTING" | Out-File "$W\state_$port.txt" -Encoding UTF8 -NoNewline
    }

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
    if (!$ok) {
        Write-Host "FAILED to start LLM. Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
        exit 1
    }
    "READY" | Out-File "$W\state_8010.txt" -Encoding UTF8 -NoNewline

    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    if ($launchAsr) {
        Write-Host "  [ASR] Starting GigaAM port 8051..." -ForegroundColor Yellow
        Write-AsrService
        Start-SpecialService "$W\asr_service.py" "$W\asr.log" 8051 "gigaam"
        "READY" | Out-File "$W\state_8051.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchOcr) {
        Write-Host "  [OCR] Starting PaddleOCR port 8053..." -ForegroundColor Yellow
        Write-OcrService
        Start-SpecialService "$W\ocr_service.py" "$W\ocr.log" 8053 "paddlepaddle paddleocr"
        "READY" | Out-File "$W\state_8053.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchEmbed) {
        Write-Host "  [Embed] Starting RoSBERTa port 8054..." -ForegroundColor Yellow
        Write-EmbedService
        Start-SpecialService "$W\embed_service.py" "$W\embed.log" 8054 "sentence-transformers"
        "READY" | Out-File "$W\state_8054.txt" -Encoding UTF8 -NoNewline
    }

    # Watchdog
    $wdScript = "$W\watchdog.ps1"
    curl.exe -L "https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_watchdog.ps1" -o $wdScript --silent
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript

    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator v14.1" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"                         -ForegroundColor Green
    Write-Host "  Model:   $($candidate.name)"            -ForegroundColor Green
    Write-Host "  GPUs:    $deviceList ($totalVram MiB)"  -ForegroundColor Green
    Write-Host "  Context: $ctxSize tokens"               -ForegroundColor Green
    Write-Host "  LLM:     http://localhost:8010/v1"      -ForegroundColor Green
    if ($Mode -eq "code") { Write-Host "  [code mode] Kodify-Nano-2B: optimised for code generation, completions, refactoring" -ForegroundColor Cyan }
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8051/v1/asr"        -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8053/v1/ocr"        -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8054/v1/embeddings" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "  Idle timeouts: LLM=$($IDLE_LLM)s  ASR=$($IDLE_ASR)s  OCR=$($IDLE_OCR)s  Embed=$($IDLE_EMBED)s" -ForegroundColor Gray
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
