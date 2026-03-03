$ErrorActionPreference = 'SilentlyContinue'
Write-Host "--- LLM Orchestrator: TOTAL PRUNE ---" -ForegroundColor Red

# 1. Остановка процессов
Write-Host "[1/4] Stopping processes..." -ForegroundColor Yellow
$killed = 0
Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
    Stop-Process $_ -Force
    $killed++
}
# Убиваем watchdog
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. Удаление задач из планировщика
Write-Host "[2/4] Removing scheduled tasks..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName "LLM-Native-Server" -Confirm:$false
Unregister-ScheduledTask -TaskName "LLM-Server" -Confirm:$false
Unregister-ScheduledTask -TaskName "LLM-Native-API" -Confirm:$false

# 3. Удаление всех файлов проекта
$W = "$env:USERPROFILE\llm_native"
if (Test-Path $W) {
    Write-Host "[3/4] Deleting project directory: $W (Models + DLLs + Logs)..." -ForegroundColor Yellow
    # Снимаем атрибуты "только для чтения", если они есть
    Get-ChildItem -Path $W -Recurse | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -Recurse -Force $W
}

# 4. Очистка временных файлов загрузки
Write-Host "[4/4] Cleaning temp files..." -ForegroundColor Yellow
$TempFiles = @("s.ps1", "d.ps1", "x.ps1", "x75.ps1", "f.ps1", "ask.ps1", "chat.ps1")
foreach ($f in $TempFiles) {
    if (Test-Path "$env:TEMP\$f") { Remove-Item -Force "$env:TEMP\$f" }
}

Write-Host "`n--- PRUNE COMPLETE ---" -ForegroundColor Green
Write-Host "System is clean. Models and engines removed."
