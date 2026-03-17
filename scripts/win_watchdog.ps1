# LLM WATCHDOG v15.1
# Proxy approach: writes a Python proxy script per service, starts as normal process.
# Python http.server needs no URL ACL, no admin, no runspaces.
# Services on internal ports 18011/18013/18014, proxies on public 8011/8013/8014.
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

function Log($msg) { $ts=Get-Date -Format "HH:mm:ss"; Add-Content $watchdogLog "[$ts] $msg" }

$cfg=$null
if (Test-Path "$W\config.json") { try{$cfg=Get-Content "$W\config.json" -Raw|ConvertFrom-Json}catch{} }
$launchOcr   = $cfg -and $cfg.launchOcr
$launchEmbed = $cfg -and $cfg.launchEmbed
$launchAsr   = $cfg -and $cfg.launchAsr

Log "Watchdog v15.1 started."
Log ("Idle: LLM="+($cfg.idleLlm)+"s ASR="+($cfg.idleAsr)+"s OCR="+($cfg.idleOcr)+"s Embed="+($cfg.idleEmbed)+"s")

# =============================================================================
# Write Python proxy script (one file, parameterised per service)
# =============================================================================
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
        "        except: data = b'{\"error\":\"upstream error\"}'",
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
        "                msg = b'{\"error\":\"service failed to start\"}'",
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
# Start a proxy process for a service
# =============================================================================
function Start-Proxy($pubPort, $intPort, $name, $script) {
    # Kill anything on the public port first
    try {
        $conn = Get-NetTCPConnection -LocalPort $pubPort -EA SilentlyContinue | Where-Object State -eq "Listen" | Select-Object -First 1
        if ($conn -and $conn.OwningProcess -gt 4) { Stop-Process -Id $conn.OwningProcess -Force -EA SilentlyContinue; Start-Sleep -ms 500 }
    } catch {}

    $logFile = "$W\proxy_${pubPort}.log"
    $errFile = "$W\proxy_${pubPort}_err.log"
    Start-Process "python" -ArgumentList "$W\proxy_service.py", $pubPort, $intPort, $name, $script, $W `
        -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $errFile
    Log "[$name] Proxy :$pubPort->:$intPort started"
}

function Test-ProxyAlive($pubPort) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $pubPort -EA SilentlyContinue | Where-Object State -eq "Listen"
        return [bool]$conn
    } catch { return $false }
}

# =============================================================================
# INIT: write proxy script and start proxies
# =============================================================================
Write-ProxyScript

$proxyDefs = @{}
if ($launchAsr)   { $proxyDefs[8011] = @{ int=18011; name="ASR";   script="$W\asr_service.py"   } }
if ($launchOcr)   { $proxyDefs[8013] = @{ int=18013; name="OCR";   script="$W\ocr_service.py"   } }
if ($launchEmbed) { $proxyDefs[8014] = @{ int=18014; name="Embed"; script="$W\embed_service.py" } }

foreach ($pub in @($proxyDefs.Keys)) {
    $d = $proxyDefs[$pub]
    Start-Proxy $pub $d.int $d.name $d.script
}

# =============================================================================
# MAIN LOOP: restart dead proxies + monitor LLM
# =============================================================================
$llmFail = 0; $llmUp = $false

while ($true) {
    Start-Sleep -s 15

    # Restart dead proxy processes
    foreach ($pub in @($proxyDefs.Keys)) {
        if (-not (Test-ProxyAlive $pub)) {
            Log ("Proxy :$pub not listening, restarting")
            $d = $proxyDefs[$pub]
            Start-Proxy $pub $d.int $d.name $d.script
        }
    }

    # Monitor LLM
    $llmSt = "down"
    try {
        $lr = [System.Net.HttpWebRequest]::Create("http://localhost:8010/health")
        $lr.Timeout = 3000; $lr.Method = "GET"
        try {
            $lrsp = $lr.GetResponse()
            $lsr  = [System.IO.StreamReader]::new($lrsp.GetResponseStream())
            $llmSt = ($lsr.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
            $lsr.Close(); $lrsp.Close()
        } catch [System.Net.WebException] { $llmSt = "down" }
    } catch {}

    if ($llmSt -eq "ok" -or $llmSt -eq "loading model") {
        if (-not $llmUp) { Log "[8010] LLM UP" }
        $llmUp = $true; $llmFail = 0
    } else {
        $llmFail++
        if (-not $llmUp) { continue }
        Log ("[LLM] DOWN fail " + $llmFail)
        if ($llmFail -ge 2) {
            Get-Process | Where-Object { $_.Name -match "llama" } | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -s 2
            if (Test-Path "$W\run.ps1") {
                if ($llmFail -ge 4) {
                    $rc = Get-Content "$W\run.ps1" -Raw
                    if ($rc -match "--ctx-size (\d+)") {
                        $oldCtx = [int]$Matches[1]; $newCtx = 2048
                        foreach ($s in @(32768,16384,8192,4096,2048)) { if ($s -lt $oldCtx) { $newCtx = $s; break } }
                        Log ("[LLM] ctx $oldCtx->$newCtx")
                        $rc = $rc -replace "--ctx-size \d+", "--ctx-size $newCtx"
                        [System.IO.File]::WriteAllText("$W\run.ps1", $rc, [System.Text.UTF8Encoding]::new($false))
                        $llmFail = 0
                    }
                }
                Start-Process "powershell.exe" -ArgumentList "-WindowStyle", "Hidden", "-File", "$W\run.ps1"
                Log "[LLM] Restart issued"; $llmUp = $false
            }
        }
    }
}
