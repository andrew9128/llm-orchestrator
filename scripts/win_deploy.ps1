# LLM WIN DEPLOY v15.0
# Clean rewrite. All special services use ONNX Runtime - no PyTorch dependency.
#
# Modes:
#   chat   - LLM only
#   voice  - LLM + ASR (GigaAM-v3 ONNX)
#   doc    - LLM + OCR (RapidOCR ONNX) + Embed (BGE-M3 ONNX)
#   full   - LLM + ASR + OCR + Embed
#
# Internal ports (watchdog proxies public->internal):
#   LLM:   8010 (direct, no proxy)
#   ASR:   8011 -> 18011
#   OCR:   8013 -> 18013
#   Embed: 8014 -> 18014
#
# Usage:
#   win_deploy.ps1                  -- deploy chat mode
#   win_deploy.ps1 -Mode voice      -- LLM + ASR
#   win_deploy.ps1 -Mode doc        -- LLM + OCR + Embed
#   win_deploy.ps1 -Mode full       -- all services
#   win_deploy.ps1 -Gpus 2          -- use 2 GPUs
#   win_deploy.ps1 --stop
#   win_deploy.ps1 --status
#   win_deploy.ps1 --restart
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
    Get-Process | Where-Object { $_.Name -match "llama|whisper" } | ForEach-Object {
        Stop-Process $_ -Force -EA SilentlyContinue
        Write-Host "  Stopped $($_.Name) PID $($_.Id)" -ForegroundColor Green
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog|asr_service|ocr_service|embed_service|llm_native"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -match "python" -and $_.CommandLine -match "asr_service|ocr_service|embed_service"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
    }
    foreach ($port in 8010, 8011, 8013, 8014, 18011, 18013, 18014) {
        try {
            $conn = Get-NetTCPConnection -LocalPort $port -EA SilentlyContinue | Where-Object State -eq "Listen" | Select-Object -First 1
            if ($conn -and $conn.OwningProcess -gt 4) {
                $proc = Get-Process -Id $conn.OwningProcess -EA SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $conn.OwningProcess -Force -EA SilentlyContinue
                    Write-Host "  Freed port $port ($($proc.Name))" -ForegroundColor Green
                }
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
    $portMap = @{ 8010="LLM"; 8011="ASR (GigaAM-v3 ONNX)"; 8013="OCR (RapidOCR ONNX)"; 8014="Embed (BGE-M3 ONNX)" }
    foreach ($port in 8010, 8011, 8013, 8014) {
        $name = $portMap[$port]
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
        if ($st -eq "ok") { $color = "Green" } elseif ($st -eq "loading") { $color = "Yellow" } elseif ($st) { $color = "Red" } else { $color = "Red" }
        if (-not $st) { $st = "NOT RUNNING" }
        Write-Host "  $name [$port]: $st" -ForegroundColor $color
    }
    $wd = Get-WmiObject Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog" }
    if ($wd) { Write-Host "  Watchdog: RUNNING (PID $($wd.ProcessId))" -ForegroundColor Green }
    else      { Write-Host "  Watchdog: NOT RUNNING" -ForegroundColor Yellow }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)") { Write-Host "  Model: $($Matches[1])" -ForegroundColor Cyan }
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
    & curl.exe -L --retry 3 --retry-delay 5 "$url" -o "$dest"
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1KB) { 
        Write-Host "  OK!" -ForegroundColor Green
        return $true 
    }
    return $false
}

function Download-HF($repo, $filename, $dest, $label) {
    $url = "https://huggingface.co/$repo/resolve/main/$filename`?download=true"
    return Download-File $url $dest $label
}

