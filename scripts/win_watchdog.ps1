# LLM WATCHDOG v15.0
# Permanent reverse-proxy on public ports 8011/8013/8014.
# Services run on internal ports 18011/18013/18014 (ONNX-native, no torch).
# Proxy: UP -> forward immediately; DOWN -> start, wait /health ok, forward.
$ProgressPreference = "SilentlyContinue"
$W = "$env:USERPROFILE\llm_native"
$watchdogLog = "$W\watchdog.log"

function Log($msg) { $ts=Get-Date -Format "HH:mm:ss"; Add-Content $watchdogLog "[$ts] $msg" }

$cfg=$null
if (Test-Path "$W\config.json") { try{$cfg=Get-Content "$W\config.json" -Raw|ConvertFrom-Json}catch{} }
$IDLE_LLM   = if($cfg -and $cfg.idleLlm)  {$cfg.idleLlm}  else{600}
$IDLE_OCR   = if($cfg -and $cfg.idleOcr)  {$cfg.idleOcr}  else{300}
$IDLE_EMBED = if($cfg -and $cfg.idleEmbed){$cfg.idleEmbed} else{900}
$IDLE_ASR   = if($cfg -and $cfg.idleAsr)  {$cfg.idleAsr}  else{300}
$launchOcr   = $cfg -and $cfg.launchOcr
$launchEmbed = $cfg -and $cfg.launchEmbed
$launchAsr   = $cfg -and $cfg.launchAsr

Log "Watchdog v15.0 started."
Log ("Idle: LLM="+$IDLE_LLM+"s ASR="+$IDLE_ASR+"s OCR="+$IDLE_OCR+"s Embed="+$IDLE_EMBED+"s")

