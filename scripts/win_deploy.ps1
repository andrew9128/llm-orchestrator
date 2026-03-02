$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir = "$env:USERPROFILE\llm_native"
New-Item -ItemType Directory -Path "$WorkDir\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$WorkDir\models" -Force | Out-Null

# ── ДЕТЕКТ GPU ────────────────────────────────────────────────
$gpu     = Get-WmiObject Win32_VideoController |
           Where-Object { $_.Name -notmatch "Microsoft|Basic" } |
           Select-Object -First 1
$gpuName = if ($gpu) { $gpu.Name } else { "CPU" }

# Версия драйвера → выбор CUDA 11 или 12
$ngl = 0
$tag = "b4594"
if ($gpuName -match "NVIDIA") {
    $ngl = 99
    $drv = [int]($gpu.DriverVersion -replace '.*\.(\d+)$','$1')
    if ($drv -ge 52500) {
        $bin = "llama-$tag-bin-win-cuda-cu12.4-x64.zip"
    } else {
        $bin = "llama-$tag-bin-win-cuda-cu11.7.1-x64.zip"
    }
} elseif ($gpuName -match "AMD|Radeon|RX ") {
    $ngl = 99
    $bin = "llama-$tag-bin-win-vulkan-x64.zip"
} elseif ($gpuName -match "Intel|Arc") {
    $ngl = 99
    $bin = "llama-$tag-bin-win-vulkan-x64.zip"
} else {
    $bin = "llama-$tag-bin-win-avx2-x64.zip"
}

# ── ДВИЖОК ───────────────────────────────────────────────────
if (!(Test-Path "$WorkDir\bin\llama-server.exe")) {
    $url = "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin"
    & curl.exe -fsSL $url -o "$WorkDir\llama.zip"
    Expand-Archive "$WorkDir\llama.zip" -DestinationPath "$WorkDir\bin" -Force
    Remove-Item "$WorkDir\llama.zip" -Force
}

# ── МОДЕЛЬ ────────────────────────────────────────────────────
$model = "$WorkDir\models\saiga.gguf"
if (!(Test-Path $model)) {
    $murl = "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf"
    & curl.exe -fL $murl -o $model
}

# ── СКРИПТ ЗАПУСКА ────────────────────────────────────────────
$run = @"
Set-Location '$WorkDir\bin'
.\llama-server.exe ``
    --model '$model' ``
    --port 8010 ``
    --n-gpu-layers $ngl ``
    --ctx-size 16384 ``
    --host 0.0.0.0 ``
    --log-disable
"@
$run | Out-File "$WorkDir\start.ps1" -Encoding UTF8

# ── АВТОЗАПУСК (Task Scheduler) ───────────────────────────────
$action   = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkDir\start.ps1`""
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit 0
Register-ScheduledTask `
    -TaskName "LLM-Native-Server" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force | Out-Null

# ── СТАРТ ПРЯМО СЕЙЧАС ────────────────────────────────────────
Start-Process "powershell.exe" `
    -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkDir\start.ps1`"" `
    -WindowStyle Hidden

Write-Host "GPU   : $gpuName (layers=$ngl)"
Write-Host "API   : http://localhost:8010/v1"
Write-Host "DONE. Server runs silently. Auto-starts on reboot."
