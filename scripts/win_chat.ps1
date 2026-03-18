$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "--- Chat ---" -ForegroundColor Cyan

function Wake-LLM {
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $h = Invoke-RestMethod -Uri "http://localhost:8010/health" -TimeoutSec 3 -EA Stop
            if ($h.status -eq "ok") { return $true }
        } catch {}
        if ($i -eq 0) { Write-Host "  Waking LLM..." -ForegroundColor Yellow }
        if ($i -eq 0) { try { Invoke-RestMethod -Uri "http://localhost:8010/v1/models" -TimeoutSec 2 -EA Stop } catch {} }
        Start-Sleep -s 3
    }
    return $false
}

while($true) {
    $p = Read-Host ">>> You"
    if ($p -eq "exit") { break }
    if (-not (Wake-LLM)) { Write-Host "LLM не поднялся" -ForegroundColor Red; continue }
    $body = @{ model="model"; messages=@(@{role="user"; content=$p}); max_tokens=1000 } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $res = Invoke-RestMethod -Uri "http://localhost:8010/v1/chat/completions" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 120
        Write-Host "`nModel: $($res.choices[0].message.content)`n" -ForegroundColor Green
    } catch { Write-Host "connection error" -ForegroundColor Red }
}
