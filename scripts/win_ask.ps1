param([Parameter(Mandatory=$true)][string]$Prompt)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        $h = Invoke-RestMethod -Uri "http://localhost:8010/health" -TimeoutSec 3 -EA Stop
        if ($h.status -eq "ok") { $ready = $true; break }
    } catch {}
    if ($i -eq 0) { Write-Host "Waking LLM..." -ForegroundColor Yellow }
    if ($i -eq 0) {
        try { Invoke-RestMethod -Uri "http://localhost:8010/v1/models" -TimeoutSec 2 -EA Stop } catch {}
    }
    Start-Sleep -s 3
}
if (-not $ready) { Write-Error "LLM не поднялся"; exit 1 }

$body = @{ model="model"; messages=@(@{role="user"; content=$Prompt}); max_tokens=1000 } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
    $res = Invoke-RestMethod -Uri "http://localhost:8010/v1/chat/completions" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 120
    Write-Host "`n$($res.choices[0].message.content)" -ForegroundColor White
} catch { Write-Error "Ошибка запроса: $_" }
