$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function DL($url, $out) {
    Write-Host "Downloading: $(Split-Path $out -Leaf)"
    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0")
    $client.Timeout = [System.TimeSpan]::FromHours(2)
    $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $resp.EnsureSuccessStatusCode() | Out-Null
    $src = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $dst = [System.IO.File]::Create($out)
    $src.CopyTo($dst)
    $dst.Close(); $src.Close(); $client.Dispose()
    if ((Get-Item $out).Length -lt 1MB) { throw "FAILED: $url" }
    Write-Host "OK"
}

$W = "$env:USERPROFILE\llm_native"
New-Item -ItemType Directory -Path "$W\bin"    -Force | Out-Null
New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null

$gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft|Basic" } | Select-Object -First 1
$gpuName = if ($gpu) { $gpu.Name } else { "CPU" }
$ngl = 0; $tag = "b4594"

if ($gpuName -match "NVIDIA") {
    $ngl = 99
    $drv = [int]($gpu.DriverVersion -replace '.*\.(\d+)$','$1')
    $bin = if ($drv -ge 52500) { "llama-$tag-bin-win-cuda-cu12.4-x64.zip" } else { "llama-$tag-bin-win-cuda-cu11.7.1-x64.zip" }
} elseif ($gpuName -match "AMD|Radeon") {
    $ngl = 99; $bin = "llama-$tag-bin-win-vulkan-x64.zip"
} elseif ($gpuName -match "Intel|Arc") {
    $ngl = 99; $bin = "llama-$tag-bin-win-vulkan-x64.zip"
} else {
    $bin = "llama-$tag-bin-win-avx2-x64.zip"
}

Write-Host "=== GPU: $gpuName | Package: $bin ==="

if (!(Test-Path "$W\bin\llama-server.exe")) {
    DL "https://github.com/ggerganov/llama.cpp/releases/download/$tag/$bin" "$W\llama.zip"
    Expand-Archive "$W\llama.zip" -DestinationPath "$W\bin" -Force
    Remove-Item "$W\llama.zip" -Force
} else { Write-Host "Engine: exists, skip" }

$model = "$W\models\saiga.gguf"
if (!(Test-Path $model) -or (Get-Item $model -ErrorAction SilentlyContinue).Length -lt 100MB) {
    DL "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_k.gguf" $model
} else { Write-Host "Model: exists, skip" }

"Set-Location '$W\bin'; .\llama-server.exe --model '$model' --port 8010 --n-gpu-layers $ngl --ctx-size 16384 --host 0.0.0.0 --log-disable" | Out-File "$W\start.ps1" -Encoding UTF8

$a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`""
$t = New-ScheduledTaskTrigger -AtStartup
$s = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "LLM-Native-Server" -Action $a -Trigger $t -Settings $s -RunLevel Highest -Force | Out-Null

Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$W\start.ps1`"" -WindowStyle Hidden
Write-Host "=== DONE | API: http://localhost:8010/v1 ==="