function Pip-Install($pkg, $stampKey) {
    $pkgName = ($pkg -split "==|>=|<=|~=")[0] -replace "[^a-zA-Z0-9_-]",""
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

function Select-BestModel($vramMb, $deployMode) {
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{ name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3000
            url="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf" }
    }
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 700  }
    if ($deployMode -eq "doc")   { $specialMb = 100  }
    if ($deployMode -eq "full")  { $specialMb = 700  }
    $budget = $vramMb - 1200 - $specialMb

    $catalog = @(
        [PSCustomObject]@{ name="t-lite-2.1-q8";  file="t-lite-2.1-q8.gguf";  minVram=10000; url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q6";  file="t-lite-2.1-q6.gguf";  minVram=8200;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q5";  file="t-lite-2.1-q5.gguf";  minVram=6500;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q4";  file="t-lite-2.1-q4.gguf";  minVram=5200;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q8";   file="t-pro-2.0-q8.gguf";   minVram=36000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q6";   file="t-pro-2.0-q6.gguf";   minVram=27000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q5";   file="t-pro-2.0-q5.gguf";   minVram=23000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q4";   file="t-pro-2.0-q4.gguf";   minVram=19000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q8";  file="saiga-gem12-q8.gguf";  minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6";  file="saiga-gem12-q6.gguf";  minVram=11000; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5";  file="saiga-gem12-q5.gguf";  minVram=9500;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4";  file="saiga-gem12-q4.gguf";  minVram=7800;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q6";  file="saiga-nem12-q6.gguf";  minVram=11000; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q5";  file="saiga-nem12-q5.gguf";  minVram=9500;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q4";  file="saiga-nem12-q4.gguf";  minVram=7800;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q8";     file="yagpt-8b-q8.gguf";     minVram=10000; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";     file="yagpt-8b-q4.gguf";     minVram=5200;  url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q8";    file="qvikhr-4b-q8.gguf";    minVram=5200;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q5";    file="qvikhr-4b-q5.gguf";    minVram=4000;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4";    file="qvikhr-4b-q4.gguf";    minVram=3400;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q8";    file="qvikhr-1b-q8.gguf";    minVram=2200;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4";    file="qvikhr-1b-q4.gguf";    minVram=1800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf" }
    )

    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (-not $best) {
        Write-Host "  WARNING: budget ${budget}MB too low, using smallest" -ForegroundColor Yellow
        $best = $catalog | Select-Object -Last 1
    }
    return $best
}

# =============================================================================
# SERVICE SCRIPT WRITERS
# =============================================================================
function Write-AsrService {
    $script = @"
import json, base64, tempfile, os, threading, soundfile as sf
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
    # RapidOCR with PaddleOCR v5 ONNX models (cyrillic)
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'",
        "IDLE_TIMEOUT = $IDLE_OCR",
        "last_req = [time.time()]",
        "_ocr = [None]; ready = [False]; err_msg = [None]",
        "def load_model():",
        "    try:",
        "        from rapidocr import RapidOCR, LangRec, EngineType, OCRVersion",
        "        import onnxruntime as ort",
        "        use_gpu = 'CUDAExecutionProvider' in ort.get_available_providers()",
        "        _ocr[0] = RapidOCR(params={",
        "            'Rec.lang_type': LangRec.ESLAV,",
        "            'Rec.engine_type': EngineType.CUDA if use_gpu else EngineType.ONNXRUNTIME,",
        "            'Rec.ocr_version': OCRVersion.PPOCRV5,",
        "            'Det.engine_type': EngineType.CUDA if use_gpu else EngineType.ONNXRUNTIME,",
        "        })",
        "        if use_gpu: print('OCR: CUDA ESLAV Russian PP-OCRv5', flush=True)",
        "        else: print('OCR: CPU ESLAV Russian PP-OCRv5', flush=True)",
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
        "            if ready[0]: st = 'ok'",
        "            elif err_msg[0]: st = 'error: ' + err_msg[0][:100]",
        "            else: st = 'loading'",
        "            self.wfile.write(json.dumps({'status': st}).encode('utf-8'))",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode('utf-8')); return",
        "        last_req[0] = time.time()",
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
        "def watcher():",
        "    while True:",
        "        time.sleep(30)",
        "        if ready[0] and time.time() - last_req[0] > IDLE_TIMEOUT: os._exit(0)",
        "threading.Thread(target=watcher, daemon=True).start()",
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
        _model[0] = TextEmbedding('BAAI/bge-m3')
        print('Embed: fastembed BGE-M3 ready', flush=True)
    except Exception as e:
        _err[0] = str(e)
        print(f'Embed error: {e}', flush=True)
