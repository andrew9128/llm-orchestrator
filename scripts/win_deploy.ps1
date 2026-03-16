# LLM WIN DEPLOY v14.3
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

$IDLE_LLM   = 600
$IDLE_ASR   = 300
$IDLE_OCR   = 300
$IDLE_EMBED = 900

# =============================================================================
# STOP
# =============================================================================
function Invoke-Stop {
    Write-Host "Stopping all LLM services..." -ForegroundColor Yellow
    $killed = 0
    Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
        Stop-Process $_ -Force -ErrorAction SilentlyContinue; $killed++
    }
    Write-Host "  Stopped $killed llama process(es)" -ForegroundColor Green
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and (
            $_.CommandLine -match "watchdog" -or $_.CommandLine -match "asr_service" -or
            $_.CommandLine -match "ocr_service" -or $_.CommandLine -match "embed_service"
        )
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "asr_service|ocr_service|embed_service"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
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
        8011 = "ASR (GigaAM)"
        8013 = "OCR (surya-ocr)"
        8014 = "Embedding (RoSBERTa)"
    }
    foreach ($port in 8010, 8011, 8013, 8014) {
        $name = $portMap[$port]
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $h = ($r.Content | ConvertFrom-Json).status
            $col = if ($h -eq "ok") { "Green" } elseif ($h -eq "loading") { "Yellow" } else { "Red" }
            Write-Host "  $name [$port]: $h" -ForegroundColor $col
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
    if ($wd) { Write-Host "  Watchdog: RUNNING (PID $($wd.ProcessId -join ' '))" -ForegroundColor Green }
    else      { Write-Host "  Watchdog: NOT RUNNING" -ForegroundColor Yellow }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)")    { Write-Host "  Model file: $($Matches[1])" -ForegroundColor Cyan }
        if ($run -match "--ctx-size\s+(\d+)") { Write-Host "  Context:    $($Matches[1]) tokens" -ForegroundColor Cyan }
    }
}

# =============================================================================
# STAMP HELPERS
# =============================================================================
function Get-Stamp($name) {
    $f = "$W\stamp_$name.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Set-Stamp($name, $value) {
    $value | Out-File "$W\stamp_$name.txt" -Encoding UTF8 -NoNewline
}

