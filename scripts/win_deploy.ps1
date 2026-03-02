$ErrorActionPreference = 'Stop'
$W = "$env:USERPROFILE\llm_native"
$LogFile = "$W\server_error.log"

# 1. Завершаем старое
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue

# 2. Формируем команду запуска специально для GPU 1 (RTX 5060)
# Мы добавляем флаг --device 1 (или используем переменную окружения)
$ModelPath = "$W\models\saiga.gguf"

# Создаем скрипт запуска с логом ошибок
$start_script = @"
Set-Location '$W\bin'
`$env:CUDA_VISIBLE_DEVICES = '1'
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 2> '$LogFile'
"@
$start_script | Out-File "$W\start.ps1" -Encoding UTF8 -Force

Write-Host "--- Attempting visible start to debug ---" -ForegroundColor Cyan
# Запускаем в новом окне, чтобы увидеть ошибку, если она будет
Start-Process "powershell.exe" -ArgumentList "-NoExit", "-File", "$W\start.ps1"

Write-Host "If the new window closes instantly, check: $LogFile" -ForegroundColor Yellow
