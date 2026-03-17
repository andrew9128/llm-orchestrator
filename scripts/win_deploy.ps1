# LLM WIN DEPLOY v15.1 (RU/EN)
# Полная переработка. Все спецсервисы используют ONNX Runtime — без зависимости от PyTorch.
# Full rewrite. All special services use ONNX Runtime — no PyTorch dependency.
#
# Режимы / Modes:
#   chat   - только LLM / LLM only
#   voice  - LLM + ASR (GigaAM-v3 ONNX)
#   doc    - LLM + OCR (RapidOCR ONNX) + Embed (BGE-M3 fastembed ONNX)
#   full   - LLM + ASR + OCR + Embed
#
# Внутренние порты (watchdog проксирует публичные -> внутренние):
# Internal ports (watchdog proxies public->internal):
#   LLM:   8010 (прямой / direct, без прокси / no proxy)
#   ASR:   8011 -> 18011
#   OCR:   8013 -> 18013
#   Embed: 8014 -> 18014
#
# Использование / Usage:
#   win_deploy.ps1                  -- развернуть chat / deploy chat mode
#   win_deploy.ps1 -Mode voice      -- LLM + ASR
#   win_deploy.ps1 -Mode doc        -- LLM + OCR + Embed
#   win_deploy.ps1 -Mode full       -- все сервисы / all services
#   win_deploy.ps1 -Gpus 2          -- использовать 2 GPU / use 2 GPUs
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

# Таймауты простоя (сек) / Idle timeouts (sec)
$IDLE_LLM   = 600
$IDLE_ASR   = 300
$IDLE_OCR   = 300
$IDLE_EMBED = 900

# =============================================================================
# ОСТАНОВКА / STOP
# =============================================================================
function Invoke-Stop {
    Write-Host "Останавливаем все сервисы... / Stopping all services..." -ForegroundColor Yellow
    Get-Process | Where-Object { $_.Name -match "llama|whisper" } | ForEach-Object {
        Stop-Process $_ -Force -EA SilentlyContinue
        Write-Host "  Остановлен / Stopped: $($_.Name) PID $($_.Id)" -ForegroundColor Green
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
                    Write-Host "  Порт освобождён / Port freed: $port ($($proc.Name))" -ForegroundColor Green
                }
            }
        } catch {}
    }
    Remove-Item "$W\*.trigger" -EA SilentlyContinue
    Start-Sleep -s 2
    Write-Host "Готово / Done." -ForegroundColor Green
}

# =============================================================================
# СТАТУС / STATUS
# =============================================================================
function Invoke-Status {
    Write-Host "--- СТАТУС ОРКЕСТРАТОРА / ORCHESTRATOR STATUS ---" -ForegroundColor Cyan
    $portMap = @{
        8010 = "LLM"
        8011 = "ASR (GigaAM-v3 ONNX)"
        8013 = "OCR (RapidOCR ONNX)"
        8014 = "Embed (BGE-M3 ONNX)"
    }
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
        if     ($st -eq "ok")      { $color = "Green"  }
        elseif ($st -eq "loading") { $color = "Yellow" }
        elseif ($st)               { $color = "Red"    }
        else                       { $color = "Red"    }
        if (-not $st) { $st = "НЕ ЗАПУЩЕН / NOT RUNNING" }
        Write-Host "  $name [$port]: $st" -ForegroundColor $color
    }
    $wd = Get-WmiObject Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog" }
    if ($wd) { Write-Host "  Watchdog: ЗАПУЩЕН / RUNNING (PID $($wd.ProcessId))" -ForegroundColor Green }
    else     { Write-Host "  Watchdog: НЕ ЗАПУЩЕН / NOT RUNNING"                 -ForegroundColor Yellow }
    if (Test-Path "$W\watchdog.log") {
        Write-Host "  Лог watchdog (последние 5) / Watchdog log (last 5):" -ForegroundColor Gray
        Get-Content "$W\watchdog.log" -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    if (Test-Path "$W\run.ps1") {
        $run = Get-Content "$W\run.ps1" -Raw
        if ($run -match "--model\s+(\S+)")    { Write-Host "  Модель / Model:   $($Matches[1])" -ForegroundColor Cyan }
        if ($run -match "--ctx-size\s+(\d+)") { Write-Host "  Контекст / Context: $($Matches[1]) токенов / tokens" -ForegroundColor Cyan }
    }
}

# =============================================================================
# МЕТКИ КЕША / CACHE STAMPS
# =============================================================================
function Get-Stamp($name) {
    $f = "$W\stamp_$name.txt"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return "" }
}
function Set-Stamp($name, $value) { $value | Out-File "$W\stamp_$name.txt" -Encoding UTF8 -NoNewline }

