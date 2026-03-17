# LLM WIN DEPLOY v14.2-fix3
# On-demand model lifecycle: STOPPED -> LOADING -> READY -> IDLE -> STOPPED
# All services (LLM, ASR, OCR, Embedding) start on request, unload on idle_timeout
#
# FIXES vs v14.1:
#   [fix1] Write-OcrService: surya 0.6.x predictor API (DetectionPredictor/RecognitionPredictor)
#   [fix2] Write-EmbedService: trust_remote_code=True for ai-forever/ru-en-RoSBERTa
#   [fix3] Start-SpecialService: proper torch version compare (handles 2.10+, strips +cu124 suffix)
#   [fix4] LLM health-check: reads HTTP 503 body (loading model), no hard timeout, bails on process death
#   [fix5] Invoke-Stop: kills any process holding ports 8010-8014 (wake proxy, stale listeners)
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

    # Kill llama processes
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue
        $killed++
    }
    Write-Host "  Stopped $killed llama process(es)" -ForegroundColor Green

    # Kill known PowerShell service processes (watchdog, wake proxy, service wrappers)
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and (
            $_.CommandLine -match "watchdog|wake_proxy|asr_service|ocr_service|embed_service|llm_native"
        )
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped PS process PID $($_.ProcessId)" -ForegroundColor Green
    }

    # Kill Python service processes
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and (
            $_.CommandLine -match "asr_service|ocr_service|embed_service|wake_proxy"
        )
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped Python service PID $($_.ProcessId)" -ForegroundColor Green
    }

    # Kill anything holding our service ports (8010-8014) - catches wake proxies and leftovers
    foreach ($port in 8010, 8011, 8013, 8014) {
        try {
            $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue |
                    Where-Object { $_.State -eq "Listen" } | Select-Object -First 1
            if ($conn -and $conn.OwningProcess -gt 4) {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
                    Write-Host "  Freed port $port (was held by $($proc.Name) PID $($conn.OwningProcess))" -ForegroundColor Green
                }
            }
        } catch {}
    }

    Remove-Item "$W\*.trigger" -ErrorAction SilentlyContinue
    Start-Sleep -s 2
    Write-Host "Done." -ForegroundColor Green
}

