# LLM WIN DEPLOY v14.1
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
# STAMP HELPERS (idempotency — skip steps already done)
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
    # Only curl.exe - no huggingface_hub python (requires login, gets 401)
    # HF public models work via direct resolve URL + ?download=true
    Remove-Item $dest -ErrorAction SilentlyContinue
    $dlUrl = if ($url -notmatch "\?") { "$url`?download=true" } else { $url }
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
    # Reserve VRAM for special services depending on mode
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 512  }
    if ($deployMode -eq "doc")   { $specialMb = 1500 }
    if ($deployMode -eq "full")  { $specialMb = 2000 }
    # code mode: force Kodify-Nano-2.0 regardless of VRAM
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{
            name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3200
            url="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf"
        }
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
        [PSCustomObject]@{ name="qvikhr-8b-q8";  file="qvikhr-8b-q8.gguf";  minVram=10000; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q8_0.gguf" }
        # saiga 12B q5 (10 GB)
        [PSCustomObject]@{ name="saiga-nem12-q5"; file="saiga-nem12-q5.gguf"; minVram=9800; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5"; file="saiga-gem12-q5.gguf"; minVram=9800; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        # t-lite 8B q6 (8 GB)
        [PSCustomObject]@{ name="t-lite-8b-q6"; file="t-lite-8b-q6.gguf"; minVram=8200; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q6_K.gguf" }
        # saiga 12B q4 (8 GB)
        [PSCustomObject]@{ name="saiga-nem12-q4"; file="saiga-nem12-q4.gguf"; minVram=8300; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4"; file="saiga-gem12-q4.gguf"; minVram=8300; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        # qvikhr 8B q5 + t-lite q5 (7 GB)
        [PSCustomObject]@{ name="qvikhr-8b-q5"; file="qvikhr-8b-q5.gguf"; minVram=6800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q5"; file="t-lite-8b-q5.gguf"; minVram=6600; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q5_K_M.gguf" }
        # saiga mistral 7B q5 (6 GB)
        [PSCustomObject]@{ name="saiga-mis7b-q5"; file="saiga-mis7b-q5.gguf"; minVram=6200; url="https://huggingface.co/IlyaGusev/saiga_mistral_7b_gguf/resolve/main/saiga_mistral_7b.Q5_K_M.gguf" }
        # qvikhr 4B q8 + t-lite q4 + yagpt q4 (5-6 GB)
        [PSCustomObject]@{ name="qvikhr-4b-q8"; file="qvikhr-4b-q8.gguf"; minVram=5800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-lite-8b-q4"; file="t-lite-8b-q4.gguf"; minVram=5600; url="https://huggingface.co/t-tech/T-lite-it-1.0-GGUF/resolve/main/T-lite-it-1.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";  file="yagpt-8b-q4.gguf";  minVram=5600; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-8b-q4"; file="qvikhr-8b-q4.gguf"; minVram=5700; url="https://huggingface.co/Vikhrmodels/QVikhr-3-8B-Instruction-GGUF/resolve/main/QVikhr-3-8B-Instruction-Q4_K_M.gguf" }
        # qvikhr 4B q5/q4 (4-5 GB)
        [PSCustomObject]@{ name="qvikhr-4b-q5"; file="qvikhr-4b-q5.gguf"; minVram=4300; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4"; file="qvikhr-4b-q4.gguf"; minVram=3800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-llama8b-q4"; file="saiga-llama8b-q4.gguf"; minVram=5800; url="https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/saiga_llama3_8b.Q4_K_M.gguf" }
        # qvikhr 1.7B minimum viable
        [PSCustomObject]@{ name="qvikhr-1b-q8"; file="qvikhr-1b-q8.gguf"; minVram=2600; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4"; file="qvikhr-1b-q4.gguf"; minVram=1800; url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf" }
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
        "        import torch",
        "        from surya.ocr import run_ocr as _run",
        "        from surya.model.detection.model import load_model as load_det, load_processor as load_det_proc",
        "        from surya.model.recognition.model import load_model as load_rec",
        "        from surya.model.recognition.processor import load_processor as load_rec_proc",
        "        det_m = load_det(); det_p = load_det_proc()",
        "        rec_m = load_rec(); rec_p = load_rec_proc()",
        "        _ocr[0] = (_run, det_m, det_p, rec_m, rec_p)",
        "        ready[0] = True",
        "    except Exception as e:",
        "        print(f'CRITICAL_LOAD_ERROR: {e}', file=sys.stderr)",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "def do_ocr(image_path):",
        "    from PIL import Image",
        "    _run, det_m, det_p, rec_m, rec_p = _ocr[0]",
        "    img  = Image.open(image_path).convert('RGB')",
        "    res  = _run([img], [['ru', 'en']], det_m, det_p, rec_m, rec_p)",
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

function Write-EmbedService {
    # Direct transformers + mean pooling — avoids sentence-transformers hang on Windows
    # Model: ai-forever/ru-en-RoSBERTa (already cached from previous run)
    # Output: 768-dim embeddings, same as sentence-transformers would produce
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
        "        _tok[0] = AutoTokenizer.from_pretrained('ai-forever/ru-en-RoSBERTa')",
        "        _mdl[0] = AutoModel.from_pretrained('ai-forever/ru-en-RoSBERTa')",
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

function Start-SpecialService($scriptPath, $logPath, $port, $packages) {
    $pyOk = $false
    try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}
    if (!$pyOk) { Write-Host "  Python not found!" -ForegroundColor Red; return }
    
    $errLog = $logPath -replace "\.log$", "_err.log"
    
    if ($packages) {
        Write-Host "  Aligning dependencies for $port (Torch 2.7.1+cu124)..." -ForegroundColor Gray
        & python -m pip install --quiet --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 --no-cache-dir
        
        foreach ($pkg in $packages.Split(" ")) {
            Write-Host "  Installing $pkg..." -ForegroundColor Gray
            & python -m pip install --quiet --prefer-binary $pkg 2>> $errLog | Out-Null
        }
    }
    
    Start-Process "python" -ArgumentList $scriptPath -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errLog
    
    Start-Sleep -s 10
    $tail = Get-Content $errLog -Tail 20 -ErrorAction SilentlyContinue
    if ($tail -match "Traceback|ImportError|ModuleNotFoundError|LOAD_ERROR|OSError") {
        Write-Host "  ERROR on port $port. Check log: cat $errLog" -ForegroundColor Red
    } else {
        Write-Host "  port $port started" -ForegroundColor Green
    }
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM AUTO-DEPLOY v14.2 (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    On-demand: services start on request, auto-unload on idle" -ForegroundColor Gray

    Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -s 1
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

    # [2] CUDA DLLs + hf-hub  ── skip if stamp matches
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

    # [3] Engine  ── skip if llama-server.exe already present for this tag
    Write-Host "[3/7] Engine..." -ForegroundColor Yellow
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ((Get-Stamp "engine") -eq $tag -and $exePath -and (Test-Path $exePath)) {
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Engine cached ($tag) at $binDir" -ForegroundColor Green
    } else {
        # Fresh install: wipe old bin, download, extract
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

    # [4] Test engine  ── skip test if stamp says cuda ok for this tag
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
            # Try q4 variant of same model
            Remove-Item $m -ErrorAction SilentlyContinue
            $fbUrl  = $candidate.url  -replace "\.(Q[5-9]|q[5-9])[^/]*\.gguf$", ".Q4_K_M.gguf"
            $fbFile = $candidate.file -replace "q[5-9]", "q4"
            if ($fbUrl -eq $candidate.url) {
                # URL didn't change (q4 pattern didn't match) - skip to emergency
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
    foreach ($port in 8010, 8011, 8013, 8014) {
        "STARTING" | Out-File "$W\state_$port.txt" -Encoding UTF8 -NoNewline
    }

    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

    $ok = $false
    for ($i = 1; $i -le 80; $i++) {
        Start-Sleep -s 3
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:8010/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $h = ($r.Content | ConvertFrom-Json).status
            if ($h -eq "ok" -or $h -eq "loading model") { $ok = $true; break }
        } catch {}
        if ($i % 5 -eq 0) { Write-Host "  loading... ($($i*3)s)" -ForegroundColor Gray }
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
        Write-Host "  [ASR] Starting GigaAM port 8011..." -ForegroundColor Yellow
        Write-AsrService
        Start-SpecialService "$W\asr_service.py" "$W\asr.log" 8011 "gigaam"
        "READY" | Out-File "$W\state_8011.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchOcr) {
        Write-Host "  [OCR] Starting surya-ocr port 8013..." -ForegroundColor Yellow
        # Clear cached model code — forces reload with updated transformers
        $hfModCache = "$env:USERPROFILE\.cache\huggingface\modules\transformers_modules\PaddlePaddle"
        if (Test-Path $hfModCache) {
            Remove-Item $hfModCache -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-OcrService
        & python -m pip install --quiet --upgrade "transformers>=4.47" 2>&1 | Out-Null
        Start-SpecialService "$W\ocr_service.py" "$W\ocr.log" 8013 "surya-ocr"
        "READY" | Out-File "$W\state_8013.txt" -Encoding UTF8 -NoNewline
    }
    if ($launchEmbed) {
        Write-Host "  [Embed] Starting RoSBERTa port 8014..." -ForegroundColor Yellow
        Write-EmbedService
        Start-SpecialService "$W\embed_service.py" "$W\embed.log" 8014 "torch transformers"
        "READY" | Out-File "$W\state_8014.txt" -Encoding UTF8 -NoNewline
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
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8011/v1/asr"        -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8013/v1/ocr  (surya-ocr ru+en)" -ForegroundColor Cyan }    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8014/v1/embeddings" -ForegroundColor Cyan }
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
