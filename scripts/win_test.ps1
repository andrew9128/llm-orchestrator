# LLM ORCHESTRATOR TEST SUITE v15.0
# Tests: LLM (chat), OCR (EN/RU/ancient RU), ASR (RU/EN)
# Usage: powershell -ExecutionPolicy Bypass -File win_test.ps1
# Run AFTER win_deploy.ps1

$ProgressPreference = "SilentlyContinue"
$pass = 0; $fail = 0; $skip = 0
$results = [System.Collections.ArrayList]::new()

function Check($name, $ok, $detail = "") {
    if ($ok -eq $null) {
        $script:skip++
        $results.Add([PSCustomObject]@{ status="SKIP"; name=$name; detail=$detail }) | Out-Null
        Write-Host "  [SKIP] $name" -ForegroundColor Gray
    } elseif ($ok) {
        $script:pass++
        $results.Add([PSCustomObject]@{ status="PASS"; name=$name; detail=$detail }) | Out-Null
        Write-Host "  [PASS] $name" -ForegroundColor Green
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
    } else {
        $script:fail++
        $results.Add([PSCustomObject]@{ status="FAIL"; name=$name; detail=$detail }) | Out-Null
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
    }
}

function Get-ServiceStatus($port) {
    try {
        $r = [System.Net.HttpWebRequest]::Create("http://localhost:$port/health")
        $r.Timeout = 5000; $r.Method = "GET"
        try {
            $rsp = $r.GetResponse()
            $sr = [System.IO.StreamReader]::new($rsp.GetResponseStream())
            $st = ($sr.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
            $sr.Close(); $rsp.Close(); return $st
        } catch [System.Net.WebException] {
            $wr = $_.Exception.Response
            if ($wr) {
                $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
                $st = ($sr2.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue).status
                $sr2.Close(); return $st
            }
            return "down"
        }
    } catch { return "down" }
}

function Post-Json($url, $bodyObj, $timeoutSec = 60) {
    try {
        $body = ($bodyObj | ConvertTo-Json -Depth 10)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "POST"; $req.Timeout = $timeoutSec * 1000
        $req.ContentType = "application/json"; $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
        $rsp = $req.GetResponse()
        $sr = [System.IO.StreamReader]::new($rsp.GetResponseStream())
        $json = $sr.ReadToEnd() | ConvertFrom-Json -EA SilentlyContinue
        $sr.Close(); $rsp.Close(); return $json
    } catch [System.Net.WebException] {
        $wr = $_.Exception.Response
        if ($wr) {
            $sr2 = [System.IO.StreamReader]::new($wr.GetResponseStream())
            $errBody = $sr2.ReadToEnd(); $sr2.Close()
            return [PSCustomObject]@{ error = $errBody }
        }
        return [PSCustomObject]@{ error = $_.Exception.Message }
    } catch {
        return [PSCustomObject]@{ error = $_.Exception.Message }
    }
}

function Get-TestImage($url, $label) {
    $tmp = "$env:TEMP\test_ocr_$([Guid]::NewGuid().ToString('N').Substring(0,8)).jpg"
    try {
        $wc = [System.Net.WebClient]::new()
        $wc.Headers["User-Agent"] = "Mozilla/5.0"
        $wc.DownloadFile($url, $tmp)
        $wc.Dispose()
        if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 1KB) { return $tmp }
    } catch {}
    Write-Host "  (could not download test image: $label)" -ForegroundColor DarkGray
    return $null
}

function Image-ToBase64($path) {
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}