# =============================================================================
# STATUS
# =============================================================================
function Invoke-Status {
    Write-Host "--- LLM ORCHESTRATOR STATUS ---" -ForegroundColor Cyan
    $portMap = @{
        8010 = "LLM (llama-server)"
        8011 = "ASR (GigaAM)"
        8013 = "OCR (surya-ocr)"
        8014 = "Embedding (RoSBERTa)"
    }
    foreach ($port in 8010, 8011, 8013, 8014) {
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
# STAMP HELPERS (idempotency - skip steps already done)
# =============================================================================
function Get-Stamp($name) {
    $f = "$W\stamp_$name.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Set-Stamp($name, $value) {
    $value | Out-File "$W\stamp_$name.txt" -Encoding UTF8 -NoNewline
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
    if ($url -notmatch "\?") { $dlUrl = "$url`?download=true" } else { $dlUrl = $url }
    Write-Host "  Downloading: $($url.Split('/')[-1].Split('?')[0])" -ForegroundColor Gray
    curl.exe -L --retry 3 --retry-delay 5 --retry-connrefused `
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
        -H "Accept: application/octet-stream" `
        --max-time 3600 `
        $dlUrl -o $dest
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 10MB) {
        return (Get-Item $dest).Length
    }
    Remove-Item $dest -ErrorAction SilentlyContinue
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
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 512  }
    if ($deployMode -eq "doc")   { $specialMb = 1500 }
    if ($deployMode -eq "full")  { $specialMb = 2000 }
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{
            name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3200
            url="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf"
        }
    }
    $budget = $vramMb - 1200 - $specialMb

    $catalog = @(
        [PSCustomObject]@{ name="t-pro-32b-q8";      file="t-pro-32b-q8.gguf";      minVram=36000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q6";      file="t-pro-32b-q6.gguf";      minVram=27000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q5";      file="t-pro-32b-q5.gguf";      minVram=23000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q4";      file="t-pro-32b-q4.gguf";      minVram=19000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q8";    file="saiga-nem12-q8.gguf";    minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8";    file="saiga-gem12-q8.gguf";    minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q6";    file="saiga-nem12-q6.gguf";    minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6";    file="saiga-gem12-q6.gguf";    minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q8";      file="t-lite-8b-q8.gguf";      minVram=10000; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q8";       file="yagpt-8b-q8.gguf";       minVram=10000; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q8";      file="qvikhr-8b-q8.gguf";      minVram=10000; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q5";    file="saiga-nem12-q5.gguf";    minVram=9800;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5";    file="saiga-gem12-q5.gguf";    minVram=9800;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q6";      file="t-lite-8b-q6.gguf";      minVram=8200;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q4";    file="saiga-nem12-q4.gguf";    minVram=8300;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4";    file="saiga-gem12-q4.gguf";    minVram=8300;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q5";      file="qvikhr-8b-q5.gguf";      minVram=6800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q5";      file="t-lite-8b-q5.gguf";      minVram=6600;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-mis7b-q5";    file="saiga-mis7b-q5.gguf";    minVram=6200;  url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/saiga_mistral_7b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q8";      file="qvikhr-4b-q8.gguf";      minVram=5800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q4";      file="t-lite-8b-q4.gguf";      minVram=5600;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";       file="yagpt-8b-q4.gguf";       minVram=5600;  url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q4";      file="qvikhr-8b-q4.gguf";      minVram=5700;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q5";      file="qvikhr-4b-q5.gguf";      minVram=4300;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4";      file="qvikhr-4b-q4.gguf";      minVram=3800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-llama8b-q4";  file="saiga-llama8b-q4.gguf";  minVram=5800;  url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q8";      file="qvikhr-1b-q8.gguf";      minVram=2600;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4";      file="qvikhr-1b-q4.gguf";      minVram=1800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf" }
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
        "HTTPServer(('0.0.0.0', 8011), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\asr_service.py" -Encoding UTF8 -NoNewline
}

# FIX #1: surya 0.6.x uses DetectionPredictor/RecognitionPredictor instead of
#          load_model()/load_processor() + run_ocr() with 5 args.
function Write-OcrService {
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "os.environ['KMP_DUPLICATE_LIB_OK']='TRUE'",
        "IDLE_TIMEOUT = $IDLE_OCR",
        "last_req = [time.time()]",
        "_ocr = [None]; ready = [False]; err_msg = [None]",
        "def load_model():",
        "    try:",
        "        from surya.recognition import RecognitionPredictor",
        "        from surya.detection import DetectionPredictor",
        "        rec_pred = RecognitionPredictor()",
        "        det_pred = DetectionPredictor()",
        "        _ocr[0] = (rec_pred, det_pred)",
        "        ready[0] = True",
        "    except Exception as e:",
        "        print(f'CRITICAL_LOAD_ERROR: {e}', file=sys.stderr)",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "def do_ocr(image_path):",
        "    from PIL import Image",
        "    rec_pred, det_pred = _ocr[0]",
        "    img = Image.open(image_path).convert('RGB')",
        "    res = rec_pred([img], [['ru', 'en']], det_pred)",
        "    lines = [line.text for page in res for line in page.text_lines if line.text.strip()]",
        "    return chr(10).join(lines)",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if self.path == '/health':",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            if ready[0]:     st = 'ok'",
        "            elif err_msg[0]: st = 'error: ' + err_msg[0][:120]",
        "            else:            st = 'loading'",
        "            self.wfile.write(json.dumps({'status': st}).encode())",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode()); return",
        "        last_req[0] = time.time()",
        "        n    = int(self.headers.get('Content-Length', 0))",
        "        body = json.loads(self.rfile.read(n))",
        "        img  = base64.b64decode(body.get('image', ''))",
        "        ext  = body.get('ext', '.png')",
        "        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:",
        "            f.write(img); tmp = f.name",
        "        try:    text = do_ocr(tmp)",
        "        except Exception as e: text = 'ERROR: ' + str(e)",
        "        finally: os.unlink(tmp)",
        "        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "        self.wfile.write(json.dumps({'text': text}).encode())",
        "def watcher():",
        "    while True:",
        "        time.sleep(30)",
        "        if ready[0] and time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
        "threading.Thread(target=load_model, daemon=True).start()",
        "HTTPServer(('0.0.0.0', 8013), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\ocr_service.py" -Encoding UTF8 -NoNewline
}

# FIX #2: ai-forever/ru-en-RoSBERTa has custom modeling_roberta.py and requires
#          trust_remote_code=True, otherwise transformers refuses to load it
#          and RobertaModel can't be imported.
function Write-EmbedService {
    $lines = @(
        "import sys, json, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "IDLE_TIMEOUT = $IDLE_EMBED",
        "last_req = [time.time()]",
        "_tok = [None]; _mdl = [None]; ready = [False]; err_msg = [None]",
        "def mean_pool(token_emb, attn_mask):",
        "    import torch",
        "    mask = attn_mask.unsqueeze(-1).expand(token_emb.size()).float()",
        "    return (torch.sum(token_emb * mask, 1) / torch.clamp(mask.sum(1), min=1e-9)).tolist()",
        "def load_model():",
        "    try:",
        "        import torch",
        "        from transformers import AutoTokenizer, AutoModel",
        "        _tok[0] = AutoTokenizer.from_pretrained('ai-forever/ru-en-RoSBERTa', trust_remote_code=True)",
        "        _mdl[0] = AutoModel.from_pretrained('ai-forever/ru-en-RoSBERTa', trust_remote_code=True)",
        "        _mdl[0].eval()",
        "        ready[0] = True",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "def encode(texts):",
        "    import torch",
        "    enc = _tok[0](texts, padding=True, truncation=True, max_length=512, return_tensors='pt')",
        "    with torch.no_grad():",
        "        out = _mdl[0](**enc)",
        "    return mean_pool(out.last_hidden_state, enc['attention_mask'])",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if self.path == '/health':",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            if ready[0]:     st = 'ok'",
        "            elif err_msg[0]: st = 'error: ' + err_msg[0][:120]",
        "            else:            st = 'loading'",
        "            self.wfile.write(json.dumps({'status': st}).encode())",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode()); return",
        "        last_req[0] = time.time()",
        "        n    = int(self.headers.get('Content-Length', 0))",
        "        body = json.loads(self.rfile.read(n))",
        "        texts = body.get('input', [])",
        "        if isinstance(texts, str): texts = [texts]",
        "        try:",
        "            vecs = encode(texts)",
        "            data = [{'index': i, 'embedding': v} for i, v in enumerate(vecs)]",
        "            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'object':'list','data':data}).encode())",
        "        except Exception as e:",
        "            self.send_response(500); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': str(e)}).encode())",
        "def watcher():",
        "    while True:",
        "        time.sleep(60)",
        "        if ready[0] and time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
        "threading.Thread(target=load_model, daemon=True).start()",
        "HTTPServer(('0.0.0.0', 8014), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\embed_service.py" -Encoding UTF8 -NoNewline
}

# FIX #3: old regex [7-9] only matched single digit minor versions,
#          so torch 2.10+ was treated as "old" and triggered a pointless re-download.
#          Now we split on dot, compare integers, and strip +cu124 suffixes first.
function Start-SpecialService($scriptPath, $logPath, $port, $packages) {
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (!$pyOk) { return }

    $errLog = $logPath -replace "\.log$", "_err.log"

    if ($packages -match "surya-ocr") {
        # Torch CUDA check
        $currentTorch = & python -c "import torch; print(torch.__version__)" 2>$null
        $torchClean = ($currentTorch -split '\+')[0]
        if ($currentTorch -match '\+(.+)') { $torchBuild = $Matches[1] } else { $torchBuild = "" }
        $torchParts = $torchClean -split '\.'
        if ($torchParts.Count -gt 0) { $torchMajor = [int]$torchParts[0] } else { $torchMajor = 0 }
        if ($torchParts.Count -gt 1) { $torchMinor = [int]$torchParts[1] } else { $torchMinor = 0 }
        $torchOld = ($torchMajor -lt 2) -or ($torchMajor -eq 2 -and $torchMinor -lt 7)
        $torchCpu = ($torchBuild -eq "cpu") -or ($torchBuild -eq "")
        $torchStamp = Get-Stamp "torch_cuda"
        if (($torchOld -or $torchCpu) -and $torchStamp -ne "cu128") {
            Write-Host "  Torch '$currentTorch' needs CUDA. Upgrading..." -ForegroundColor Yellow
            & python -m pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 --upgrade --no-cache-dir 2>&1 | Out-Null
            Set-Stamp "torch_cuda" "cu128"
        } else {
            Write-Host "  Torch '$currentTorch' OK" -ForegroundColor Green
        }

        # surya-ocr install with stamp (pin >=0.9,<0.10 for stable API)
        $suryaStamp = Get-Stamp "surya_ocr"
        $suryaInstalled = & python -m pip show surya-ocr 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version:\s*","" }
        if ($suryaInstalled) { $suryaInstalled = "$suryaInstalled".Trim() }
        $cacheStamp = Get-Stamp "surya_cache"
        if ($suryaStamp -ne $suryaInstalled -or -not $suryaInstalled) {
            Write-Host "  Installing surya-ocr..." -ForegroundColor Gray
            & python -m pip install --quiet --prefer-binary "surya-ocr" 2>> $errLog | Out-Null
            $suryaInstalled = & python -m pip show surya-ocr 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "Version:\s*","" }
            if ($suryaInstalled) { Set-Stamp "surya_ocr" $suryaInstalled }
        } else {
            Write-Host "  surya-ocr $suryaInstalled (cached, skipping)" -ForegroundColor Green
        }
        # Clear stale HF model cache whenever cache stamp differs from installed version
        # 'encoder'/'bbox_size' errors = stale model config from a different surya version
        if ($cacheStamp -ne $suryaInstalled -and $suryaInstalled) {
            Write-Host "  Clearing stale surya model cache..." -ForegroundColor Yellow
            $hfHub = "$env:USERPROFILE\.cache\huggingface\hub"
            if (Test-Path $hfHub) {
                Get-ChildItem $hfHub -Directory | Where-Object { $_.Name -match "surya|vikp" } | ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "  Removed: $($_.Name)" -ForegroundColor Gray
                }
            }
            Set-Stamp "surya_cache" $suryaInstalled
        }

        # torchvision CUDA pin - AFTER surya install (surya pulls CPU torchvision)
        $tvBuild = & python -c "import torchvision; v=torchvision.__version__; print('cuda' if '+cu' in v else 'cpu')" 2>$null
        $tvStamp = Get-Stamp "torchvision_cuda"
        if ($tvBuild -ne "cuda" -or $tvStamp -ne "cu128") {
            Write-Host "  Pinning torchvision CUDA..." -ForegroundColor Yellow
            & python -m pip install --quiet torchvision --index-url https://download.pytorch.org/whl/cu128 --upgrade --force-reinstall --no-cache-dir 2>&1 | Out-Null
            Set-Stamp "torchvision_cuda" "cu128"
        } else {
            Write-Host "  torchvision CUDA OK (cached)" -ForegroundColor Green
        }
        $tvCheck = & python -c "import torchvision.ops; torchvision.ops.nms; print('ok')" 2>$null
        if ($tvCheck -eq "ok") {
            Write-Host "  torchvision CUDA ops OK" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: torchvision::nms unavailable" -ForegroundColor Yellow
        }
    } else {
        # Non-surya packages: install with stamp
        if ($packages) {
            foreach ($pkg in $packages.Split(" ")) {
                $pkgKey = "pkg_" + ($pkg -replace "[^a-zA-Z0-9]", "_")
                $pkgName = ($pkg -split "==")[0]
                if ($pkg -match "==(.+)") { $wantVer = $Matches[1] } else { $wantVer = "" }
                $installedVer = & python -c "import importlib.metadata; print(importlib.metadata.version('$pkgName'))" 2>$null
                $cachedVer = Get-Stamp $pkgKey
                $needInstall = (-not $installedVer) -or ($wantVer -and $installedVer -ne $wantVer) -or ($cachedVer -ne $installedVer)
                if ($needInstall) {
                    Write-Host "  Installing $pkg..." -ForegroundColor Gray
                    & python -m pip install --quiet --prefer-binary $pkg 2>> $errLog | Out-Null
                    $installedVer = & python -c "import importlib.metadata; print(importlib.metadata.version('$pkgName'))" 2>$null
                    if ($installedVer) { Set-Stamp $pkgKey $installedVer }
                } else {
                    Write-Host "  $pkgName $installedVer (cached, skipping)" -ForegroundColor Green
                }
            }
        }
    }

    Start-Process "python" -ArgumentList $scriptPath -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errLog

    # Poll /health until ok, loading, or error (don't just Sleep 10)
    $svcElapsed = 0
    while ($svcElapsed -lt 300) {
        Start-Sleep -s 3
        $svcElapsed += 3
        try {
            $req2 = [System.Net.HttpWebRequest]::Create("http://localhost:$port/health")
            $req2.Timeout = 5000; $req2.Method = "GET"
            try {
                $resp2 = $req2.GetResponse()
                $sr3 = [System.IO.StreamReader]::new($resp2.GetResponseStream())
                $body3 = $sr3.ReadToEnd(); $sr3.Close(); $resp2.Close()
                $st = ($body3 | ConvertFrom-Json -ErrorAction SilentlyContinue).status
            } catch [System.Net.WebException] {
                $wr = $_.Exception.Response
                if ($wr) {
                    $sr4 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                    $body4 = $sr4.ReadToEnd(); $sr4.Close()
                    $st = ($body4 | ConvertFrom-Json -ErrorAction SilentlyContinue).status
                } else { $st = "" }
            }
            if ($st -eq "ok") {
                Write-Host "  Service :$port ready ($svcElapsed s)" -ForegroundColor Green
                break
            }
            if ($st -and $st -ne "loading") {
                Write-Host "  Service :$port status: $st" -ForegroundColor Yellow
                break
            }
            if ($svcElapsed % 30 -eq 0) {
                Write-Host ("  Service :{0} loading... {1}s" -f $port, $svcElapsed) -ForegroundColor Gray
            }
        } catch {}
    }
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY v14.2-fix3 (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    On-demand: services start on request, auto-unload on idle" -ForegroundColor Gray

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 1
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
    # Reset torch/torchvision stamps if they point to cu124 - force upgrade to cu128 (RTX 5060 CC12.0)
    if ((Get-Stamp "torch_cuda") -eq "cu124")       { Remove-Item "$W\stamp_torch_cuda.txt"       -EA SilentlyContinue; Write-Host "  Migrating torch cu124->cu128..." -ForegroundColor Yellow }
    if ((Get-Stamp "torchvision_cuda") -eq "cu124") { Remove-Item "$W\stamp_torchvision_cuda.txt" -EA SilentlyContinue }
    # Reset transformers stamp if pinned to 4.44.x - surya-ocr requires >=4.56.1
    $tfStampNow = Get-Stamp "pkg_transformers"
    if ($tfStampNow -match "^4\.4[0-4]") {
        Remove-Item "$W\stamp_pkg_transformers.txt" -EA SilentlyContinue
        Write-Host "  Resetting transformers stamp (4.44->latest for surya compat)..." -ForegroundColor Yellow
    }
    if ((Get-Stamp "surya_cache") -ne "") { Remove-Item "$W\stamp_surya_cache.txt" -EA SilentlyContinue }
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

    # [2] CUDA DLLs - skip if stamp matches
    Write-Host "[2/7] CUDA DLLs..." -ForegroundColor Yellow
    $cudaDllDir = "$W\cuda_dlls"
    if ((Get-Stamp "cuda_dlls") -eq "ok" -and (Test-Path $cudaDllDir) -and (Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll" -ErrorAction SilentlyContinue).Count -gt 0) {
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Write-Host "  CUDA DLLs: cached ($($cudaDlls.Count) dlls)" -ForegroundColor Green
    } else {
        New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
        & python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
        & python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Set-Stamp "cuda_dlls" "ok"
        Write-Host "  CUDA DLLs: $($cudaDlls.Count) installed" -ForegroundColor Green
    }

    # [3] Engine - skip if llama-server.exe already present for this tag
    Write-Host "[3/7] Engine..." -ForegroundColor Yellow
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ((Get-Stamp "engine") -eq $tag -and $exePath -and (Test-Path $exePath)) {
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Engine cached ($tag) at $binDir" -ForegroundColor Green
    } else {
        @("$W\bin","$W\bin_vulkan") | ForEach-Object {
            if (Test-Path $_) { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
        }
        New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
        Write-Host "  Downloading CUDA 12.4 engine ($tag)..." -ForegroundColor Yellow
        curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
        Expand-Archive "$W\engine.zip" "$W\bin" -Force
        Remove-Item "$W\engine.zip"
        $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Get-ChildItem "$W\bin" -Recurse -Filter "*.dll" | ForEach-Object {
            if ($_.DirectoryName -ne $binDir) { Copy-Item $_.FullName $binDir -Force }
        }
        $cudaDlls | ForEach-Object { Copy-Item $_.FullName $binDir -Force }
        Set-Stamp "engine" $tag
        Write-Host "  Engine installed. DLLs in bin: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green
    }

    # [4] Test engine - skip if stamp says cuda ok for this tag
    Write-Host "[4/7] Testing engine..." -ForegroundColor Yellow
    if ((Get-Stamp "engine_type") -eq "cuda_$tag") {
        Write-Host "  Engine type: CUDA (cached check)" -ForegroundColor Green
    } else {
        $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
        if ($p.ExitCode -ne 0) {
            Write-Host "  CUDA failed - trying Vulkan fallback..." -ForegroundColor Yellow
            if ((Get-Stamp "engine_type") -eq "vulkan_$tag" -and (Test-Path "$W\bin_vulkan")) {
                Write-Host "  Vulkan engine cached" -ForegroundColor Green
            } else {
                curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
                Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
                Remove-Item "$W\vk.zip"
            }
            $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
            $binDir  = Split-Path $exePath -Parent
            Set-Stamp "engine_type" "vulkan_$tag"
            Write-Host "  Using Vulkan" -ForegroundColor Yellow
        } else {
            Set-Stamp "engine_type" "cuda_$tag"
            Write-Host "  CUDA OK" -ForegroundColor Green
        }
    }

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
    if ($deviceList) { $deviceArg = "--device $deviceList" } else { $deviceArg = "" }
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
            Remove-Item $m -ErrorAction SilentlyContinue
            $fbUrl  = $candidate.url  -replace "\.(Q[5-9]|q[5-9])[^/]*\.gguf$", ".Q4_K_M.gguf"
            $fbFile = $candidate.file -replace "q[5-9]", "q4"
            if ($fbUrl -eq $candidate.url) {
                $sz = 0
            } else {
                Write-Host "  Download failed - trying q4 fallback..." -ForegroundColor Yellow
                $m = "$W\models\$fbFile"
                if (!(Test-Path $m) -or (Get-Item $m -EA SilentlyContinue).Length -lt 100MB) {
                    $sz = Download-Model $fbUrl $m
                } else { $sz = (Get-Item $m).Length }
            }
            if ($sz -le 100MB) {
                Write-Host "  Trying emergency fallback qvikhr-4b-q4..." -ForegroundColor Red
                $m = "$W\models\qvikhr-4b-q4.gguf"
                if (!(Test-Path $m) -or (Get-Item $m -EA SilentlyContinue).Length -lt 100MB) {
                    $sz = Download-Model "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" $m
                } else { $sz = (Get-Item $m).Length }
                if ($sz -le 100MB) { Write-Host "All downloads failed. Check network." -ForegroundColor Red; exit 1 }
            }
        }
        Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length / 1MB)) MB" -ForegroundColor Green
    }

    # [7] Start LLM server + watchdog + special services
    Write-Host "[7/7] Starting services..." -ForegroundColor Yellow
    $cmd = "Set-Location `"$binDir`"; .\llama-server.exe --model `"$m`" --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --no-warmup > `"$W\server.log`" 2>&1"
    [System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))

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

    foreach ($port in 8010, 8011, 8013, 8014) {
        "STARTING" | Out-File "$W\state_$port.txt" -Encoding UTF8 -NoNewline
    }

    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

    # Wait for LLM to become healthy.
    # No hard timeout - bail only if the llama-server process dies.
    # Use HttpWebRequest to read body even on HTTP 503 (loading model).
    $ok = $false
    $elapsed = 0
    while ($true) {
        Start-Sleep -s 5
        $elapsed += 5

        $healthStatus = ""
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://localhost:8010/health")
            $req.Timeout = 8000
            $req.Method = "GET"
            try {
                $resp = $req.GetResponse()
                $sr = [System.IO.StreamReader]::new($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
                $resp.Close()
                $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed) { $healthStatus = $parsed.status }
            } catch [System.Net.WebException] {
                $webResp = $_.Exception.Response
                if ($webResp -ne $null) {
                    $sr2 = [System.IO.StreamReader]::new($webResp.GetResponseStream())
                    $body2 = $sr2.ReadToEnd()
                    $sr2.Close()
                    $parsed2 = $body2 | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed2) { $healthStatus = $parsed2.status }
                }
            }
        } catch {}

        if ($healthStatus -eq "ok") { $ok = $true; break }

        $alive = [bool](Get-Process -Name "llama-server" -ErrorAction SilentlyContinue)
        if (-not $alive) {
            Write-Host "  llama-server process not found - crashed?" -ForegroundColor Red
            break
        }

        if ($elapsed % 30 -eq 0) {
            $statusWord = $healthStatus
            if (-not $statusWord) { $statusWord = "no response yet" }
            Write-Host ("  loading... " + $elapsed + "s, status: " + $statusWord) -ForegroundColor Gray
        }
    }
    if (-not $ok) {
        Write-Host "FAILED to start LLM. Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
        exit 1
    }
    Write-Host ("  LLM ready in " + $elapsed + "s.") -ForegroundColor Green
    "READY" | Out-File "$W\state_8010.txt" -Encoding UTF8 -NoNewline

    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    # ---- Phase 1: install packages (sequential, stamps skip already-done) ----
    $errLog11 = "$W\asr_err.log"; $errLog13 = "$W\ocr_err.log"; $errLog14 = "$W\embed_err.log"
    if ($launchOcr) {
        Write-Host "  [pkg] Checking OCR deps..." -ForegroundColor Yellow
        # Torch CUDA check
        $currentTorch = & python -c "import torch; print(torch.__version__)" 2>$null
        $torchClean = ($currentTorch -split "\+")[0]
        if ($currentTorch -match "\+(.+)") { $torchBuild = $Matches[1] } else { $torchBuild = "" }
        $torchParts = $torchClean -split "\."; if ($torchParts.Count -gt 0) { $torchMajor = [int]$torchParts[0] } else { $torchMajor = 0 }
        if ($torchParts.Count -gt 1) { $torchMinor = [int]$torchParts[1] } else { $torchMinor = 0 }
        $torchOld = ($torchMajor -lt 2) -or ($torchMajor -eq 2 -and $torchMinor -lt 7)
        $torchCpu = ($torchBuild -eq "cpu") -or ($torchBuild -eq "")
        $torchStamp = Get-Stamp "torch_cuda"
        if (($torchOld -or $torchCpu) -and $torchStamp -ne "cu128") {
            Write-Host "  Torch '$currentTorch' needs CUDA. Upgrading..." -ForegroundColor Yellow
            & python -m pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 --upgrade --no-cache-dir 2>&1 | Out-Null
            Set-Stamp "torch_cuda" "cu128"
        } else { Write-Host "  Torch '$currentTorch' OK" -ForegroundColor Green }
        # surya-ocr with stamp
        $suryaStamp = Get-Stamp "surya_ocr"
        $suryaInstalled = (& python -m pip show surya-ocr 2>$null | Select-String "^Version:") -replace "Version:\s*",""
        if ($suryaInstalled) { $suryaInstalled = $suryaInstalled.Trim() }
        $cacheStamp = Get-Stamp "surya_cache"
        if ($suryaStamp -ne $suryaInstalled -or -not $suryaInstalled) {
            Write-Host "  Installing surya-ocr..." -ForegroundColor Gray
            & python -m pip install --quiet --prefer-binary "surya-ocr" 2>> $errLog13 | Out-Null
            $suryaInstalled = (& python -m pip show surya-ocr 2>$null | Select-String "^Version:") -replace "Version:\s*",""
            if ($suryaInstalled) { $suryaInstalled = $suryaInstalled.Trim(); Set-Stamp "surya_ocr" $suryaInstalled }
        } else { Write-Host "  surya-ocr $suryaInstalled (cached)" -ForegroundColor Green }
        if ($cacheStamp -ne $suryaInstalled -and $suryaInstalled) {
            Write-Host "  Clearing stale surya model cache..." -ForegroundColor Yellow
            $hfHub = "$env:USERPROFILE\.cache\huggingface\hub"
            if (Test-Path $hfHub) { Get-ChildItem $hfHub -Directory | Where-Object { $_.Name -match "surya|vikp" } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue; Write-Host "  Removed: $($_.Name)" -ForegroundColor Gray } }
            Set-Stamp "surya_cache" $suryaInstalled
        }
        # torchvision CUDA pin after surya install
        $tvBuild = & python -c "import torchvision; v=torchvision.__version__; print('cuda' if '+cu' in v else 'cpu')" 2>$null
        $tvStamp = Get-Stamp "torchvision_cuda"
        if ($tvBuild -ne "cuda" -or $tvStamp -ne "cu128") {
            Write-Host "  Pinning torchvision CUDA..." -ForegroundColor Yellow
            & python -m pip install --quiet torchvision --index-url https://download.pytorch.org/whl/cu128 --upgrade --force-reinstall --no-cache-dir 2>&1 | Out-Null
            Set-Stamp "torchvision_cuda" "cu128"
        } else { Write-Host "  torchvision CUDA OK (cached)" -ForegroundColor Green }
    }
    if ($launchEmbed) {
        $pkgKey14 = "pkg_transformers"
        $tfInstalled = (& python -m pip show transformers 2>$null | Select-String "^Version:") -replace "Version:\s*",""
        if ($tfInstalled) { $tfInstalled = $tfInstalled.Trim() }
        $tfStamp = Get-Stamp $pkgKey14
        if (-not $tfInstalled -or $tfStamp -ne $tfInstalled) {
            Write-Host "  Installing transformers..." -ForegroundColor Gray
            & python -m pip install --quiet --prefer-binary transformers 2>> $errLog14 | Out-Null
            $tfInstalled = (& python -m pip show transformers 2>$null | Select-String "^Version:") -replace "Version:\s*",""
            if ($tfInstalled) { $tfInstalled = $tfInstalled.Trim(); Set-Stamp $pkgKey14 $tfInstalled }
        } else { Write-Host "  transformers $tfInstalled (cached)" -ForegroundColor Green }
    }
    if ($launchAsr) {
        $pkgKey11 = "pkg_gigaam"
        $gigaInstalled = (& python -m pip show gigaam 2>$null | Select-String "^Version:") -replace "Version:\s*",""
        if ($gigaInstalled) { $gigaInstalled = $gigaInstalled.Trim() }
        $gigaStamp = Get-Stamp $pkgKey11
        if (-not $gigaInstalled -or $gigaStamp -ne $gigaInstalled) {
            Write-Host "  Installing gigaam..." -ForegroundColor Gray
            & python -m pip install --quiet --prefer-binary gigaam 2>> $errLog11 | Out-Null
            $gigaInstalled = (& python -m pip show gigaam 2>$null | Select-String "^Version:") -replace "Version:\s*",""
            if ($gigaInstalled) { $gigaInstalled = $gigaInstalled.Trim(); Set-Stamp $pkgKey11 $gigaInstalled }
        } else { Write-Host "  gigaam $gigaInstalled (cached)" -ForegroundColor Green }
    }

    # ---- Phase 2: write service scripts ----
    if ($launchAsr)   { Write-AsrService }
    if ($launchOcr)   { Write-OcrService }
    if ($launchEmbed) { Write-EmbedService }

    # ---- Phase 3: start all services simultaneously ----
    $svcPorts = @{}
    if ($launchAsr) {
        Write-Host "  [ASR]   Starting GigaAM   port 8011..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\asr_service.py" -WindowStyle Hidden -RedirectStandardOutput "$W\asr.log" -RedirectStandardError $errLog11
        $svcPorts[8011] = "ASR"
        "READY" | Out-File "$W\state_8011.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchOcr) {
        Write-Host "  [OCR]   Starting surya-ocr port 8013..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\ocr_service.py" -WindowStyle Hidden -RedirectStandardOutput "$W\ocr.log" -RedirectStandardError $errLog13
        $svcPorts[8013] = "OCR"
        "READY" | Out-File "$W\state_8013.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchEmbed) {
        Write-Host "  [Embed] Starting RoSBERTa  port 8014..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\embed_service.py" -WindowStyle Hidden -RedirectStandardOutput "$W\embed.log" -RedirectStandardError $errLog14
        $svcPorts[8014] = "Embed"
        "READY" | Out-File "$W\state_8014.txt" -Encoding UTF8 -NoNewline
    }

    # ---- Phase 4: wait for all services in parallel ----
    if ($svcPorts.Count -gt 0) {
        Write-Host "  Waiting for services to become ready..." -ForegroundColor Yellow
        $pendingPorts = [System.Collections.ArrayList]::new()
        foreach ($k in $svcPorts.Keys) { $pendingPorts.Add($k) | Out-Null }
        $elapsed4 = 0
        while ($pendingPorts.Count -gt 0 -and $elapsed4 -lt 300) {
            Start-Sleep -s 3; $elapsed4 += 3
            $done4 = [System.Collections.ArrayList]::new()
            foreach ($p in @($pendingPorts)) {
                $st4 = ""
                try {
                    $rq = [System.Net.HttpWebRequest]::Create("http://localhost:$p/health")
                    $rq.Timeout = 3000; $rq.Method = "GET"
                    try {
                        $rp = $rq.GetResponse()
                        $sr5 = [System.IO.StreamReader]::new($rp.GetResponseStream())
                        $st4 = ($sr5.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                        $sr5.Close(); $rp.Close()
                    } catch [System.Net.WebException] {
                        $wr2 = $_.Exception.Response
                        if ($wr2) {
                            $sr6 = [System.IO.StreamReader]::new($wr2.GetResponseStream())
                            $st4 = ($sr6.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                            $sr6.Close()
                        }
                    }
                } catch {}
                if ($st4 -eq "ok") {
                    Write-Host ("  [{0}] ready ({1}s)" -f $svcPorts[$p], $elapsed4) -ForegroundColor Green
                    $done4.Add($p) | Out-Null
                } elseif ($st4 -and $st4 -ne "loading") {
                    Write-Host ("  [{0}] status: {1}" -f $svcPorts[$p], $st4) -ForegroundColor Yellow
                    $done4.Add($p) | Out-Null
                }
            }
            foreach ($p in @($done4)) { $pendingPorts.Remove($p) | Out-Null }
            if ($pendingPorts.Count -gt 0 -and $elapsed4 % 30 -eq 0) {
                $names = ($pendingPorts | ForEach-Object { $svcPorts[$_] }) -join ", "
                Write-Host ("  Still loading: {0} ({1}s)" -f $names, $elapsed4) -ForegroundColor Gray
            }
        }
    }

    $wdScript = "$W\watchdog.ps1"
    curl.exe -L "https://raw.githubusercontent.com/andrew9128/llm-orchestrator/main/scripts/win_watchdog.ps1" -o $wdScript --silent
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript

    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator v14.2-fix3" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"                         -ForegroundColor Green
    Write-Host "  Model:   $($candidate.name)"            -ForegroundColor Green
    Write-Host "  GPUs:    $deviceList ($totalVram MiB)"  -ForegroundColor Green
    Write-Host "  Context: $ctxSize tokens"               -ForegroundColor Green
    Write-Host "  LLM:     http://localhost:8010/v1"      -ForegroundColor Green
    if ($Mode -eq "code") { Write-Host "  [code mode] Kodify-Nano-2B: optimised for code generation, completions, refactoring" -ForegroundColor Cyan }
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8011/v1/asr"                    -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8013/v1/ocr  (surya-ocr ru+en)" -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8014/v1/embeddings"              -ForegroundColor Cyan }
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
