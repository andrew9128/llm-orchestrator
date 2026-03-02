$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ВЕРСИЯ 4.0 - TOTAL RELIABILITY
Write-Host "--- LLM Orchestrator Windows Deploy v4.0 ---" -ForegroundColor Cyan

function Download-File-Robust($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { 
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return 
    }
    Write-Host "Downloading: $(Split-Path $out -Leaf)..." -ForegroundColor Cyan
    
    # Пытаемся использовать BITS (самый стабильный метод в Windows)
    try {
        Import-Module BitsTransfer
        Start-BitsTransfer -Source $url -Destination $out -Priority High -Description "LLM-Deploy"
        Write-Host "OK (BITS)" -ForegroundColor Green
    } catch {
        # Если BITS не помог, используем curl.exe напрямую
        Write-Host "BITS failed, using curl.exe..." -ForegroundColor Yellow
        & curl.exe -L -k --retry 5 --retry-delay 5 "$url" -o "$out"
        if ($LASTEXITCODE -ne 0) { throw "All download methods failed for $url" }
        Write-Host "OK (CURL)" -ForegroundColor Green
    }
}

$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

$gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft|Basic" } | Select-Object -First 1
$vram = if ($gpu) { [math]::Round($gpu.AdapterRAM / 1GB) } else { 0 }
$tag = "b4594"

# 1. Загрузка движка (CUDA 12.4)
if (!(Test-Path "$W\bin\llama-server.exe")) {
    $bin = "llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    Download-File-Robust "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin" "$W\llama.zip"
    Expand-Archive "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 2. Загрузка модели Saiga 8B
$model = "$W\models\saiga.gguf"
Download-File-Robust "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf" $model

# 3. Настройка под RTX 5060 (8GB)
# Для 8ГБ карты 16к контекста влезут ТОЛЬКО с fp8 сжатием кэша.
$kv_type = "fp16"
if ($vram -le 9) { $kv_type = "fp8_e5m2" }

$cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$model' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv $kv_type --host 0.0.0.0 --log-disable"
$cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 4. Автозапуск (Task Scheduler)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Server-Native" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- СИСТЕМА ГОТОВА ---" -ForegroundColor Green
Write-Host "GPU: $($gpu.Name) ($vram GB)"
Write-Host "API: http://localhost:8010/v1"
Write-Host "Кэш: $kv_type (сжат для 8ГБ VRAM)"

# Запуск в невидимом режиме
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
