$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "--- Saiga 12B Chat (type 'exit' to quit) ---" -ForegroundColor Cyan
while($true) {
    $p = Read-Host ">>> Вы"
    if ($p -eq "exit") { break }
    $body = @{ model="model"; messages=@(@{role="user"; content=$p}); max_tokens=1000 } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $res = Invoke-RestMethod -Uri "http://localhost:8010/v1/chat/completions" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
        Write-Host "`nСайга: $($res.choices[0].message.content)`n" -ForegroundColor Green
    } catch { Write-Host "Ошибка соединения" -ForegroundColor Red }
}