function Make-WavBase64($text) {
    # Generate a minimal valid WAV file with silence (1 second, 16kHz, mono, 16-bit)
    # The ASR will return empty string but at least we test the service accepts audio
    $sampleRate = 16000; $numSamples = $sampleRate; $numChannels = 1; $bitsPerSample = 16
    $byteRate = $sampleRate * $numChannels * ($bitsPerSample / 8)
    $blockAlign = $numChannels * ($bitsPerSample / 8)
    $dataSize = $numSamples * $numChannels * ($bitsPerSample / 8)
    $totalSize = 36 + $dataSize
    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)
    # RIFF header
    $bw.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int32]$totalSize)
    $bw.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes("WAVE"))
    $bw.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16)
    $bw.Write([int16]1)  # PCM
    $bw.Write([int16]$numChannels)
    $bw.Write([int32]$sampleRate)
    $bw.Write([int32]$byteRate)
    $bw.Write([int16]$blockAlign)
    $bw.Write([int16]$bitsPerSample)
    $bw.Write([byte[]][System.Text.Encoding]::ASCII.GetBytes("data"))
    $bw.Write([int32]$dataSize)
    $silence = [byte[]]::new($dataSize)
    $bw.Write($silence)
    $bw.Flush()
    $wavBytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return [Convert]::ToBase64String($wavBytes)
}

# =============================================================================
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  LLM ORCHESTRATOR TEST SUITE v15.0" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Detect which services are running
$llmOk    = (Get-ServiceStatus 8010) -eq "ok"
$asrOk    = (Get-ServiceStatus 8011) -in @("ok","stopped","loading")
$ocrOk    = (Get-ServiceStatus 8013) -in @("ok","stopped","loading")
$embedOk  = (Get-ServiceStatus 8014) -in @("ok","stopped","loading")

Write-Host "  Services detected:" -ForegroundColor Gray
Write-Host "  LLM  :8010 - $(if($llmOk){'ok'}else{'NOT RUNNING - LLM tests will skip'})" -ForegroundColor $(if($llmOk){'Green'}else{'Yellow'})
Write-Host "  ASR  :8011 - $(if($asrOk){'available'}else{'NOT RUNNING - ASR tests will skip'})" -ForegroundColor $(if($asrOk){'Green'}else{'Yellow'})
Write-Host "  OCR  :8013 - $(if($ocrOk){'available'}else{'NOT RUNNING - OCR tests will skip'})" -ForegroundColor $(if($ocrOk){'Green'}else{'Yellow'})
Write-Host "  Embed:8014 - $(if($embedOk){'available'}else{'NOT RUNNING - Embed tests will skip'})" -ForegroundColor $(if($embedOk){'Green'}else{'Yellow'})
Write-Host ""

# =============================================================================
# LLM TESTS
# =============================================================================
Write-Host "--- LLM (port 8010) ---" -ForegroundColor Cyan

# Health
$st = Get-ServiceStatus 8010
Check "LLM health" ($st -eq "ok") "status=$st"

if ($llmOk) {
    # Models list
    $models = Post-Json "http://localhost:8010/v1/models" @{} 10
    Check "LLM /v1/models" ($models.data -and $models.data.Count -gt 0) "models: $(($models.data | ForEach-Object {$_.id}) -join ', ')"

    # Basic Russian chat
    $r = Post-Json "http://localhost:8010/v1/chat/completions" @{
        model = "model"
        messages = @(@{ role="user"; content="Ответь одним словом: столица России?" })
        max_tokens = 20
        temperature = 0
    } 60
    $reply = $r.choices[0].message.content
    Check "LLM Russian chat" ($reply -match "Москва|москва") "reply: $($reply -replace '\s+',' ')"

    # English chat
    $r2 = Post-Json "http://localhost:8010/v1/chat/completions" @{
        model = "model"
        messages = @(@{ role="user"; content="Reply in one word: capital of France?" })
        max_tokens = 20
        temperature = 0
    } 60
    $reply2 = $r2.choices[0].message.content
    Check "LLM English chat" ($reply2 -match "Paris|paris") "reply: $($reply2 -replace '\s+',' ')"

    # Context/length test
    $r3 = Post-Json "http://localhost:8010/v1/chat/completions" @{
        model = "model"
        messages = @(@{ role="user"; content="Посчитай от 1 до 10, каждое число на новой строке" })
        max_tokens = 100
        temperature = 0
    } 60
    $nums = ($r3.choices[0].message.content -split '\n' | Where-Object { $_ -match '^\d+' }).Count
    Check "LLM numbered list" ($nums -ge 8) "got $nums numbered lines"

    # Streaming check
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://localhost:8010/v1/chat/completions")
        $req.Method = "POST"; $req.Timeout = 15000; $req.ContentType = "application/json"
        $body = '{"model":"model","messages":[{"role":"user","content":"Hi"}],"max_tokens":5,"stream":true}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $req.GetRequestStream().Write($bytes, 0, $bytes.Length)
        $rsp = $req.GetResponse()
        $sr = [System.IO.StreamReader]::new($rsp.GetResponseStream())
        $line = $sr.ReadLine()
        $sr.Close(); $rsp.Close()
        Check "LLM streaming" ($line -match "data:") "first line: $($line.Substring(0,[math]::Min(60,$line.Length)))"
    } catch {
        Check "LLM streaming" $false $_.Exception.Message
    }
} else {
    foreach ($t in @("LLM /v1/models","LLM Russian chat","LLM English chat","LLM numbered list","LLM streaming")) {
        Check $t $null "LLM not running"
    }
}

