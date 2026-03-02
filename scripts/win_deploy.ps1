$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function DL($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { 
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return 
    }
    Write-Host "Downloading: $(Split-Path $out -Leaf)..." -ForegroundColor Cyan
    try {
        # Используем WebClient — самый стабильный метод для блокирующего скачивания в PS 5.1
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $out)
        Write-Host "OK!" -ForegroundColor Green
    } catch {
        Write-Host "Primary download failed, trying fallback (curl)..." -ForegroundColor Yellow
        & curl.exe -L -f $url -o $out
    }
}

$W = "$env:USERPROFILE\llm_native"
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

$gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft|Basic" } | Select-Object -First 1
$vram = if ($gpu) { [math]::Round($gpu.AdapterRAM / 1GB) } else { 0 }
$tag = "b4594"

# Настройка под 8GB (RTX 5060)
$ngl = 99
$kv_type = "fp16"
if ($vram -le 8) { $kv_type = "fp8_e5m2" }

# 1. Движок
if (!(Test-Path "$W\bin\llama-server.exe")) {
    $bin = "llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    DL "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin" "$W\llama.zip"
    Expand-Archive "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 2. Модель Saiga 8B
$model = "$W\models\saiga.gguf"
DL "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf" $model

# 3. Старт-файл
$cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$model' --port 8010 --n-gpu-layers $ngl --ctx-size 16384 --cache-type-kv $kv_type --host 0.0.0.0 --log-disable"
$cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 4. Регистрация задачи
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Server" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- СТАТУС ---" -ForegroundColor Green
Write-Host "GPU   : $($gpu.Name) (${vram}GB)"
Write-Host "API   : http://localhost:8010/v1"
Write-Host "DONE. Server will start in background."

Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
