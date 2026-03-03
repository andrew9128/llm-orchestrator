param([Parameter(Mandatory=$true)][string]$Prompt)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$body = @{ model="model"; messages=@(@{role="user"; content=$Prompt}); max_tokens=1000 } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
    $res = Invoke-RestMethod -Uri "http://localhost:8010/v1/chat/completions" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
    Write-Host "`n$($res.choices[0].message.content)" -ForegroundColor White
} catch { Write-Error "Сервер не отвечает. Проверь 'make status'" }
