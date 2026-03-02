$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- LLM Orchestrator v6.5 (Final Polish) ---" -ForegroundColor Cyan

$W = "$env:USERPROFILE\llm_native"
$ModelPath = "$W\models\saiga.gguf"

# 1. Завершаем старые процессы
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue

# 2. Проверка файлов (они уже должны быть у тебя)
if (!(Test-Path "$W\bin\llama-server.exe")) {
    Write-Host "Engine not found, please run deploy again." -ForegroundColor Red
    exit
}

# 3. Настройка параметров для RTX 5060 (8GB)
# Кэш q4_0 — это спасение для 8ГБ, чтобы влезло 16к контекста.
$start_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable"
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 4. Попытка регистрации автозапуска (с обработкой ошибок)
try {
    $taskName = "LLM-Native-Server"
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User $env:USERNAME -Force | Out-Null
    Write-Host "Persistence: OK (Auto-start registered)" -ForegroundColor Green
} catch {
    Write-Host "Persistence: SKIPPED (Access denied to Task Scheduler)" -ForegroundColor Yellow
}

Write-Host "`n--- SERVER STARTING ---" -ForegroundColor Green
Write-Host "API: http://localhost:8010/v1"
Write-Host "Wait 30-60 seconds for GPU warmup..."

# Запуск сервера прямо сейчас в скрытом окне
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
