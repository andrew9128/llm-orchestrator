$ErrorActionPreference = 'Stop'
$W = "$env:USERPROFILE\llm_native"
$LogFile = "$W\server_debug.log"

# 1. ЗАЧИСТКА
Stop-Process -Name "llama-server*" -ErrorAction SilentlyContinue

# 2. УСТАНОВКА КРИТИЧЕСКИХ КОМПОНЕНТОВ MICROSOFT
# Без этого C++ программы (как llama.cpp) падают молча
if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64")) {
    Write-Host "[!] Visual C++ Redistributable not found. Installing..." -ForegroundColor Yellow
    winget install -e --id Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements | Out-Null
}

# 3. ПРОВЕРКА DLL В ПАПКЕ
$RequiredDLLs = @("cudart64_12.dll", "cublas64_12.dll")
foreach ($dll in $RequiredDLLs) {
    if (!(Test-Path "$W\bin\$dll")) {
        Write-Host "[!] Missing $dll in bin folder. Re-downloading engine..." -ForegroundColor Red
        Remove-Item -Recurse -Force "$W\bin" -ErrorAction SilentlyContinue
    }
}

# 4. ПОВТОРНАЯ ЗАГРУЗКА (если папка была битая)
if (!(Test-Path "$W\bin\llama-server.exe")) {
    Write-Host "[+] Downloading Engine..." -ForegroundColor Cyan
    $tag = "b4594"
    $url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    $zip = "$W\llama.zip"
    curl.exe -L "$url" -o "$zip"
    Expand-Archive -Path "$zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$zip"
}

# 5. СОЗДАНИЕ СКРИПТА ЗАПУСКА
$ModelPath = "$W\models\saiga.gguf"
$start_script = @"
Set-Location '$W\bin'
# Принудительно выбираем GPU 1 (RTX 5060)
`$env:CUDA_VISIBLE_DEVICES = '1'
# Запуск с записью ВСЕГО вывода в лог
.\llama-server.exe --model '$ModelPath' --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --host 0.0.0.0 > '$LogFile' 2>&1
"@
$start_script | Out-File "$W\start.ps1" -Encoding UTF8 -Force

Write-Host "--- Starting Server ---" -ForegroundColor Green
# Запускаем скрыто
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\start.ps1"

Write-Host "Wait 30s and check API. Log: $LogFile" -ForegroundColor Gray
