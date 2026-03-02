$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- Smart LLM Orchestrator v6.1 (Blackwell/8GB Fix) ---" -ForegroundColor Cyan

# 1. ЗАЧИСТКА
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 2. ФУНКЦИЯ ЗАГРУЗКИ ЧЕРЕЗ BITS
function Download-File-Bits($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) {
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High -DisplayName "LLM_Download"
}

# 3. ДВИЖОК (CUDA 12.4 для 50-й серии)
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
Download-File-Bits $bin_url "$W\llama.zip"
if (Test-Path "$W\llama.zip") {
    Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 4. МОДЕЛЬ (SAIGA LLAMA 3 8B)
$model_url = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf"
Download-File-Bits $model_url "$W\models\saiga.gguf"

# 5. ОПТИМИЗАЦИЯ ПОД 8GB VRAM (RTX 5060)
# --cache-type-kv q4_0 сжимает кэш в 4 раза. Это позволит 16к контекста занять всего 550МБ.
# Итого модель (4.8ГБ) + Кэш (0.6ГБ) + Система (1.5ГБ) = ~7ГБ. ВЛЕЗАЕТ!
$start_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$W\models\saiga.gguf' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable"
$start_cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 6. АВТОЗАПУСК (Скрытая задача)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Native-API" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- СИСТЕМА ГОТОВА ---" -ForegroundColor Green
Write-Host "API: http://localhost:8010/v1"
Write-Host "Модель запущена в фоне. Проверьте через 2-3 минуты."

# Запуск прямо сейчас
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