threading.Thread(target=_load, daemon=True).start()
class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a): pass
    def _load():
        try:
            from fastembed import TextEmbedding
            supported = [m['model'] for m in TextEmbedding.list_supported_models()]
            name = 'BAAI/bge-m3' if 'BAAI/bge-m3' in supported else supported[0]
            _model[0] = TextEmbedding(name)
            print(f'Embed: {name} ready', flush=True)
        except Exception as e:
            _err[0] = str(e)
            print(f'Embed error: {e}', flush=True)
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
# HEALTH POLL - wait for service on port to return ok
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
        if ($st -eq "ok") {
            Write-Host ("  [$label] ready ({0}s)" -f $t) -ForegroundColor Green
            return $true
        }
        if ($st -and $st -ne "loading" -and $st -ne "down") {
            Write-Host "  [$label] status: $st" -ForegroundColor Red
            return $false
        }
        if ($t % 30 -eq 0) { Write-Host ("  [$label] loading... {0}s" -f $t) -ForegroundColor Gray }
    }
    Write-Host "  [$label] timed out after ${timeoutSec}s" -ForegroundColor Red
    return $false
}

function Write-ProxyScript {
    $lines = @(
        "import sys, os, time, json, subprocess, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "from urllib.request import urlopen, Request",
        "from urllib.error import URLError",
        "",
        "PUB_PORT  = int(sys.argv[1])",
        "INT_PORT  = int(sys.argv[2])",
        "SVC_NAME  = sys.argv[3]",
        "SVC_SCRIPT = sys.argv[4]",
        "W = sys.argv[5]",
        "LOG = os.path.join(W, 'watchdog.log')",
        "",
        "def plog(m):",
        "    ts = time.strftime('%H:%M:%S')",
        "    line = f'[{ts}] [{SVC_NAME}] {m}'",
        "    try:",
        "        with open(LOG, 'a', encoding='utf-8') as f: f.write(line + chr(10))",
        "    except: pass",
        "",
        "def get_status():",
        "    try:",
        "        r = urlopen(f'http://localhost:{INT_PORT}/health', timeout=2)",
        "        return json.loads(r.read()).get('status', 'unknown')",
        "    except URLError as e:",
        "        if hasattr(e, 'code'): ",
        "            try: return json.loads(e.read()).get('status', 'error')",
        "            except: return 'error'",
        "        return 'down'",
        "    except: return 'down'",
        "",
        "def start_service():",
        "    plog(f'Starting on :{INT_PORT}')",
        "    log_path = os.path.join(W, SVC_NAME.lower() + '_svc.log')",
        "    err_path = os.path.join(W, SVC_NAME.lower() + '_err.log')",
        "    subprocess.Popen(",
        "        [sys.executable, SVC_SCRIPT],",
        "        stdout=open(log_path, 'a'), stderr=open(err_path, 'a'),",
        "        creationflags=0x08000000  # CREATE_NO_WINDOW",
        "    )",
        "",
        "def wait_ready(timeout=300):",
        "    t = 0",
        "    while t < timeout:",
        "        time.sleep(2); t += 2",
        "        st = get_status()",
        "        if st == 'ok': plog('UP'); return True",
        "        if st not in ('loading', 'down', 'stopped', 'unknown'): plog(f'startup: {st}'); return False",
        "        if t % 30 == 0: plog(f'loading... {t}s')",
        "    plog('timed out'); return False",
        "",
        "def forward(handler, body_bytes):",
        "    path = handler.path",
        "    method = handler.command",
        "    ct = handler.headers.get('Content-Type', '')",
        "    try:",
        "        req = Request(f'http://localhost:{INT_PORT}{path}', data=body_bytes if body_bytes else None, method=method)",
        "        if ct: req.add_header('Content-Type', ct)",
        "        req.add_header('Content-Length', str(len(body_bytes) if body_bytes else 0))",
        "        resp = urlopen(req, timeout=120)",
        "        data = resp.read()",
        "        handler.send_response(resp.status)",
        "        handler.send_header('Content-Type', resp.headers.get('Content-Type', 'application/json'))",
        "        handler.send_header('Content-Length', str(len(data)))",
        "        handler.end_headers()",
        "        handler.wfile.write(data)",
        "    except URLError as e:",
        "        code = e.code if hasattr(e, 'code') else 503",
        "        try: data = e.read()",
        "        except: data = json.dumps({'error':'upstream error'}).encode()",
        "        handler.send_response(code)",
        "        handler.send_header('Content-Type', 'application/json')",
        "        handler.send_header('Content-Length', str(len(data)))",
        "        handler.end_headers()",
        "        handler.wfile.write(data)",
        "    except Exception as ex:",
        "        msg = json.dumps({'error': str(ex)}).encode()",
        "        handler.send_response(500)",
        "        handler.send_header('Content-Type', 'application/json')",
        "        handler.send_header('Content-Length', str(len(msg)))",
        "        handler.end_headers()",
        "        handler.wfile.write(msg)",
        "",
        "_start_lock = threading.Lock()",
        "",
        "class ProxyHandler(BaseHTTPRequestHandler):",
        "    def log_message(self, fmt, *args): pass",
        "    def _read_body(self):",
        "        cl = int(self.headers.get('Content-Length', 0))",
        "        return self.rfile.read(cl) if cl > 0 else b''",
        "    def do_GET(self): self._handle()",
        "    def do_POST(self): self._handle()",
        "    def do_PUT(self): self._handle()",
        "    def _handle(self):",
        "        if '/health' in self.path:",
        "            st = get_status()",
        "            if not st: st = 'stopped'",
        "            data = json.dumps({'status': st}).encode()",
        "            code = 200 if st == 'ok' else 503",
        "            self.send_response(code); self.send_header('Content-Type','application/json')",
        "            self.send_header('Content-Length', str(len(data))); self.end_headers()",
        "            self.wfile.write(data); return",
        "        body = self._read_body()",
        "        st = get_status()",
        "        if st != 'ok' and st != 'loading':",
        "            with _start_lock:",
        "                if get_status() not in ('ok', 'loading'):",
        "                    plog('Request -> waking service')",
        "                    start_service()",
        "            ok = wait_ready(300)",
        "            if not ok:",
        "                msg = json.dumps({'error':'service failed to start'}).encode()",
        "                self.send_response(503); self.send_header('Content-Type','application/json')",
        "                self.send_header('Content-Length', str(len(msg))); self.end_headers()",
        "                self.wfile.write(msg); return",
        "        elif st == 'loading':",
        "            wait_ready(300)",
        "        forward(self, body)",
        "",
        "plog(f'Proxy :{PUB_PORT} -> :{INT_PORT} ready')",
        "HTTPServer(('0.0.0.0', PUB_PORT), ProxyHandler).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\proxy_service.py" -Encoding UTF8 -NoNewline
}

# =============================================================================
# MINIMAL LLM WATCHDOG WRITER
# =============================================================================
function Write-LlmWatchdog($path) {
    $lines = @(
        '# LLM Watchdog v15.4 - monitors LLM only, proxy processes run separately'
        '$ProgressPreference = "SilentlyContinue"'
        '$W = "$env:USERPROFILE\llm_native"'
        '$log = "$W\watchdog.log"'
        'function L($m) { $ts=Get-Date -Format "HH:mm:ss"; Add-Content $log "[$ts] $m" }'
        ''
        'function Get-LlmSt {'
        '    try {'
        '        $r=[System.Net.HttpWebRequest]::Create("http://localhost:8010/health")'
        '        $r.Timeout=3000; $r.Method="GET"'
        '        try {'
        '            $rsp=$r.GetResponse()'
        '            $sr=[System.IO.StreamReader]::new($rsp.GetResponseStream())'
        '            $st=($sr.ReadToEnd()|ConvertFrom-Json -EA SilentlyContinue).status'
        '            $sr.Close(); $rsp.Close(); return $st'
        '        } catch [System.Net.WebException] { return "down" }'
        '    } catch { return "down" }'
        '}'
        ''
        'L "Watchdog v15.2 started."'
        '$fail=0; $up=$false'
        'while($true) {'
        '    Start-Sleep -s 15'
        '    $st = Get-LlmSt'
        '    if ($st -eq "ok" -or $st -eq "loading model") {'
        '        if (-not $up) { L "[LLM] UP" }'
        '        $up=$true; $fail=0'
        '    } else {'
        '        $fail++'
        '        if (-not $up) { continue }'
        '        L "[LLM] DOWN fail $fail"'
        '        if ($fail -ge 2) {'
        '            Get-Process|Where-Object{$_.Name -match "llama"}|Stop-Process -Force -EA SilentlyContinue'
        '            Start-Sleep -s 2'
        '            if (Test-Path "$W\run.ps1") {'
        '                if ($fail -ge 4) {'
        '                    $rc=Get-Content "$W\run.ps1" -Raw'
        '                    if ($rc -match "--ctx-size (\d+)") {'
        '                        $old=[int]$Matches[1]; $new=2048'
        '                        foreach($s in @(32768,16384,8192,4096,2048)){if($s -lt $old){$new=$s;break}}'
        '                        L "[LLM] ctx $old->$new"'
        '                        $rc=$rc -replace "--ctx-size \d+","--ctx-size $new"'
        '                        [System.IO.File]::WriteAllText("$W\run.ps1",$rc,[System.Text.UTF8Encoding]::new($false))'
        '                        $fail=0'
        '                    }'
        '                }'
        '                Start-Process "powershell.exe" -ArgumentList "-WindowStyle","Hidden","-File","$W\run.ps1"'
        '                L "[LLM] Restart issued"; $up=$false'
        '            }'
        '        }'
        '    }'
        '}'
    )
    $lines -join "`n" | Out-File $path -Encoding UTF8 -NoNewline
}

# =============================================================================
# DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- LLM DEPLOY v15.6 (GPUs: $Gpus, Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    ONNX-native stack: no PyTorch for special services" -ForegroundColor Gray

    Invoke-Stop
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    # ------------------------------------------------------------------
    # [1] System deps
    # ------------------------------------------------------------------
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

    # ------------------------------------------------------------------
    # [2] CUDA DLLs (cu128 for Blackwell CC12.0 + older GPUs)
    # ------------------------------------------------------------------
    Write-Host "[2/8] CUDA DLLs (cu128)..." -ForegroundColor Yellow
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

    # ------------------------------------------------------------------
    # [3] llama-server engine
    # ------------------------------------------------------------------
    Write-Host "[3/8] llama-server engine..." -ForegroundColor Yellow
    $tag = "b5248"
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ((Get-Stamp "engine") -eq $tag -and $exePath -and (Test-Path $exePath)) {
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Engine cached ($tag)" -ForegroundColor Green
    } else {
        if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" -EA SilentlyContinue }
        New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
        Write-Host "  Downloading llama.cpp $tag (CUDA 12.4 build)..." -ForegroundColor Yellow
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

    # Test engine, fallback to Vulkan
    $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
    if ($p.ExitCode -ne 0) {
        Write-Host "  CUDA test failed - trying Vulkan fallback..." -ForegroundColor Yellow
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

    # ------------------------------------------------------------------
    # [4] GPU detection
    # ------------------------------------------------------------------
    Write-Host "[4/8] Detecting GPUs (-Gpus $Gpus)..." -ForegroundColor Yellow
    Start-Process $exePath "--list-devices" -Wait -NoNewWindow -RedirectStandardOutput "$W\do.txt" -RedirectStandardError "$W\de.txt" -EA SilentlyContinue
    $devLines = @()
    if (Test-Path "$W\do.txt") { $devLines += Get-Content "$W\do.txt" }
    if (Test-Path "$W\de.txt") { $devLines += Get-Content "$W\de.txt" }
    $devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    $allDevices = @()
    foreach ($line in $devLines) {
        if ($line -match "^\s*([A-Za-z]+\d+):\s*(.+?)\((\d+)\s*MiB") {
            $allDevices += [PSCustomObject]@{ name=$Matches[1]; label=$Matches[2]; vram=[int]$Matches[3] }
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
    if ($deviceList) { $deviceArg = "--device $deviceList" } else { $deviceArg = "" }
    Write-Host "  Using: $deviceList | Total VRAM: $totalVram MiB" -ForegroundColor Green

    # ------------------------------------------------------------------
    # [5] LLM model
    # ------------------------------------------------------------------
    Write-Host "[5/8] Selecting LLM (mode=$Mode, vram=$totalVram MiB)..." -ForegroundColor Yellow
    $candidate = Select-BestModel $totalVram $Mode

    $ctxSize   = Get-CtxSize $totalVram
    Write-Host "  Selected: $($candidate.name) | minVram: $($candidate.minVram)MB | ctx: $ctxSize" -ForegroundColor Cyan

    $m = "$W\models\$($candidate.file)"
    if ((Test-Path $m) -and (Get-Item $m -EA SilentlyContinue).Length -gt 100MB) {
        Write-Host "  Model cached: $($candidate.name) ($([math]::Round((Get-Item $m).Length/1MB))MB)" -ForegroundColor Green
    } else {
        Write-Host "  Downloading $($candidate.name)..." -ForegroundColor Yellow
        if ($candidate.url -notmatch "\?") { $dlUrl = "$($candidate.url)?download=true" } else { $dlUrl = $candidate.url }
        Download-File $dlUrl $m $($candidate.name) | Out-Null
        if (-not (Test-Path $m) -or (Get-Item $m).Length -lt 100MB) {
            Remove-Item $m -EA SilentlyContinue
            Write-Host "  Download failed - trying emergency fallback..." -ForegroundColor Red
            $m = "$W\models\qvikhr-4b-q4.gguf"
            Download-File "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf?download=true" $m "qvikhr-4b-q4 (emergency)" | Out-Null
            if (-not (Test-Path $m) -or (Get-Item $m).Length -lt 100MB) {
                Write-Host "FAILED: cannot download model." -ForegroundColor Red; exit 1
            }
        }
        Write-Host "  Downloaded: $([math]::Round((Get-Item $m).Length/1MB))MB" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # [6] Install ONNX packages for special services
    # ------------------------------------------------------------------
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[6/8] ONNX packages..." -ForegroundColor Yellow

        $orVer = Pip-Install "onnxruntime-gpu" "onnxruntime_gpu"
        if (-not $orVer) {
            Write-Host "  onnxruntime-gpu failed, trying CPU fallback..." -ForegroundColor Yellow
            Pip-Install "onnxruntime" "onnxruntime" | Out-Null
        }

        if ($launchAsr) {
            Pip-Install "onnx-asr" "onnx_asr" | Out-Null
            Pip-Install "soundfile" "soundfile" | Out-Null
        }
        if ($launchOcr) {
            Pip-Install "rapidocr[onnxruntime]" "rapidocr" | Out-Null
        }
        if ($launchEmbed) {
            Write-Host "  Installing fastembed (latest)..." -ForegroundColor Gray
            & python -m pip install --quiet --upgrade fastembed 2>&1 | Out-Null
            Set-Stamp "fastembed" "latest"
        }
    } else {
        Write-Host "[6/8] No ONNX packages needed for chat mode." -ForegroundColor Gray
    }

    # ------------------------------------------------------------------
    # [7] Download ONNX model files
    # ------------------------------------------------------------------
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[7/8] ONNX model files..." -ForegroundColor Yellow

        if ($launchAsr) {
            $gigaamStamp = Get-Stamp "gigaam_v3_onnx"
            if ($gigaamStamp -ne "ok") {
                Write-Host "  Pre-downloading GigaAM-v3 ONNX models..." -ForegroundColor Yellow
                $dlScript = "import onnx_asr; onnx_asr.load_model('gigaam-v3-e2e-rnnt', providers=['CPUExecutionProvider']); print('ok')"
                $result = & python -c $dlScript 2>&1
                if ($result -match "ok") {
                    Set-Stamp "gigaam_v3_onnx" "ok"
                    Write-Host "  GigaAM-v3 ONNX: ready" -ForegroundColor Green
                } else {
                    Write-Host "  GigaAM-v3 will download on first ASR request" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  GigaAM-v3 ONNX: cached" -ForegroundColor Green
            }
        }

        if ($launchOcr) {
            Write-Host "  OCR: rapidocr will auto-download Russian models on first request" -ForegroundColor Green
        }

        if ($launchEmbed) {
            Write-Host "  BGE-M3 ONNX: will load on first request (auto-download)" -ForegroundColor Green
        }
    } else {
        Write-Host "[7/8] No ONNX models needed for chat mode." -ForegroundColor Gray
    }

    # ------------------------------------------------------------------
    # [8] Start all services
    # ------------------------------------------------------------------
    Write-Host "[8/8] Starting services..." -ForegroundColor Yellow

    $cfgObj = [PSCustomObject]@{
        mode        = $Mode
        idleLlm     = $IDLE_LLM; idleAsr = $IDLE_ASR; idleOcr = $IDLE_OCR; idleEmbed = $IDLE_EMBED
        modelName   = $candidate.name; ctxSize = $ctxSize; deviceList = $deviceList
        launchAsr = $launchAsr; launchOcr = $launchOcr; launchEmbed = $launchEmbed
    }
    $cfgObj | ConvertTo-Json -Depth 5 | Out-File "$W\config.json" -Encoding UTF8 -NoNewline

    # LLM
    $cmd = "Set-Location `"$binDir`"; .\llama-server.exe --model `"$m`" --port 8010 --n-gpu-layers 99 --ctx-size $ctxSize --host 0.0.0.0 $deviceArg --no-warmup > `"$W\server.log`" 2>&1"
    [System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"

    $llmReady = Wait-ServiceReady 8010 "LLM" 600
    if (-not $llmReady) {
        Write-Host "FAILED to start LLM. Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 20 }
        exit 1
    }

    # Write service scripts
    if ($launchAsr)   { Write-AsrService }
    if ($launchOcr)   { Write-OcrService }
    if ($launchEmbed) { Write-EmbedService }

    # Start special services simultaneously
    $svcPorts = @{}
    if ($launchAsr) {
        Write-Host "  [ASR]   Starting GigaAM-v3 ONNX..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\asr_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\asr.log" -RedirectStandardError "$W\asr_err.log"
        $svcPorts[18011] = "ASR"
    }
    if ($launchOcr) {
        Write-Host "  [OCR]   Starting RapidOCR ONNX..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\ocr_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\ocr.log" -RedirectStandardError "$W\ocr_err.log"
        $svcPorts[18013] = "OCR"
    }
    if ($launchEmbed) {
        Write-Host "  [Embed] Starting BGE-M3 ONNX..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\embed_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\embed.log" -RedirectStandardError "$W\embed_err.log"
        $svcPorts[18014] = "Embed"
    }

    # Wait for all in parallel
    if ($svcPorts.Count -gt 0) {
        Write-Host "  Waiting for services..." -ForegroundColor Yellow
        $pending = [System.Collections.ArrayList]::new()
        foreach ($k in $svcPorts.Keys) { $pending.Add($k) | Out-Null }
        $elapsed = 0
        while ($pending.Count -gt 0 -and $elapsed -lt 300) {
            Start-Sleep -s 3; $elapsed += 3
            $done = [System.Collections.ArrayList]::new()
            foreach ($p in @($pending)) {
                $st = ""
                try {
                    $rq = [System.Net.HttpWebRequest]::Create("http://localhost:$p/health")
                    $rq.Timeout = 3000; $rq.Method = "GET"
                    try {
                        $rp = $rq.GetResponse()
                        $sr5 = [System.IO.StreamReader]::new($rp.GetResponseStream())
                        $st = ($sr5.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                        $sr5.Close(); $rp.Close()
                    } catch [System.Net.WebException] {
                        $wr2 = $_.Exception.Response
                        if ($wr2) {
                            $sr6 = [System.IO.StreamReader]::new($wr2.GetResponseStream())
                            $st = ($sr6.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                            $sr6.Close()
                        }
                    }
                } catch {}
                if ($st -eq "ok") {
                    Write-Host ("  [{0}] ready ({1}s)" -f $svcPorts[$p], $elapsed) -ForegroundColor Green
                    $done.Add($p) | Out-Null
                } elseif ($st -and $st -ne "loading" -and $st -ne "down") {
                    Write-Host ("  [{0}] status: {1}" -f $svcPorts[$p], $st) -ForegroundColor Yellow
                    $done.Add($p) | Out-Null
                }
            }
            foreach ($p in @($done)) { $pending.Remove($p) | Out-Null }
            if ($pending.Count -gt 0 -and $elapsed % 30 -eq 0) {
                $names = ($pending | ForEach-Object { $svcPorts[$_] }) -join ", "
                Write-Host ("  Still loading: {0} ({1}s)" -f $names, $elapsed) -ForegroundColor Gray
            }
        }
    }

    # Start proxy processes
    Write-ProxyScript
    $proxyScript = "$W\proxy_service.py"
    if ($launchAsr) {
        Start-Process "python" -ArgumentList $proxyScript, "8011", "18011", "ASR", "$W\asr_service.py", $W `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8011.log" -RedirectStandardError "$W\proxy_8011_err.log"
    }
    if ($launchOcr) {
        Start-Process "python" -ArgumentList $proxyScript, "8013", "18013", "OCR", "$W\ocr_service.py", $W `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8013.log" -RedirectStandardError "$W\proxy_8013_err.log"
    }
    if ($launchEmbed) {
        Start-Process "python" -ArgumentList $proxyScript, "8014", "18014", "Embed", "$W\embed_service.py", $W `
            -WindowStyle Hidden -RedirectStandardOutput "$W\proxy_8014.log" -RedirectStandardError "$W\proxy_8014_err.log"
    }

    # Minimal watchdog: only monitors LLM restarts
    $wdScript = "$W\watchdog.ps1"
    Write-LlmWatchdog $wdScript
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript

    Write-Host ""
    Write-Host "SUCCESS - LLM Orchestrator v15.0" -ForegroundColor Green
    Write-Host "  Mode:    $Mode"                                         -ForegroundColor Green
    Write-Host "  Model:   $($candidate.name)"                           -ForegroundColor Green
    Write-Host "  GPUs:    $deviceList ($totalVram MiB)"                 -ForegroundColor Green
    Write-Host "  Context: $ctxSize tokens"                              -ForegroundColor Green
    Write-Host "  LLM:     http://localhost:8010/v1"                     -ForegroundColor Green
    if ($launchAsr)   { Write-Host "  ASR:     http://localhost:8011  (GigaAM-v3 ONNX)"  -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:     http://localhost:8013  (RapidOCR ONNX)"   -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:   http://localhost:8014  (BGE-M3 ONNX)"     -ForegroundColor Cyan }
    Write-Host ""
    Write-Host ("  Idle timeouts: LLM={0}s  ASR={1}s  OCR={2}s  Embed={3}s" -f $IDLE_LLM, $IDLE_ASR, $IDLE_OCR, $IDLE_EMBED) -ForegroundColor Gray
    Write-Host "  Stop:   powershell -EP Bypass -File win_deploy.ps1 --stop"   -ForegroundColor Gray
    Write-Host "  Status: powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor Gray
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
