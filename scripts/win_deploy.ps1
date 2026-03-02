# Фикс TLS и ошибок рукопожатия
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

Write-Host "--- Smart LLM Orchestrator v6.0 (Blackwell/8GB Fix) ---" -ForegroundColor Cyan

# 1. ЗАЧИСТКА
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force }

# 2. ФУНКЦИЯ ЗАГРУЗКИ ЧЕРЕЗ BITS (Самый надежный метод в Windows)
function Download-File-Bits($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) {
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    # BITS не падает при обрывах рукопожатия и умеет докачивать
    Start-BitsTransfer -Source $url -Destination $out -Priority High -DisplayName "LLM_Download"
}

# 3. ДВИЖОК (CUDA 12.4)
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
# Чтобы 16к контекста влезли в 8ГБ, используем --cache-type-kv q4_0
# Это сжимает кэш в 4 раза (с 2.2ГБ до 550МБ). Теперь всё влезет в память карты.
$start_cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$W\models\saiga.gguf' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable"
$start_cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 6. АВТОЗАПУСК (Скрытый)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Native-API" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- УСТАНОВКА ЗАВЕРШЕНА ---" -ForegroundColor Green
Write-Host "GPU: NVIDIA RTX 5060 8GB (Optimized)"
Write-Host "API: http://localhost:8010/v1"
Write-Host "Модель запущена скрыто в фоне."

# Запуск прямо сейчас
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