# =============================================================================
# PROXY RUNSPACE: permanent HttpListener on $pub, forwards to :$int
# =============================================================================
function Start-ServiceProxy($pub,$int,$name,$script,$stateFile) {
    $vars = @"
`$pub=$pub
`$int=$int
`$svcName='$name'
`$script='$($script -replace "'","''")'
`$stateFile='$($stateFile -replace "'","''")'
`$W='$($W -replace "'","''")'
`$wLog='$($watchdogLog -replace "'","''")'
"@
    $code = $vars + @'
function PL($m){$ts=Get-Date -Format "HH:mm:ss";Add-Content $wLog "[$ts] [$svcName] $m"}

function Get-ISt{
    try{
        $r=[System.Net.HttpWebRequest]::Create("http://localhost:$int/health")
        $r.Timeout=2000;$r.Method="GET"
        try{
            $rsp=$r.GetResponse()
            $sr=[System.IO.StreamReader]::new($rsp.GetResponseStream())
            $b=$sr.ReadToEnd();$sr.Close();$rsp.Close()
            return ($b|ConvertFrom-Json -EA SilentlyContinue).status
        }catch [System.Net.WebException]{
            $wr=$_.Exception.Response
            if($wr){$sr2=[System.IO.StreamReader]::new($wr.GetResponseStream());$st=($sr2.ReadToEnd()|ConvertFrom-Json -EA SilentlyContinue).status;$sr2.Close();return $st}
            return "down"
        }
    }catch{return "down"}
}

function StartSvc{
    $errLog=$stateFile -replace "state_\d+\.txt$","svc_err.log"
    try{
        $stale=Get-NetTCPConnection -LocalPort $int -EA SilentlyContinue|Where-Object State -eq "Listen"|Select-Object -First 1
        if($stale -and $stale.OwningProcess -gt 4){Stop-Process -Id $stale.OwningProcess -Force -EA SilentlyContinue;Start-Sleep -s 1}
    }catch{}
    Start-Process "python" -ArgumentList $script -WindowStyle Hidden `
        -RedirectStandardOutput ($stateFile -replace "state_\d+\.txt$","svc.log") `
        -RedirectStandardError $errLog -EA SilentlyContinue
    "STARTING"|Out-File $stateFile -Encoding UTF8 -NoNewline
    PL "Starting on :$int"
}

function WaitSvc($sec){
    $t=0
    while($t -lt $sec){
        Start-Sleep -s 2;$t+=2
        $st=Get-ISt
        if($st -eq "ok"){"READY"|Out-File $stateFile -Encoding UTF8 -NoNewline;PL "UP";return $true}
        if($st -and $st -ne "loading" -and $st -ne "down"){PL("startup: $st");return $false}
        if($t%30 -eq 0){PL("loading... ${t}s")}
    }
    "STOPPED"|Out-File $stateFile -Encoding UTF8 -NoNewline;PL "timed out";return $false
}

function Fwd($ctx){
    $bodyBytes=$null
    try{$cl=$ctx.Request.ContentLength64;if($cl -gt 0){$bodyBytes=[byte[]]::new($cl);$ctx.Request.InputStream.Read($bodyBytes,0,$cl)|Out-Null}}catch{}
    $fUri="http://localhost:${int}"+$ctx.Request.Url.PathAndQuery
    try{
        $fq=[System.Net.HttpWebRequest]::Create($fUri);$fq.Method=$ctx.Request.HttpMethod;$fq.Timeout=120000
        if($ctx.Request.ContentType){$fq.ContentType=$ctx.Request.ContentType}
        if($bodyBytes -and $bodyBytes.Length -gt 0){$fq.ContentLength=$bodyBytes.Length;$fs=$fq.GetRequestStream();$fs.Write($bodyBytes,0,$bodyBytes.Length);$fs.Close()}
        $fc=200;$fb=$null;$fct="application/json"
        try{
            $fr=$fq.GetResponse()
            $sr3=[System.IO.StreamReader]::new($fr.GetResponseStream())
            $fb=[System.Text.Encoding]::UTF8.GetBytes($sr3.ReadToEnd());$fct=$fr.ContentType;$sr3.Close();$fr.Close()
        }catch [System.Net.WebException]{
            $fwr=$_.Exception.Response;$fc=if($fwr){[int]$fwr.StatusCode}else{503}
            if($fwr){$sr4=[System.IO.StreamReader]::new($fwr.GetResponseStream());$fb=[System.Text.Encoding]::UTF8.GetBytes($sr4.ReadToEnd());$sr4.Close()}
            else{$fb=[System.Text.Encoding]::UTF8.GetBytes('{"error":"upstream error"}')}
        }
        $ctx.Response.StatusCode=$fc;$ctx.Response.ContentType=$fct
        $ctx.Response.ContentLength64=$fb.Length;$ctx.Response.OutputStream.Write($fb,0,$fb.Length)
    }catch{
        $eb=[System.Text.Encoding]::UTF8.GetBytes('{"error":"proxy failed"}')
        $ctx.Response.StatusCode=500;$ctx.Response.ContentLength64=$eb.Length;$ctx.Response.OutputStream.Write($eb,0,$eb.Length)
    }
    try{$ctx.Response.OutputStream.Close()}catch{}
}

$listener=[System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:${pub}/")
$listener.Start()
PL "Proxy :${pub}->:${int} ready"

while($listener.IsListening){
    $ctx=$null
    try{$ctx=$listener.GetContext()}catch{break}
    $path=$ctx.Request.Url.PathAndQuery

    if($path -match "^/health"){
        $ist=Get-ISt;if(-not $ist){$ist="stopped"}
        $hb=[System.Text.Encoding]::UTF8.GetBytes('{"status":"'+$ist+'"}')
        $ctx.Response.StatusCode=if($ist -eq "ok"){200}else{503}
        $ctx.Response.ContentType="application/json"
        $ctx.Response.ContentLength64=$hb.Length;$ctx.Response.OutputStream.Write($hb,0,$hb.Length)
        try{$ctx.Response.OutputStream.Close()}catch{}
        continue
    }

    $ist=Get-ISt
    if($ist -ne "ok" -and $ist -ne "loading"){
        PL "Request -> waking service"
        StartSvc
        $ok=WaitSvc 300
        if(-not $ok){
            $eb=[System.Text.Encoding]::UTF8.GetBytes('{"error":"service failed to start"}')
            $ctx.Response.StatusCode=503;$ctx.Response.ContentLength64=$eb.Length
            $ctx.Response.OutputStream.Write($eb,0,$eb.Length)
            try{$ctx.Response.OutputStream.Close()}catch{}
            continue
        }
    } elseif($ist -eq "loading"){WaitSvc 300|Out-Null}

    Fwd $ctx
}
'@
    $rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState="MTA";$rs.ThreadOptions="ReuseThread";$rs.Open()
    $ps=[System.Management.Automation.PowerShell]::Create();$ps.Runspace=$rs
    [void]$ps.AddScript($code)
    $h=$ps.BeginInvoke()
    return @{ps=$ps;rs=$rs;handle=$h}
}

# =============================================================================
$svcDefs = @{
    8011 = @{ int=18011; name="ASR";   script="$W\asr_service.py";   state="$W\state_8011.txt" }
    8013 = @{ int=18013; name="OCR";   script="$W\ocr_service.py";   state="$W\state_8013.txt" }
    8014 = @{ int=18014; name="Embed"; script="$W\embed_service.py"; state="$W\state_8014.txt" }
}

$proxies=@{}
if($launchAsr)  {$d=$svcDefs[8011];$proxies[8011]=Start-ServiceProxy 8011 $d.int $d.name $d.script $d.state;Log "[ASR] Proxy :8011->:18011 started"}
if($launchOcr)  {$d=$svcDefs[8013];$proxies[8013]=Start-ServiceProxy 8013 $d.int $d.name $d.script $d.state;Log "[OCR] Proxy :8013->:18013 started"}
if($launchEmbed){$d=$svcDefs[8014];$proxies[8014]=Start-ServiceProxy 8014 $d.int $d.name $d.script $d.state;Log "[Embed] Proxy :8014->:18014 started"}

$llmFail=0;$llmUp=$false
while($true){
    Start-Sleep -s 10

    # Restart crashed proxy runspaces
    foreach($pub in @($proxies.Keys)){
        $px=$proxies[$pub]
        if($px.handle.IsCompleted){
            Log("Proxy :$pub crashed, restarting")
            try{$px.rs.Close()}catch{}
            $d=$svcDefs[$pub]
            $proxies[$pub]=Start-ServiceProxy $pub $d.int $d.name $d.script $d.state
        }
    }

    # Monitor LLM
    $llmSt="down"
    try{
        $lr=[System.Net.HttpWebRequest]::Create("http://localhost:8010/health")
        $lr.Timeout=3000;$lr.Method="GET"
        try{
            $lrsp=$lr.GetResponse()
            $lsr=[System.IO.StreamReader]::new($lrsp.GetResponseStream())
            $llmSt=($lsr.ReadToEnd()|ConvertFrom-Json -EA SilentlyContinue).status
            $lsr.Close();$lrsp.Close()
        }catch [System.Net.WebException]{$llmSt="down"}
    }catch{}

    if($llmSt -eq "ok" -or $llmSt -eq "loading model"){
        if(-not $llmUp){Log "[8010] LLM UP"}
        $llmUp=$true;$llmFail=0
    }else{
        $llmFail++
        if(-not $llmUp){continue}
        Log("[LLM] DOWN fail "+$llmFail)
        if($llmFail -ge 2){
            Get-Process|Where-Object{$_.Name -match "llama"}|Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -s 2
            if(Test-Path "$W\run.ps1"){
                if($llmFail -ge 4){
                    $rc=Get-Content "$W\run.ps1" -Raw
                    if($rc -match "--ctx-size (\d+)"){
                        $oldCtx=[int]$Matches[1];$newCtx=2048
                        foreach($s in @(32768,16384,8192,4096,2048)){if($s -lt $oldCtx){$newCtx=$s;break}}
                        Log("[LLM] ctx $oldCtx->$newCtx")
                        $rc=$rc -replace "--ctx-size \d+","--ctx-size $newCtx"
                        [System.IO.File]::WriteAllText("$W\run.ps1",$rc,[System.Text.UTF8Encoding]::new($false))
                        $llmFail=0
                    }
                }
                Start-Process "powershell.exe" -ArgumentList "-WindowStyle","Hidden","-File","$W\run.ps1"
                Log "[LLM] Restart issued";$llmUp=$false
            }
        }
    }
}