# =============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ / HELPERS
# =============================================================================
function Install-Pkg($pkgId, $label) {
    Write-Host "  Проверяем / Checking: $label..." -ForegroundColor Gray
    & winget install -e --id $pkgId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Download-File($url, $dest, $label) {
    Remove-Item $dest -EA SilentlyContinue
    try {
        $wc = [System.Net.WebClient]::new()
        $wc.Headers["User-Agent"] = "Mozilla/5.0"
        $lastPct = [ref]-1
        Register-ObjectEvent $wc DownloadProgressChanged -Action {
            $pct = $EventArgs.ProgressPercentage
            $mb  = [math]::Round($EventArgs.BytesReceived / 1MB, 1)
            if ($pct -ne $lastPct.Value -and ($pct % 5 -eq 0 -or $pct -eq 100)) {
                Write-Host ("`r  $label  $pct%  ($mb МБ / MB)   ") -NoNewline
                $lastPct.Value = $pct
            }
        } | Out-Null
        $done = [System.Threading.ManualResetEventSlim]::new($false)
        Register-ObjectEvent $wc DownloadFileCompleted -Action { $done.Set() } | Out-Null
        $wc.DownloadFileAsync([uri]$url, $dest)
        $done.Wait()
        $wc.Dispose()
        Write-Host ""
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1KB) { return $true }
    } catch {
        Write-Host ""
        Write-Host "  ПРЕДУПРЕЖДЕНИЕ / WARNING: ошибка загрузки / download error — $_" -ForegroundColor Yellow
    }
    Remove-Item $dest -EA SilentlyContinue; return $false
}

function Download-HF($repo, $filename, $dest, $label) {
    $url = "https://huggingface.co/$repo/resolve/main/$filename`?download=true"
    return Download-File $url $dest $label
}

function Pip-Install($pkg, $stampKey) {
    $pkgName  = ($pkg -split "==|>=|<=|~=|\[")[0] -replace "[^a-zA-Z0-9_-]",""
    $installed = ("" + (& python -m pip show $pkgName 2>$null | Select-String "^Version:")).Trim() -replace "(?i)version:\s*",""
    $stamp     = Get-Stamp $stampKey
    if ($installed -and $stamp -eq $installed) {
        Write-Host "  $pkgName $installed (кеш / cached)" -ForegroundColor Green
        return $installed
    }
    Write-Host "  Устанавливаем / Installing: $pkg..." -ForegroundColor Gray
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
    if ($vramMb -ge 6000)  { return 8192  }
    return 8192
}

