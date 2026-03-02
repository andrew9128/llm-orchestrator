$ErrorActionPreference = 'Stop' # Теперь мы будем видеть ошибки
$ProgressPreference = 'Continue' # Вернем прогресс-бар для наглядности
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "--- Smart LLM Orchestrator v7.3 (FORCE UPDATE) ---" -ForegroundColor Cyan

# 1. ПАПКИ
$W = "$env:USERPROFILE\llm_native"
if (!(Test-Path "$W\bin")) { New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null }
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 2. ФУНКЦИЯ ЗАГРУЗКИ (с проверкой)
function Download-Safe($url, $out, $minSize) {
    if ((Test-Path $out) -and ((Get-Item $out).Length -gt $minSize)) {
        Write-Host "Found existing file: $(Split-Path $out -Leaf). Skipping download." -ForegroundColor Gray
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf)... This may take time." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $out -Priority High
}

# 3. ДВИЖОК
$tag = "b4594"
$bin_url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
Download-Safe $bin_url "$W\llama.zip" 10MB
Write-Host "Unpacking engine..." -ForegroundColor Gray
Expand-Archive -Path "$W\llama.zip" -DestinationPath "$W\bin" -Force

# 4. МОДЕЛЬ (Проверка на 5ГБ+)
Download-Safe "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" "$W\models\saiga.gguf" 4000MB

# 5. КОМАНДА ЗАПУСКА (GPU 1 - RTX 5060)
$ModelPath = "$W\models\saiga.gguf"
$LogFile = "$W\server.log"
$start_cmd = @"
Set-Location '$W\bin'
`$env:PATH = '$W\bin;' + `$env:PATH
`$env:CUDA_VISIBLE_DEVICES = '1'
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 8192 --cache-type-kv q4_0 --host 0.0.0.0 --log-disable > '$LogFile' 2>&1
"@
$start_cmd | Out-File "$W\start.ps1" -Encoding ASCII -Force

# 6. ЗАПУСК
Write-Host "Starting server on GPU 1..." -ForegroundColor Green
Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"

Start-Sleep -Seconds 5
if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "SUCCESS: API is live at http://localhost:8010/v1" -ForegroundColor Green
} else {
    Write-Host "ERROR: Server died. Showing last log lines:" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 10 }
}
