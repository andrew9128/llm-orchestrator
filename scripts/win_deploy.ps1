$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "--- LLM Orchestrator Windows Deploy v5.2 ---" -ForegroundColor Cyan

# 1. УСТАНОВКА ARIA2
if (!(Get-Command aria2c -ErrorAction SilentlyContinue)) {
    Write-Host "[1/4] Installing aria2 for stable download..." -ForegroundColor Yellow
    winget install -e --id aria2.aria2 --accept-source-agreements --accept-package-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Download-Smart($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { return }
    Write-Host "Downloading $(Split-Path $out -Leaf)..." -ForegroundColor Cyan
    & aria2c.exe -x 16 -s 16 -k 1M --retry-wait 2 --max-tries 10 --console-log-level=error "$url" -d (Split-Path $out) -o (Split-Path $out -Leaf)
}

$W = "$env:USERPROFILE\llm_native"
foreach ($sub in "bin","models") { if (!(Test-Path "$W\$sub")) { New-Item -ItemType Directory -Path "$W\$sub" -Force | Out-Null } }

$gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft|Basic" } | Select-Object -First 1
$vram = if ($gpu) { [math]::Round($gpu.AdapterRAM / 1GB) } else { 0 }
$tag = "b4594"

# 2. ДВИЖОК (CUDA 12.4)
if (!(Test-Path "$W\bin\llama-server.exe")) {
    $bin = "llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    Download-Smart "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin" "$W\llama.zip"
    Expand-Archive "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 3. МОДЕЛЬ SAIGA 8B
$model = "$W\models\saiga.gguf"
Download-Smart "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf" $model

# 4. ОПТИМИЗАЦИЯ ПОД 8GB (RTX 5060)
# Кэш q4_0 экономит 75% памяти кэша. 16к контекста теперь точно влезут.
$kv_type = "fp16"
if ($vram -le 9) { $kv_type = "q4_0" }

$cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$model' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv $kv_type --host 0.0.0.0 --log-disable"
$cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 5. ТИХИЙ АВТОЗАПУСК ЧЕРЕЗ ПЛАНИРОВЩИК
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Server-Native" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "--- READY ---" -ForegroundColor Green
Write-Host "GPU: $($gpu.Name) (${vram}GB)"
Write-Host "API: http://localhost:8010/v1"

# Скрытый запуск сервера
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