function Select-BestModel($vramMb, $deployMode) {
    # Режим code: Kodify-Nano / Code mode: Kodify-Nano
    if ($deployMode -eq "code") {
        return [PSCustomObject]@{
            name="kodify-2b-q8"; file="kodify-2b-q8.gguf"; minVram=3000
            url="https://huggingface.co/mradermacher/Kodify-Nano-2.0-GGUF/resolve/main/Kodify-Nano-2.0.Q8_0.gguf"
        }
    }

    # Резервируем VRAM под спецсервисы (ONNX — минимальный GPU)
    # Reserve VRAM for special services (ONNX — minimal GPU usage)
    $specialMb = 0
    if ($deployMode -eq "voice") { $specialMb = 700 }
    if ($deployMode -eq "doc")   { $specialMb = 100 }   # rapidocr = CPU, bge-m3 = CPU
    if ($deployMode -eq "full")  { $specialMb = 700 }   # только ASR на GPU / only ASR on GPU
    $budget = $vramMb - 1200 - $specialMb

    $catalog = @(
        # T-lite-it-2.1 (архитектура Qwen3, лучшая русскоязычная модель 2025-2026)
        [PSCustomObject]@{ name="t-lite-2.1-q8";  file="t-lite-2.1-q8.gguf";  minVram=10000; url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q6";  file="t-lite-2.1-q6.gguf";  minVram=8200;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q5";  file="t-lite-2.1-q5.gguf";  minVram=6500;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-lite-2.1-q4";  file="t-lite-2.1-q4.gguf";  minVram=5200;  url="https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q4_K_M.gguf" }
        # T-pro 32B
        [PSCustomObject]@{ name="t-pro-2.0-q8";   file="t-pro-2.0-q8.gguf";   minVram=36000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q8_0.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q6";   file="t-pro-2.0-q6.gguf";   minVram=27000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q6_K.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q5";   file="t-pro-2.0-q5.gguf";   minVram=23000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q5_K_M.gguf" }
        [PSCustomObject]@{ name="t-pro-2.0-q4";   file="t-pro-2.0-q4.gguf";   minVram=19000; url="https://huggingface.co/t-tech/T-pro-it-2.0-GGUF/resolve/main/T-pro-it-2.0-Q4_K_M.gguf" }
        # Saiga Gemma3 12B
        [PSCustomObject]@{ name="saiga-gem12-q8";  file="saiga-gem12-q8.gguf";  minVram=14500; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q8_0.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q6";  file="saiga-gem12-q6.gguf";  minVram=11000; url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q5";  file="saiga-gem12-q5.gguf";  minVram=9500;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-gem12-q4";  file="saiga-gem12-q4.gguf";  minVram=7800;  url="https://huggingface.co/IlyaGusev/saiga_gemma3_12b_gguf/resolve/main/saiga_gemma3_12b.Q4_K_M.gguf" }
        # Saiga Nemo 12B
        [PSCustomObject]@{ name="saiga-nem12-q6";  file="saiga-nem12-q6.gguf";  minVram=11000; url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q6_K.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q5";  file="saiga-nem12-q5.gguf";  minVram=9500;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q5_K_M.gguf" }
        [PSCustomObject]@{ name="saiga-nem12-q4";  file="saiga-nem12-q4.gguf";  minVram=7800;  url="https://huggingface.co/IlyaGusev/saiga_nemo_12b_gguf/resolve/main/saiga_nemo_12b.Q4_K_M.gguf" }
        # YandexGPT 8B
        [PSCustomObject]@{ name="yagpt-8b-q8";     file="yagpt-8b-q8.gguf";     minVram=10000; url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q8_0.gguf" }
        [PSCustomObject]@{ name="yagpt-8b-q4";     file="yagpt-8b-q4.gguf";     minVram=5200;  url="https://huggingface.co/yandex/YandexGPT-5-Lite-8B-GGUF/resolve/main/YandexGPT-5-Lite-8B-instruct-Q4_K_M.gguf" }
        # QVikhr 4B (компактная русская / compact Russian)
        [PSCustomObject]@{ name="qvikhr-4b-q8";    file="qvikhr-4b-q8.gguf";    minVram=5200;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q5";    file="qvikhr-4b-q5.gguf";    minVram=4000;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q5_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-4b-q4";    file="qvikhr-4b-q4.gguf";    minVram=3400;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf" }
        # Запасная / Fallback
        [PSCustomObject]@{ name="qvikhr-1b-q8";    file="qvikhr-1b-q8.gguf";    minVram=2200;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q8_0.gguf" }
        [PSCustomObject]@{ name="qvikhr-1b-q4";    file="qvikhr-1b-q4.gguf";    minVram=1800;  url="https://huggingface.co/Vikhrmodels/QVikhr-3-1.7B-Instruction-GGUF/resolve/main/QVikhr-3-1.7B-Instruction-Q4_K_M.gguf" }
    )

    $best = $catalog | Where-Object { $_.minVram -le $budget } | Select-Object -First 1
    if (-not $best) {
        Write-Host "  ПРЕДУПРЕЖДЕНИЕ / WARNING: бюджет VRAM ${budget}МБ слишком мал, используем наименьшую модель / budget too low, using smallest" -ForegroundColor Yellow
        $best = $catalog | Select-Object -Last 1
    }
    return $best
}

# =============================================================================
# ГЕНЕРАЦИЯ СКРИПТОВ СЕРВИСОВ / SERVICE SCRIPT WRITERS
# =============================================================================

function Write-AsrService {
    # GigaAM-v3 ONNX через onnx-asr — без PyTorch / via onnx-asr — no torch required
    # ИСПРАВЛЕНИЕ / FIX: модель вызывается как функция _model[0](tmp), не .transcribe()
    $lines = @(
        "import sys, json, base64, tempfile, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "IDLE_TIMEOUT = $IDLE_ASR",
        "last_req = [time.time()]",
        "_model = [None]; ready = [False]; err_msg = [None]",
        "def load_model():",
        "    try:",
        "        import onnx_asr",
        "        providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']",
        "        _model[0] = onnx_asr.load_model('gigaam-v3-e2e-rnnt', providers=providers)",
        "        ready[0] = True",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if '/health' in self.path:",
        "            self.send_response(200 if ready[0] else 503)",
        "            self.send_header('Content-Type','application/json'); self.end_headers()",
        "            if ready[0]: st = 'ok'",
        "            elif err_msg[0]: st = 'error: ' + err_msg[0][:100]",
        "            else: st = 'loading'",
        "            self.wfile.write(json.dumps({'status': st}).encode())",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode()); return",
        "        last_req[0] = time.time()",
        "        n = int(self.headers.get('Content-Length', 0))",
        "        body = json.loads(self.rfile.read(n))",
        "        audio = base64.b64decode(body.get('audio', ''))",
        "        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:",
        "            f.write(audio); tmp = f.name",
        "        try:",
        "            # FIX: TextResultsAsrAdapter callable, not .transcribe()",
        "            result = _model[0](tmp)",
        "            text = result if isinstance(result, str) else str(result)",
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
        "HTTPServer(('0.0.0.0', 18011), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\asr_service.py" -Encoding UTF8 -NoNewline
}

function Write-OcrService {
    # RapidOCR с моделями PP-OCRv5 ONNX (кириллица / cyrillic)
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
        "            self.wfile.write(json.dumps({'status': st}).encode())",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode()); return",
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
        "        self.wfile.write(json.dumps({'text': text}).encode())",
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
    # ИСПРАВЛЕНИЕ / FIX: заменено sentence-transformers (ошибка last_hidden_state)
    # на fastembed — готовые ONNX-артефакты BGE-M3 без экспорта
    # FIXED: replaced sentence-transformers (last_hidden_state mismatch) with
    # fastembed which ships pre-built ONNX for BGE-M3, no export step needed
    $lines = @(
        "import sys, json, os, time, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "IDLE_TIMEOUT = $IDLE_EMBED",
        "last_req = [time.time()]",
        "_model = [None]; ready = [False]; err_msg = [None]",
        "def load_model():",
        "    try:",
        "        from fastembed import TextEmbedding",
        "        _model[0] = TextEmbedding(model_name='BAAI/bge-m3')",
        "        print('Embed: BGE-M3 fastembed ONNX loaded', flush=True)",
        "        ready[0] = True",
        "    except Exception as e:",
        "        err_msg[0] = str(e)",
        "        print(f'LOAD_ERROR: {e}', file=sys.stderr, flush=True)",
        "class H(BaseHTTPRequestHandler):",
        "    def log_message(self, f, *a): pass",
        "    def do_GET(self):",
        "        if '/health' in self.path:",
        "            self.send_response(200 if ready[0] else 503)",
        "            self.send_header('Content-Type','application/json'); self.end_headers()",
        "            if ready[0]: st = 'ok'",
        "            elif err_msg[0]: st = 'error: ' + err_msg[0][:100]",
        "            else: st = 'loading'",
        "            self.wfile.write(json.dumps({'status': st}).encode())",
        "    def do_POST(self):",
        "        if not ready[0]:",
        "            self.send_response(503); self.send_header('Content-Type','application/json'); self.end_headers()",
        "            self.wfile.write(json.dumps({'error': err_msg[0] or 'loading'}).encode()); return",
        "        last_req[0] = time.time()",
        "        n = int(self.headers.get('Content-Length', 0))",
        "        body = json.loads(self.rfile.read(n))",
        "        texts = body.get('input', [])",
        "        if isinstance(texts, str): texts = [texts]",
        "        try:",
        "            import numpy as np",
        "            vecs = list(_model[0].embed(texts))",
        "            data = [{'index': i, 'embedding': v.tolist()} for i, v in enumerate(vecs)]",
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
        "HTTPServer(('0.0.0.0', 18014), H).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\embed_service.py" -Encoding UTF8 -NoNewline
}

# =============================================================================
# ОЖИДАНИЕ ГОТОВНОСТИ СЕРВИСА / HEALTH POLL
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
            Write-Host ("  [{0}] готов / ready ({1}с / s)" -f $label, $t) -ForegroundColor Green
            return $true
        }
        if ($st -and $st -ne "loading" -and $st -ne "down") {
            Write-Host "  [$label] статус / status: $st" -ForegroundColor Red
            return $false
        }
        if ($t % 30 -eq 0) {
            Write-Host ("  [{0}] загружается / loading... {1}с / s" -f $label, $t) -ForegroundColor Gray
        }
    }
    Write-Host ("  [{0}] таймаут / timed out после / after {1}с / s" -f $label, $timeoutSec) -ForegroundColor Red
    return $false
}

# =============================================================================
# ПРОКСИ-СКРИПТ / PROXY SCRIPT WRITER
# =============================================================================
function Write-ProxyScript {
    $lines = @(
        "import sys, os, time, json, subprocess, threading",
        "from http.server import HTTPServer, BaseHTTPRequestHandler",
        "from urllib.request import urlopen, Request",
        "from urllib.error import URLError",
        "",
        "PUB_PORT   = int(sys.argv[1])",
        "INT_PORT   = int(sys.argv[2])",
        "SVC_NAME   = sys.argv[3]",
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
        "        if hasattr(e, 'code'):",
        "            try: return json.loads(e.read()).get('status', 'error')",
        "            except: return 'error'",
        "        return 'down'",
        "    except: return 'down'",
        "",
        "def start_service():",
        "    plog(f'Запуск / Starting on :{INT_PORT}')",
        "    log_path = os.path.join(W, SVC_NAME.lower() + '_svc.log')",
        "    err_path = os.path.join(W, SVC_NAME.lower() + '_err.log')",
        "    subprocess.Popen(",
        "        [sys.executable, SVC_SCRIPT],",
        "        stdout=open(log_path, 'a'), stderr=open(err_path, 'a'),",
        "        creationflags=0x08000000",
        "    )",
        "",
        "def wait_ready(timeout=300):",
        "    t = 0",
        "    while t < timeout:",
        "        time.sleep(2); t += 2",
        "        st = get_status()",
        "        if st == 'ok': plog('ГОТОВ / UP'); return True",
        "        if st not in ('loading', 'down', 'stopped', 'unknown'): plog(f'startup: {st}'); return False",
        "        if t % 30 == 0: plog(f'загружается / loading... {t}с / s')",
        "    plog('таймаут / timed out'); return False",
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
        "                    plog('Запрос -> пробуждаем / Request -> waking service')",
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
        "plog(f'Прокси / Proxy :{PUB_PORT} -> :{INT_PORT} готов / ready')",
        "HTTPServer(('0.0.0.0', PUB_PORT), ProxyHandler).serve_forever()"
    )
    $lines -join "`n" | Out-File "$W\proxy_service.py" -Encoding UTF8 -NoNewline
}

# =============================================================================
# WATCHDOG LLM / LLM WATCHDOG WRITER
# =============================================================================
function Write-LlmWatchdog($path) {
    $lines = @(
        '# LLM Watchdog v15.2 RU/EN — следит только за LLM, прокси запускаются отдельно'
        '# Monitors LLM only, proxy processes run separately'
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
        'L "Watchdog v15.2 RU/EN запущен / started."'
        '$fail=0; $up=$false'
        'while($true) {'
        '    Start-Sleep -s 15'
        '    $st = Get-LlmSt'
        '    if ($st -eq "ok" -or $st -eq "loading model") {'
        '        if (-not $up) { L "[LLM] ЗАПУЩЕН / UP" }'
        '        $up=$true; $fail=0'
        '    } else {'
        '        $fail++'
        '        if (-not $up) { continue }'
        '        L "[LLM] УПАЛ / DOWN, попытка / fail $fail"'
        '        if ($fail -ge 2) {'
        '            Get-Process|Where-Object{$_.Name -match "llama"}|Stop-Process -Force -EA SilentlyContinue'
        '            Start-Sleep -s 2'
        '            if (Test-Path "$W\run.ps1") {'
        '                if ($fail -ge 4) {'
        '                    $rc=Get-Content "$W\run.ps1" -Raw'
        '                    if ($rc -match "--ctx-size (\d+)") {'
        '                        $old=[int]$Matches[1]; $new=2048'
        '                        foreach($s in @(32768,16384,8192,4096,2048)){if($s -lt $old){$new=$s;break}}'
        '                        L "[LLM] контекст / ctx $old -> $new"'
        '                        $rc=$rc -replace "--ctx-size \d+","--ctx-size $new"'
        '                        [System.IO.File]::WriteAllText("$W\run.ps1",$rc,[System.Text.UTF8Encoding]::new($false))'
        '                        $fail=0'
        '                    }'
        '                }'
        '                Start-Process "powershell.exe" -ArgumentList "-WindowStyle","Hidden","-File","$W\run.ps1"'
        '                L "[LLM] Перезапуск выдан / Restart issued"; $up=$false'
        '            }'
        '        }'
        '    }'
        '}'
    )
    $lines -join "`n" | Out-File $path -Encoding UTF8 -NoNewline
}

# =============================================================================
# РАЗВЁРТЫВАНИЕ / DEPLOY
# =============================================================================
function Invoke-Deploy {
    Write-Host "--- РАЗВЁРТЫВАНИЕ / LLM DEPLOY v15.1 RU/EN (GPU: $Gpus, Режим / Mode: $Mode) ---" -ForegroundColor Cyan
    Write-Host "    ONNX-стек без PyTorch для спецсервисов / ONNX-native stack: no PyTorch for special services" -ForegroundColor Gray

    Invoke-Stop
    New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

    $launchAsr   = $Mode -in @("voice","full")
    $launchOcr   = $Mode -in @("doc","full")
    $launchEmbed = $Mode -in @("doc","full")

    # ------------------------------------------------------------------
    # [1] Системные зависимости / System dependencies
    # ------------------------------------------------------------------
    Write-Host "[1/8] Системные зависимости / System dependencies..." -ForegroundColor Yellow
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
    # [2] CUDA DLLs (cu128 — Blackwell CC12.0 + старые GPU / older GPUs)
    # ------------------------------------------------------------------
    Write-Host "[2/8] CUDA DLLs (cu128)..." -ForegroundColor Yellow
    $cudaDllDir = "$W\cuda_dlls"
    if ((Get-Stamp "cuda_dlls_cu128") -eq "ok" -and (Test-Path $cudaDllDir) -and (Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll" -EA SilentlyContinue).Count -gt 3) {
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Write-Host "  CUDA DLLs: кеш / cached ($($cudaDlls.Count) dll)" -ForegroundColor Green
    } else {
        New-Item -ItemType Directory -Path $cudaDllDir -Force | Out-Null
        & python -m pip install --quiet --target $cudaDllDir nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 2>&1 | Out-Null
        $cudaDlls = Get-ChildItem $cudaDllDir -Recurse -Filter "*.dll"
        Set-Stamp "cuda_dlls_cu128" "ok"
        Write-Host "  CUDA DLLs: установлено / installed $($cudaDlls.Count)" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # [3] Движок llama-server / llama-server engine
    # ------------------------------------------------------------------
    Write-Host "[3/8] Движок llama-server / Engine..." -ForegroundColor Yellow
    $tag = "b5248"
    $exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ((Get-Stamp "engine") -eq $tag -and $exePath -and (Test-Path $exePath)) {
        $binDir = Split-Path $exePath -Parent
        Write-Host "  Движок в кеше / Engine cached ($tag)" -ForegroundColor Green
    } else {
        if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" -EA SilentlyContinue }
        New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
        Write-Host "  Скачиваем llama.cpp $tag (CUDA 12.4 сборка / build)..." -ForegroundColor Yellow
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
        Write-Host "  Движок установлен / Engine installed. DLL: $((Get-ChildItem $binDir -Filter *.dll).Count)" -ForegroundColor Green
    }

    # Тест движка, откат на Vulkan / Test engine, fallback to Vulkan
    $p = Start-Process $exePath "--version" -PassThru -Wait -NoNewWindow -RedirectStandardOutput "$W\vo.txt" -RedirectStandardError "$W\ve.txt"
    if ($p.ExitCode -ne 0) {
        Write-Host "  Тест CUDA не прошёл — пробуем Vulkan / CUDA test failed — trying Vulkan fallback..." -ForegroundColor Yellow
        if (-not (Test-Path "$W\bin_vulkan\llama-server.exe")) {
            Download-File "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" "$W\vk.zip" "llama.cpp Vulkan" | Out-Null
            New-Item -ItemType Directory -Path "$W\bin_vulkan" -Force | Out-Null
            Expand-Archive "$W\vk.zip" "$W\bin_vulkan" -Force
            Remove-Item "$W\vk.zip" -EA SilentlyContinue
        }
        $exePath = Get-ChildItem "$W\bin_vulkan" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
        $binDir  = Split-Path $exePath -Parent
        Write-Host "  Используем Vulkan / Using Vulkan" -ForegroundColor Yellow
    } else {
        Write-Host "  Движок: CUDA OK / Engine: CUDA OK" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # [4] Определение GPU / GPU detection
    # ------------------------------------------------------------------
    Write-Host "[4/8] Определяем GPU (-Gpus $Gpus) / Detecting GPUs..." -ForegroundColor Yellow
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
    if     ($gpuMode -eq "all")         { $sel = $allDevices }
    elseif ($gpuMode -match "^\d+$")    { $sel = @($allDevices | Select-Object -First ([int]$gpuMode)) }
    else                                 { $sel = @($allDevices | Select-Object -First 1) }
    if ($sel.Count -eq 0 -and $allDevices.Count -gt 0) { $sel = @($allDevices | Select-Object -First 1) }

    $totalVram  = ($sel | Measure-Object -Property vram -Sum).Sum
    $deviceList = ($sel | ForEach-Object { $_.name }) -join ","
    if ($deviceList) { $deviceArg = "--device $deviceList" } else { $deviceArg = "" }
    Write-Host "  Используем / Using: $deviceList | VRAM всего / Total: $totalVram МиБ / MiB" -ForegroundColor Green

    # ------------------------------------------------------------------
    # [5] Выбор модели LLM / Select LLM model
    # ------------------------------------------------------------------
    Write-Host "[5/8] Выбираем LLM (режим / mode=$Mode, vram=$totalVram МиБ / MiB)..." -ForegroundColor Yellow
    $candidate = Select-BestModel $totalVram $Mode
    $ctxSize   = Get-CtxSize $totalVram
    Write-Host "  Выбрана / Selected: $($candidate.name) | minVram: $($candidate.minVram)МБ / MB | ctx: $ctxSize" -ForegroundColor Cyan

    $m = "$W\models\$($candidate.file)"
    if ((Test-Path $m) -and (Get-Item $m -EA SilentlyContinue).Length -gt 100MB) {
        Write-Host "  Модель в кеше / Model cached: $($candidate.name) ($([math]::Round((Get-Item $m).Length/1MB))МБ / MB)" -ForegroundColor Green
    } else {
        Write-Host "  Скачиваем / Downloading: $($candidate.name)..." -ForegroundColor Yellow
        if ($candidate.url -notmatch "\?") { $dlUrl = "$($candidate.url)?download=true" } else { $dlUrl = $candidate.url }
        Download-File $dlUrl $m $($candidate.name) | Out-Null
        if (-not (Test-Path $m) -or (Get-Item $m).Length -lt 100MB) {
            Remove-Item $m -EA SilentlyContinue
            Write-Host "  Загрузка не удалась — аварийный fallback / Download failed — emergency fallback..." -ForegroundColor Red
            $m = "$W\models\qvikhr-4b-q4.gguf"
            Download-File "https://huggingface.co/Vikhrmodels/QVikhr-3-4B-Instruction-GGUF/resolve/main/QVikhr-3-4B-Instruction-Q4_K_M.gguf?download=true" $m "qvikhr-4b-q4 (emergency)" | Out-Null
            if (-not (Test-Path $m) -or (Get-Item $m).Length -lt 100MB) {
                Write-Host "ОШИБКА / FAILED: не удалось скачать модель / cannot download model." -ForegroundColor Red; exit 1
            }
        }
        Write-Host "  Скачано / Downloaded: $([math]::Round((Get-Item $m).Length/1MB))МБ / MB" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # [6] ONNX-пакеты для спецсервисов / ONNX packages for special services
    # ------------------------------------------------------------------
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[6/8] ONNX-пакеты / ONNX packages..." -ForegroundColor Yellow

        # onnxruntime-gpu — общая база / shared base
        $orVer = Pip-Install "onnxruntime-gpu" "onnxruntime_gpu"
        if (-not $orVer) {
            Write-Host "  onnxruntime-gpu не удался, пробуем CPU / failed, trying CPU fallback..." -ForegroundColor Yellow
            Pip-Install "onnxruntime" "onnxruntime" | Out-Null
        }

        if ($launchAsr) {
            Pip-Install "onnx-asr" "onnx_asr" | Out-Null
        }
        if ($launchOcr) {
            Pip-Install "rapidocr[onnxruntime]" "rapidocr" | Out-Null
        }
        if ($launchEmbed) {
            # fastembed вместо sentence-transformers (исправлена ошибка last_hidden_state)
            # fastembed replaces sentence-transformers (fixes last_hidden_state error)
            Pip-Install "fastembed" "fastembed" | Out-Null
        }
    } else {
        Write-Host "[6/8] ONNX-пакеты не нужны для режима chat / No ONNX packages needed for chat mode." -ForegroundColor Gray
    }

    # ------------------------------------------------------------------
    # [7] Файлы ONNX-моделей / ONNX model files
    # ------------------------------------------------------------------
    if ($launchAsr -or $launchOcr -or $launchEmbed) {
        Write-Host "[7/8] Файлы ONNX-моделей / ONNX model files..." -ForegroundColor Yellow

        if ($launchAsr) {
            $gigaamStamp = Get-Stamp "gigaam_v3_onnx"
            if ($gigaamStamp -ne "ok") {
                Write-Host "  Предзагрузка GigaAM-v3 ONNX / Pre-downloading GigaAM-v3 ONNX..." -ForegroundColor Yellow
                $dlScript = "import onnx_asr; onnx_asr.load_model('gigaam-v3-e2e-rnnt', providers=['CPUExecutionProvider']); print('ok')"
                $result = & python -c $dlScript 2>&1
                if ($result -match "ok") {
                    Set-Stamp "gigaam_v3_onnx" "ok"
                    Write-Host "  GigaAM-v3 ONNX: готов / ready" -ForegroundColor Green
                } else {
                    Write-Host "  GigaAM-v3 скачается при первом запросе / will download on first ASR request" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  GigaAM-v3 ONNX: кеш / cached" -ForegroundColor Green
            }
        }

        if ($launchOcr) {
            Write-Host "  OCR: rapidocr скачает русские модели при первом запросе / will auto-download Russian models on first request" -ForegroundColor Green
        }

        if ($launchEmbed) {
            Write-Host "  BGE-M3 (fastembed): скачается при первом запросе / will download on first request" -ForegroundColor Green
        }
    } else {
        Write-Host "[7/8] ONNX-модели не нужны для режима chat / No ONNX models needed for chat mode." -ForegroundColor Gray
    }

    # ------------------------------------------------------------------
    # [8] Запуск сервисов / Start all services
    # ------------------------------------------------------------------
    Write-Host "[8/8] Запускаем сервисы / Starting services..." -ForegroundColor Yellow

    # Сохраняем конфиг для watchdog / Save config for watchdog
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
        Write-Host "ОШИБКА запуска LLM / FAILED to start LLM. Лог / Log:" -ForegroundColor Red
        if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 20 }
        exit 1
    }

    # Генерируем скрипты сервисов / Write service scripts
    if ($launchAsr)   { Write-AsrService }
    if ($launchOcr)   { Write-OcrService }
    if ($launchEmbed) { Write-EmbedService }

    # Запускаем спецсервисы одновременно / Start special services simultaneously
    $svcPorts = @{}
    if ($launchAsr) {
        Write-Host "  [ASR]   Запускаем GigaAM-v3 ONNX / Starting..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\asr_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\asr.log" -RedirectStandardError "$W\asr_err.log"
        $svcPorts[18011] = "ASR"
    }
    if ($launchOcr) {
        Write-Host "  [OCR]   Запускаем RapidOCR ONNX / Starting..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\ocr_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\ocr.log" -RedirectStandardError "$W\ocr_err.log"
        $svcPorts[18013] = "OCR"
    }
    if ($launchEmbed) {
        Write-Host "  [Embed] Запускаем BGE-M3 fastembed ONNX / Starting..." -ForegroundColor Yellow
        Start-Process "python" -ArgumentList "$W\embed_service.py" -WindowStyle Hidden `
            -RedirectStandardOutput "$W\embed.log" -RedirectStandardError "$W\embed_err.log"
        $svcPorts[18014] = "Embed"
    }

    # Ждём готовности всех параллельно / Wait for all in parallel
    if ($svcPorts.Count -gt 0) {
        Write-Host "  Ждём сервисы / Waiting for services..." -ForegroundColor Yellow
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
                    Write-Host ("  [{0}] готов / ready ({1}с / s)" -f $svcPorts[$p], $elapsed) -ForegroundColor Green
                    $done.Add($p) | Out-Null
                } elseif ($st -and $st -ne "loading" -and $st -ne "down") {
                    Write-Host ("  [{0}] статус / status: {1}" -f $svcPorts[$p], $st) -ForegroundColor Yellow
                    $done.Add($p) | Out-Null
                }
            }
            foreach ($p in @($done)) { $pending.Remove($p) | Out-Null }
            if ($pending.Count -gt 0 -and $elapsed % 30 -eq 0) {
                $names = ($pending | ForEach-Object { $svcPorts[$_] }) -join ", "
                Write-Host ("  Ещё загружается / Still loading: {0} ({1}с / s)" -f $names, $elapsed) -ForegroundColor Gray
            }
        }
    }

    # Запускаем прокси-процессы / Start proxy processes
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

    # Минимальный watchdog — только LLM / Minimal watchdog: LLM only
    $wdScript = "$W\watchdog.ps1"
    Write-LlmWatchdog $wdScript
    Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-ExecutionPolicy", "Bypass", "-File", $wdScript

    Write-Host ""
    Write-Host "ГОТОВО / SUCCESS — LLM Orchestrator v15.1 RU/EN" -ForegroundColor Green
    Write-Host "  Режим / Mode:    $Mode"                                         -ForegroundColor Green
    Write-Host "  Модель / Model:  $($candidate.name)"                           -ForegroundColor Green
    Write-Host "  GPU:             $deviceList ($totalVram МиБ / MiB)"           -ForegroundColor Green
    Write-Host "  Контекст / Ctx:  $ctxSize токенов / tokens"                    -ForegroundColor Green
    Write-Host "  LLM:             http://localhost:8010/v1"                      -ForegroundColor Green
    if ($launchAsr)   { Write-Host "  ASR:             http://localhost:8011  (GigaAM-v3 ONNX)"          -ForegroundColor Cyan }
    if ($launchOcr)   { Write-Host "  OCR:             http://localhost:8013  (RapidOCR ONNX)"           -ForegroundColor Cyan }
    if ($launchEmbed) { Write-Host "  Embed:           http://localhost:8014  (BGE-M3 fastembed ONNX)"   -ForegroundColor Cyan }
    Write-Host ""
    Write-Host ("  Таймауты простоя / Idle timeouts: LLM={0}с  ASR={1}с  OCR={2}с  Embed={3}с" -f $IDLE_LLM, $IDLE_ASR, $IDLE_OCR, $IDLE_EMBED) -ForegroundColor Gray
    Write-Host "  Остановка / Stop:    powershell -EP Bypass -File win_deploy.ps1 --stop"   -ForegroundColor Gray
    Write-Host "  Статус / Status:     powershell -EP Bypass -File win_deploy.ps1 --status" -ForegroundColor Gray
}

# =============================================================================
# ТОЧКА ВХОДА / MAIN
# =============================================================================
switch ($Action) {
    { $_ -in "--stop",    "stop"    } { Invoke-Stop }
    { $_ -in "--status",  "status"  } { Invoke-Status }
    { $_ -in "--restart", "restart" } { Invoke-Stop; Start-Sleep -s 3; Invoke-Deploy }
    default                           { Invoke-Deploy }
}