# =============================================================================
# DOWNLOAD MODEL  (aria2c 16 connections if available, else curl)
# =============================================================================
function Download-Model($url, $dest) {
    Remove-Item $dest -ErrorAction SilentlyContinue
    $dlUrl = if ($url -notmatch "\?") { "$url`?download=true" } else { $url }
    $fname = ($url.Split('/')[-1].Split('?')[0])
    Write-Host "  Downloading: $fname" -ForegroundColor Gray

    $aria2 = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($aria2) {
        $dir  = Split-Path $dest -Parent
        $file = Split-Path $dest -Leaf
        aria2c --continue=true --max-connection-per-server=16 --split=16 `
               --min-split-size=5M --file-allocation=none `
               --header="User-Agent: Mozilla/5.0" `
               -d $dir -o $file $dlUrl
    } else {
        curl.exe -L --retry 3 --retry-delay 5 --retry-connrefused `
            -H "User-Agent: Mozilla/5.0" `
            --max-time 7200 `
            $dlUrl -o $dest
    }

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
        [PSCustomObject]@{ name="t-pro-32b-q8";    file="t-pro-32b-q8.gguf";    minVram=36000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q6";    file="t-pro-32b-q6.gguf";    minVram=27000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q5";    file="t-pro-32b-q5.gguf";    minVram=23000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-32b-q4";    file="t-pro-32b-q4.gguf";    minVram=19000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q8";   file="saiga-nem12-q8.gguf";   minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8";   file="saiga-gem12-q8.gguf";   minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q6";   file="saiga-nem12-q6.gguf";   minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6";   file="saiga-gem12-q6.gguf";   minVram=11500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q8";    file="t-lite-8b-q8.gguf";    minVram=10000; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q8";     file="yagpt-8b-q8.gguf";     minVram=10000; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q8";    file="qvikhr-8b-q8.gguf";    minVram=10000; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q5";   file="saiga-nem12-q5.gguf";   minVram=9800;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5";   file="saiga-gem12-q5.gguf";   minVram=9800;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q6";    file="t-lite-8b-q6.gguf";    minVram=8200;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q4";   file="saiga-nem12-q4.gguf";   minVram=8300;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4";   file="saiga-gem12-q4.gguf";   minVram=8300;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q5";    file="qvikhr-8b-q5.gguf";    minVram=6800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q5";    file="t-lite-8b-q5.gguf";    minVram=6600;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-mis7b-q5";  file="saiga-mis7b-q5.gguf";  minVram=6200;  url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/saiga_mistral_7b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q8";    file="qvikhr-4b-q8.gguf";    minVram=5800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-llama8b-q4"; file="saiga-llama8b-q4.gguf"; minVram=5800;  url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q4";    file="t-lite-8b-q4.gguf";    minVram=5600;  url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";     file="yagpt-8b-q4.gguf";     minVram=5600;  url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q4";    file="qvikhr-8b-q4.gguf";    minVram=5700;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q5";    file="qvikhr-4b-q5.gguf";    minVram=4300;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4";    file="qvikhr-4b-q4.gguf";    minVram=3800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q8";    file="qvikhr-1b-q8.gguf";    minVram=2600;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4";    file="qvikhr-1b-q4.gguf";    minVram=1800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf" }
    )
    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (!$best) {
        Write-Host "  WARNING: budget $budget MB too low, using smallest" -ForegroundColor Yellow
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

function Write-OcrService {
    # surya-ocr: pure PyTorch, excellent Russian, no custom model code
    # Tries surya >= 0.7 API (RecognitionPredictor/DetectionPredictor) first,
    # falls back to surya 0.5/0.6 legacy (run_ocr + load_model functions)
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading, warnings",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "warnings.filterwarnings('ignore')",
        "os.environ['TOKENIZERS_PARALLELISM'] = 'false'",
        "os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'",
        "IDLE_TIMEOUT = $IDLE_OCR",
        "last_req = [time.time()]",
        "_state = [None]; ready = [False]; err_msg = [None]",
        "",
        "def load_model():",
        "    try:",
        "        # surya >= 0.7 predictor API",
        "        try:",
        "            from surya.recognition import RecognitionPredictor",
        "            from surya.detection import DetectionPredictor",
        "            det = DetectionPredictor()",
        "            rec = RecognitionPredictor()",
        "            _state[0] = ('new', det, rec)",
        "            ready[0] = True",
        "            print('surya: loaded new API (>=0.7)', flush=True)",
        "            return",
        "        except (ImportError, AttributeError, Exception) as _e1:",
        "            print(f'surya new API failed: {_e1}, trying legacy...', file=sys.stderr)",
        "        # surya 0.5/0.6 legacy API",
        "        from surya.ocr import run_ocr as _run",
        "        from surya.model.detection.model import load_model as ld, load_processor as ldp",
        "        from surya.model.recognition.model import load_model as lr",
        "        from surya.model.recognition.processor import load_processor as lrp",
        "        _state[0] = ('legacy', _run, ld(), ldp(), lr(), lrp())",
        "        ready[0] = True",
        "        print('surya: loaded legacy API', flush=True)",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "",
        "def do_ocr(image_path):",
        "    from PIL import Image",
        "    img = Image.open(image_path).convert('RGB')",
        "    api = _state[0][0]",
        "    if api == 'new':",
        "        _, det, rec = _state[0]",
        "        det_preds = det([img])",
        "        rec_preds = rec([img], [['ru', 'en']], det_preds)",
        "        lines = [l.text for page in rec_preds for l in page.text_lines if l.text.strip()]",
        "    else:",
        "        _, _run, det_m, det_p, rec_m, rec_p = _state[0]",
        "        res = _run([img], [['ru', 'en']], det_m, det_p, rec_m, rec_p)",
        "        lines = [l.text for page in res for l in page.text_lines if l.text.strip()]",
        "    return chr(10).join(lines)",
        "",
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
        "",
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

function Write-EmbedService {
    # Direct transformers + mean pooling. No sentence-transformers (hangs on Windows).
    # Uses local cache first (instant), downloads only on first run.
    # ignore_mismatched_sizes=True handles RobertaModel pooler mismatch.
    $lines = @(
        "import sys, json, os, time, threading, warnings",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "warnings.filterwarnings('ignore')",
        "os.environ['TOKENIZERS_PARALLELISM'] = 'false'",
        "IDLE_TIMEOUT = $IDLE_EMBED",
        "last_req = [time.time()]",
        "_tok = [None]; _mdl = [None]; ready = [False]; err_msg = [None]",
        "",
        "def mean_pool(token_emb, attn_mask):",
        "    import torch",
        "    mask = attn_mask.unsqueeze(-1).expand(token_emb.size()).float()",
        "    return (torch.sum(token_emb * mask, 1) / torch.clamp(mask.sum(1), min=1e-9)).tolist()",
        "",
        "def load_model():",
        "    try:",
        "        import torch",
        "        from transformers import AutoTokenizer, AutoModel",
        "        mid = 'ai-forever/ru-en-RoSBERTa'",
        "        try:",
        "            _tok[0] = AutoTokenizer.from_pretrained(mid, local_files_only=True)",
        "            _mdl[0] = AutoModel.from_pretrained(mid, local_files_only=True,",
        "                          ignore_mismatched_sizes=True)",
        "        except Exception:",
        "            _tok[0] = AutoTokenizer.from_pretrained(mid)",
        "            _mdl[0] = AutoModel.from_pretrained(mid, ignore_mismatched_sizes=True)",
        "        _mdl[0].eval()",
        "        ready[0] = True",
        "        print('embed: model loaded OK', flush=True)",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "",
        "def encode(texts):",
        "    import torch",
        "    enc = _tok[0](texts, padding=True, truncation=True, max_length=512, return_tensors='pt')",
        "    with torch.no_grad():",
        "        out = _mdl[0](**enc)",
        "    return mean_pool(out.last_hidden_state, enc['attention_mask'])",
        "",
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
        "",
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

# =============================================================================
# START SPECIAL SERVICE (fire-and-forget, watchdog monitors)
# =============================================================================
function Start-SpecialService($scriptPath, $logPath, $port) {
    $errLog = $logPath -replace "\.log$", "_err.log"
    Remove-Item $errLog -ErrorAction SilentlyContinue
    Start-Process "python" -ArgumentList $scriptPath -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errLog
    # Wait 6s then check for instant crash (ImportError etc)
    Start-Sleep -s 6
    $tail = Get-Content $errLog -Tail 10 -ErrorAction SilentlyContinue
    $hasCrash = $tail | Where-Object { $_ -match "LOAD_ERROR|ImportError|ModuleNotFoundError|No module named" }
    if ($hasCrash) {
        Write-Host "  port $port CRASHED:" -ForegroundColor Red
        $tail | Where-Object { $_ -match "\S" } | Select-Object -Last 4 | ForEach-Object {
            Write-Host "    $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  port $port started (model loading in background)" -ForegroundColor Green
    }
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY v14.3 (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    On-demand: services start on request, auto-unload on idle" -ForegroundColor Gray

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 1
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null
    $tag = "b5248"

    # [1] System deps
    Write-Host "[1/7] System dependencies..." -ForegroundColor Cyan
    $vcOk = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\*\VC\Runtimes\x64" -EA SilentlyContinue | Where-Object { $_.Major -ge 14 })
    if (!$vcOk) {
        Write-Host "  Installing Visual C++ Runtime..." -ForegroundColor Yellow
        $vcExe = "$env:TEMP\vc_redist.x64.exe"
        curl.exe -L -s "https://aka.ms/vs/17/release/vc_redist.x64.exe" -o $vcExe
        Start-Process $vcExe -ArgumentList "/install /quiet /norestart" -Wait
    } else { Write-Host "  Visual C++ Runtime: OK" -ForegroundColor Green }
    $pyVer = & python --version 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  Python not found!" -ForegroundColor Red; exit 1 }
    Write-Host "  Python: $pyVer" -ForegroundColor Green

    # [2] CUDA DLLs
    Write-Host "[2/7] CUDA DLLs..." -ForegroundColor Cyan
    $cudaStamp = Get-Stamp "cuda_dlls"
    if ($cudaStamp -ne $tag) {
        Write-Host "  Installing CUDA DLLs..." -ForegroundColor Gray
        & python -m pip install --quiet nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cudnn-cu12 2>&1 | Out-Null
        Set-Stamp "cuda_dlls" $tag
        Write-Host "  CUDA DLLs: installed" -ForegroundColor Green
    } else { Write-Host "  CUDA DLLs: cached" -ForegroundColor Green }

    # [3] Engine
    Write-Host "[3/7] Engine..." -ForegroundColor Cyan
    $engineStamp = Get-Stamp "engine"
    $binDir  = "$W\bin"
    $llamaExe = "$binDir\llama-server.exe"
    if ($engineStamp -ne $tag -or !(Test-Path $llamaExe)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $zipUrl  = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.2.0-x64.zip"
        $zipPath = "$env:TEMP\llama_$tag.zip"
        Write-Host "  Downloading llama-server $tag..." -ForegroundColor Gray
        curl.exe -L --retry 3 --max-time 300 $zipUrl -o $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
        Remove-Item $zipPath -EA SilentlyContinue
        Set-Stamp "engine" $tag
        Write-Host "  Engine installed" -ForegroundColor Green
    } else { Write-Host "  Engine cached ($tag) at $binDir" -ForegroundColor Green }

    # [4] Engine type
    Write-Host "[4/7] Testing engine..." -ForegroundColor Cyan
    $engineType = Get-Stamp "engine_type"
    if (!$engineType) {
        $testOut = & "$llamaExe" --version 2>&1
        $engineType = if ($testOut -match "CUDA") { "CUDA" } elseif ($testOut -match "Vulkan") { "Vulkan" } else { "CPU" }
        Set-Stamp "engine_type" $engineType
    }
    Write-Host "  Engine type: $engineType (cached)" -ForegroundColor Green

    # [5] GPU detection
    Write-Host "[5/7] Detecting GPUs (-Gpus $Gpus)..." -ForegroundColor Cyan
    $gpuArgs   = ""
    $totalVram = 0
    $gpuTestOut = & "$llamaExe" --list-devices 2>&1
    Write-Host "  Available devices:" -ForegroundColor Gray
    $cudaDevices = @()
    foreach ($line in $gpuTestOut) {
        if ($line -match "CUDA\d+.*MiB") {
            Write-Host "    $line" -ForegroundColor Gray
            if ($line -match "(\d+) MiB") { $cudaDevices += [int]$Matches[1] }
        }
        if ($line -match "ggml_cuda_init:|found \d+ CUDA") { Write-Host "  $line" -ForegroundColor Gray }
    }
    if ($Gpus -eq "all") { $numGpus = $cudaDevices.Count }
    elseif ($Gpus -match "^\d+$") { $numGpus = [int]$Gpus }
    else { $numGpus = 1 }
    if ($numGpus -gt 1 -and $cudaDevices.Count -ge $numGpus) {
        $gpuArgs   = "-ngl 999 -ts " + ($cudaDevices[0..($numGpus-1)] -join ",")
        $totalVram = ($cudaDevices[0..($numGpus-1)] | Measure-Object -Sum).Sum
        Write-Host "  Using: $numGpus GPUs | Total VRAM: $totalVram MiB" -ForegroundColor Green
    } else {
        $gpuArgs   = "-ngl 999"
        $totalVram = if ($cudaDevices.Count -gt 0) { $cudaDevices[0] } else { 0 }
        Write-Host "  Using: CUDA0 | Total VRAM: $totalVram MiB" -ForegroundColor Green
    }

    # [6] Model
    Write-Host "[6/7] Selecting model (mode=$Mode, vram=$totalVram MiB)..." -ForegroundColor Cyan
    $candidate = Select-BestModel $totalVram $Mode
    $ctx = Get-CtxSize $totalVram
    Write-Host "  Selected: $($candidate.name) | minVram: $($candidate.minVram) MB | ctx: $ctx" -ForegroundColor Green
    $modelPath = "$W\models\$($candidate.file)"
    if ((Test-Path $modelPath) -and (Get-Item $modelPath).Length -gt 100MB) {
        $sz = [math]::Round((Get-Item $modelPath).Length / 1MB)
        Write-Host "  Cached: $($candidate.name) ($sz MB)" -ForegroundColor Green
    } else {
        $sz = Download-Model $candidate.url $modelPath
        if ($sz -eq 0) {
            Write-Host "  Primary failed. Trying qvikhr-4b-q4 fallback..." -ForegroundColor Red
            $fbUrl = "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf"
            $modelPath = "$W\models\qvikhr-4b-q4.gguf"
            $sz = Download-Model $fbUrl $modelPath
            if ($sz -eq 0) { Write-Host "  All downloads failed." -ForegroundColor Red; exit 1 }
            $candidate = [PSCustomObject]@{ name="qvikhr-4b-q4"; file="qvikhr-4b-q4.gguf" }
        }
        Write-Host "  Downloaded: $([math]::Round($sz/1MB)) MB" -ForegroundColor Green
    }

    # [7] Services
    Write-Host "[7/7] Starting services..." -ForegroundColor Cyan
    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    # LLM always starts
    @"
& '$llamaExe' --model '$modelPath' $gpuArgs --ctx-size $ctx --port 8010 --host 0.0.0.0 --log-disable
"@ | Out-File "$W\run.ps1" -Encoding UTF8
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$W\run.ps1`"" -WindowStyle Hidden

    if ($launchAsr) {
        Write-Host "  [ASR] Starting GigaAM port 8011..." -ForegroundColor Yellow
        Write-AsrService
        & python -m pip install --quiet gigaam 2>&1 | Out-Null
        Start-SpecialService "$W\asr_service.py" "$W\asr.log" 8011
        "READY" | Out-File "$W\state_8011.txt" -Encoding UTF8 -NoNewline
    }

    if ($launchOcr) {
        Write-Host "  [OCR] Starting surya-ocr port 8013..." -ForegroundColor Yellow
        # Upgrade surya to latest — API compatibility with current torch
        Write-Host "  Installing/upgrading surya-ocr..." -ForegroundColor Gray
        & python -m pip install --upgrade surya-ocr 2>&1 | Where-Object { $_ -match "Successfully|Collecting|ERROR" } | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Write-OcrService
        Start-SpecialService "$W\ocr_service.py" "$W\ocr.log" 8013
        "READY" | Out-File "$W\state_8013.txt" -Encoding UTF8 -NoNewline
    }

    if ($launchEmbed) {
        Write-Host "  [Embed] Starting RoSBERTa port 8014..." -ForegroundColor Yellow
        Write-Host "  Installing torch + transformers..." -ForegroundColor Gray
        & python -m pip install --quiet torch transformers 2>&1 | Out-Null
        Write-EmbedService
        Start-SpecialService "$W\embed_service.py" "$W\embed.log" 8014
        "READY" | Out-File "$W\state_8014.txt" -Encoding UTF8 -NoNewline
    }

    # Watchdog
    $wdSrc = "$W\watchdog_src.ps1"
    $wdDst = "$W\watchdog.ps1"
    if (Test-Path $wdSrc) { Copy-Item $wdSrc $wdDst -Force }
    if (Test-Path $wdDst) {
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$wdDst`" -Mode $Mode" -WindowStyle Hidden
    }

    Start-Sleep -s 8

    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator v14.3" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"                   -ForegroundColor Cyan
    Write-Host "  Model:   $($candidate.name)"      -ForegroundColor Cyan
    Write-Host "  GPUs:    CUDA0 ($totalVram MiB)"  -ForegroundColor Cyan
    Write-Host "  Context: $ctx tokens"             -ForegroundColor Cyan
    Write-Host "  LLM:     http://localhost:8010/v1" -ForegroundColor Cyan
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8011/v1/asr" -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8013/v1/ocr  (surya-ocr ru+en)" -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8014/v1/embeddings" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "  Idle timeouts: LLM=${IDLE_LLM}s  ASR=${IDLE_ASR}s  OCR=${IDLE_OCR}s  Embed=${IDLE_EMBED}s" -ForegroundColor Gray
    Write-Host "  Stop:    powershell -EP Bypass -File win_deploy.ps1 --stop" -ForegroundColor Gray
    Write-Host "  Status:  powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor Gray
    Write-Host "  Tip: install aria2 for 4x faster model downloads: winget install aria2.aria2" -ForegroundColor Gray
}

# =============================================================================
# MAIN
# =============================================================================
switch ($Action) {
    "--stop"    { Invoke-Stop }
    "--status"  { Invoke-Status }
    "--restart" { Invoke-Stop; Start-Sleep -s 2; Invoke-Deploy }
    "--deploy"  { Invoke-Deploy }
    default     { Invoke-Deploy }
}