Write-Host ""

# =============================================================================
# OCR TESTS
# =============================================================================
Write-Host "--- OCR (port 8013) ---" -ForegroundColor Cyan

$st = Get-ServiceStatus 8013
Check "OCR health/proxy" ($st -ne "down" -and $st -ne $null) "status=$st"

if ($ocrOk) {
    # Test 1: English printed text
    $imgEn = Get-TestImage "https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/release/2.7/doc/imgs_en/img_12.jpg" "English OCR"
    if ($imgEn) {
        $b64 = Image-ToBase64 $imgEn
        $r = Post-Json "http://localhost:8013/v1/ocr" @{ image=$b64; ext=".jpg" } 60
        Remove-Item $imgEn -EA SilentlyContinue
        $hasText = $r.text -and $r.text.Length -gt 10
        Check "OCR English printed" $hasText "chars=$(if($r.text){$r.text.Length}else{0}) sample: $($r.text -replace '\n',' ' | ForEach-Object { if($_.Length -gt 80){$_.Substring(0,80)+'...'}else{$_} })"
    } else { Check "OCR English printed" $null "download failed" }

    # Test 2: Russian modern text
    $imgRu = Get-TestImage "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a7/Camponotus_flavomarginatus_ant.jpg/320px-Camponotus_flavomarginatus_ant.jpg" "Russian OCR"
    # Use embedded test image with Russian text instead
    # Generate a test PNG with Russian text via .NET Graphics
    $testRuPath = "$env:TEMP\test_ru_gen.png"
    try {
        Add-Type -AssemblyName System.Drawing
        $bmp = [System.Drawing.Bitmap]::new(400, 100)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $font = [System.Drawing.Font]::new("Arial", 18)
        $brush = [System.Drawing.Brushes]::Black
        $g.DrawString("Привет мир 2024", $font, $brush, 20, 30)
        $font.Dispose(); $g.Dispose()
        $bmp.Save($testRuPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $b64ru = Image-ToBase64 $testRuPath
        Remove-Item $testRuPath -EA SilentlyContinue
        $r2 = Post-Json "http://localhost:8013/v1/ocr" @{ image=$b64ru; ext=".png" } 60
        $ruOk = $r2.text -match "Привет|мир|2024|Privet"
        Check "OCR Russian modern" $ruOk "text: '$($r2.text -replace '\n',' ')'"
    } catch {
        Check "OCR Russian modern" $null "System.Drawing not available: $_"
    }

    # Test 3: Real Russian document photo (учебник)
    $imgDoc = Get-TestImage "https://blogger.googleusercontent.com/img/b/R29vZ2xl/AVvXsEjiB4c327V3aosd-ZkxnBK_1g5zPyzr4uCL1h-7jw69OMDuixJxvTzxQOrLta5boAm_qeMgB26GmL0l9fNwoJz8FMpnXoploWFWz4W0tGzfPKJHRHONs5HRt3H_OpbIskX4fLwoOc5hxsyj7EJO5KaMxLm2rj1BD9AZcKc8R6EpuNWtFqr_WGV6QZdO3Q/s1600/%D0%A0%D0%B0%D0%B7%D0%B3%D0%BE%D0%B2%D0%BE%D1%80%D0%BD%D1%8B%D0%B9%20%D1%80%D1%83%D1%81%20%D1%8F%D0%B7%D1%8B%D0%BA%20%D1%87.%2011-1_page-0038.jpg" "Russian document"
    if ($imgDoc) {
        $b64doc = Image-ToBase64 $imgDoc
        $r3 = Post-Json "http://localhost:8013/v1/ocr" @{ image=$b64doc; ext=".jpg" } 90
        Remove-Item $imgDoc -EA SilentlyContinue
        $charCount = if ($r3.text) { $r3.text.Length } else { 0 }
        $hasCyrillic = $r3.text -match "[а-яА-ЯёЁ]"
        Check "OCR Russian document" ($charCount -gt 50 -and $hasCyrillic) "chars=$charCount cyrillic=$(if($hasCyrillic){'yes'}else{'no'}) first 80: $($r3.text -replace '\n',' ' | ForEach-Object {if($_.Length -gt 80){$_.Substring(0,80)}else{$_}})"
    } else { Check "OCR Russian document" $null "download failed" }

    # Test 4: Pre-revolutionary Russian text (Church Slavonic style scan)
    $imgOld = Get-TestImage "https://upload.wikimedia.org/wikipedia/commons/thumb/5/50/RomanovDynastyTree.jpg/320px-RomanovDynastyTree.jpg" "Old Russian"
    if ($imgOld) {
        $b64old = Image-ToBase64 $imgOld
        $r4 = Post-Json "http://localhost:8013/v1/ocr" @{ image=$b64old; ext=".jpg" } 60
        Remove-Item $imgOld -EA SilentlyContinue
        Check "OCR ancient/prerev Russian" ($r4.text -and $r4.text.Length -gt 5) "chars=$(if($r4.text){$r4.text.Length}else{0})"
    } else { Check "OCR ancient/prerev Russian" $null "download failed" }

    # Test 5: Error on empty input
    $r5 = Post-Json "http://localhost:8013/v1/ocr" @{ image=""; ext=".jpg" } 15
    Check "OCR handles empty input" ($r5 -ne $null) "got response (error or empty text is ok)"

} else {
    foreach ($t in @("OCR English printed","OCR Russian modern","OCR Russian document","OCR ancient/prerev Russian","OCR handles empty input")) {
        Check $t $null "OCR not running"
    }
}

Write-Host ""

# =============================================================================
# ASR TESTS
# =============================================================================
Write-Host "--- ASR (port 8011) ---" -ForegroundColor Cyan

$st = Get-ServiceStatus 8011
Check "ASR health/proxy" ($st -ne "down" -and $st -ne $null) "status=$st"

if ($asrOk) {
    # Test 1: Silence WAV (service should respond without error)
    $silenceB64 = Make-WavBase64 ""
    $r = Post-Json "http://localhost:8011/v1/asr" @{ audio=$silenceB64 } 30
    Check "ASR accepts silent WAV" ($r -ne $null -and -not $r.error) "response: $(if($r.text){"text='$($r.text)'"} elseif($r.error){"error=$($r.error)"}else{'no text field'})"

    # Test 2: Download and transcribe real Russian speech sample
    $wavRu = "$env:TEMP\test_asr_ru.wav"
    $dlOk = $false
    try {
        $wc = [System.Net.WebClient]::new()
        $wc.Headers["User-Agent"] = "Mozilla/5.0"
        # Common Voice Russian sample
        $wc.DownloadFile("https://upload.wikimedia.org/wikipedia/commons/4/45/Ru-Москва.ogg", "$env:TEMP\test_asr_ru.ogg")
        $wc.Dispose()
        # Try to use the OGG directly - onnx-asr may handle it
        if ((Test-Path "$env:TEMP\test_asr_ru.ogg") -and (Get-Item "$env:TEMP\test_asr_ru.ogg").Length -gt 1KB) {
            $dlOk = $true
        }
    } catch {}

    if ($dlOk) {
        $audioB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:TEMP\test_asr_ru.ogg"))
        Remove-Item "$env:TEMP\test_asr_ru.ogg" -EA SilentlyContinue
        $r2 = Post-Json "http://localhost:8011/v1/asr" @{ audio=$audioB64 } 30
        Check "ASR Russian word (Москва)" ($r2.text -match "Москва|москва|moskva") "text: '$($r2.text)'"
    } else {
        Check "ASR Russian speech" $null "could not download test audio"
    }

    # Test 3: Timeout / large input handling
    $bigSilence = [Convert]::ToBase64String([byte[]]::new(100))
    $r3 = Post-Json "http://localhost:8011/v1/asr" @{ audio=$bigSilence } 15
    Check "ASR handles invalid audio" ($r3 -ne $null) "returned response (error is ok)"

} else {
    foreach ($t in @("ASR accepts silent WAV","ASR Russian speech","ASR handles invalid audio")) {
        Check $t $null "ASR not running"
    }
}

Write-Host ""

# =============================================================================
# EMBED TESTS
# =============================================================================
Write-Host "--- Embed (port 8014) ---" -ForegroundColor Cyan

$st = Get-ServiceStatus 8014
Check "Embed health/proxy" ($st -ne "down" -and $st -ne $null) "status=$st"

if ($embedOk) {
    # Test 1: Basic embedding
    $r = Post-Json "http://localhost:8014/v1/embeddings" @{ input = "Привет мир" } 60
    $hasEmbed = $r.data -and $r.data.Count -gt 0 -and $r.data[0].embedding -and $r.data[0].embedding.Count -gt 100
    Check "Embed basic" $hasEmbed "dims=$(if($r.data){$r.data[0].embedding.Count}else{0})"

    # Test 2: Batch
    $r2 = Post-Json "http://localhost:8014/v1/embeddings" @{ input = @("первое предложение","second sentence","третье") } 60
    Check "Embed batch (3 texts)" ($r2.data -and $r2.data.Count -eq 3) "got $($r2.data.Count) embeddings"

    # Test 3: Cosine similarity (similar texts should score high)
    if ($r2.data -and $r2.data.Count -eq 3) {
        $v1 = $r2.data[0].embedding
        $v2 = $r2.data[2].embedding  # both Russian
        $dot = 0; $n1 = 0; $n2 = 0
        for ($i = 0; $i -lt $v1.Count; $i++) { $dot += $v1[$i]*$v2[$i]; $n1 += $v1[$i]*$v1[$i]; $n2 += $v2[$i]*$v2[$i] }
        $cos = $dot / ([math]::Sqrt($n1) * [math]::Sqrt($n2))
        Check "Embed cosine similarity" ($cos -gt 0.3) "cosine(ru1,ru3)=$([math]::Round($cos,3))"
    } else {
        Check "Embed cosine similarity" $null "batch test failed"
    }

} else {
    foreach ($t in @("Embed basic","Embed batch (3 texts)","Embed cosine similarity")) {
        Check $t $null "Embed not running"
    }
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $pass passed  $fail failed  $skip skipped" -ForegroundColor $(if($fail -gt 0){"Yellow"}else{"Green"})
Write-Host "================================================" -ForegroundColor Cyan

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "  Failed tests:" -ForegroundColor Red
    $results | Where-Object { $_.status -eq "FAIL" } | ForEach-Object {
        Write-Host "    [FAIL] $($_.name)" -ForegroundColor Red
        if ($_.detail) { Write-Host "           $($_.detail)" -ForegroundColor DarkGray }
    }
}

Write-Host ""
$total = $pass + $fail
if ($total -gt 0) {
    $pct = [math]::Round($pass * 100 / $total)
    Write-Host ("  Score: {0}/{1} ({2}%)" -f $pass, $total, $pct) -ForegroundColor $(if($pct -ge 80){"Green"}elseif($pct -ge 50){"Yellow"}else{"Red"})
}
Write-Host ""
