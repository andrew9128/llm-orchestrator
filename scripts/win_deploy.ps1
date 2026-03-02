$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "--- LLM Orchestrator Windows Deploy v5.0 (Blackwell/8GB Optimized) ---" -ForegroundColor Cyan

# 1. УСТАНОВКА МОЩНОГО ЗАГРУЗЧИКА (aria2)
if (!(Get-Command aria2c -ErrorAction SilentlyContinue)) {
    Write-Host "[1/4] Installing aria2 engine via winget..." -ForegroundColor Yellow
    winget install -e --id aria2.aria2 --accept-source-agreements --accept-package-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Download-Smart($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 100MB) { 
        Write-Host "File exists: $(Split-Path $out -Leaf)" -ForegroundColor Gray
        return 
    }
    Write-Host "Downloading: $(Split-Path $out -Leaf) (Multi-threaded)..." -ForegroundColor Cyan
    # Aria2c: 16 потоков, авто-ретри, игнорирование разрывов
    & aria2c.exe -x 16 -s 16 -k 1M --retry-wait 5 --max-tries 20 --console-log-level=error "$url" -d (Split-Path $out) -o (Split-Path $out -Leaf)
    if ($LASTEXITCODE -ne 0) { throw "Download failed even with aria2" }
    Write-Host "OK!" -ForegroundColor Green
}

$W = "$env:USERPROFILE\llm_native"
foreach ($sub in "bin","models") { if (!(Test-Path "$W\$sub")) { New-Item -ItemType Directory -Path "$W\$sub" -Force | Out-Null } }

$gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft|Basic" } | Select-Object -First 1
$vram = if ($gpu) { [math]::Round($gpu.AdapterRAM / 1GB) } else { 0 }
$tag = "b4594"

# 2. ДВИЖОК
if (!(Test-Path "$W\bin\llama-server.exe")) {
    $bin = "llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    Download-Smart "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin" "$W\llama.zip"
    Expand-Archive "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
}

# 3. МОДЕЛЬ SAIGA 8B (Напрямую)
$model = "$W\models\saiga.gguf"
Download-Smart "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf" $model

# 4. ФИКС ОПТИМИЗАЦИИ ПОД 8GB (RTX 5060)
# Чтобы 16к контекста влезли в 8ГБ, сжимаем кеш в 4 раза (q4_0 или fp8)
$kv_type = "fp16"
if ($vram -le 9) { $kv_type = "q4_0" } # Экстремальное сжатие для стабильности

$cmd = "Set-Location '$W\bin'; .\llama-server.exe --model '$model' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv $kv_type --host 0.0.0.0 --log-disable"
$cmd | Out-File "$W\start.ps1" -Encoding UTF8 -Force

# 5. ТИХИЙ АВТОЗАПУСК
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Server-Native" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "`n--- СИСТЕМА ГОТОВА ---" -ForegroundColor Green
Write-Host "GPU : $($gpu.Name) (${vram}GB)"
Write-Host "API : http://localhost:8010/v1"
Write-Host "KV  : $kv_type (MAX Optimization)"

Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
