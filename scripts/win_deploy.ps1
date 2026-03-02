$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "--- LLM AUTO-DEPLOY v11.4 (Full CUDA DLLs) ---" -ForegroundColor Cyan

Stop-Process -Name "llama-server*" -Force -ErrorAction SilentlyContinue
$W = "$env:USERPROFILE\llm_native"
if (Test-Path "$W\bin") { Remove-Item -Recurse -Force "$W\bin" }
New-Item -ItemType Directory -Path "$W\bin" -Force | Out-Null
if (!(Test-Path "$W\models")) { New-Item -ItemType Directory -Path "$W\models" -Force | Out-Null }

# 1. VCRedist
Write-Host "[1/6] Visual C++ Runtime..." -ForegroundColor Yellow
& winget install -e --id Microsoft.VCRedist.2015+.x64 --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null

# 2. Все CUDA DLLs через NuGet (только runtime-пакеты, ~200MB суммарно)
Write-Host "[2/6] Downloading CUDA runtime DLLs via NuGet..." -ForegroundColor Yellow
$cudaVer = "12.4.0"
$dllDest = "$W\bin"
$pkgDir  = "$W\cuda_pkgs"
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

# Все пакеты нужные для llama.cpp CUDA build
$nugetPkgs = @(
    "CUDA.Runtime.Redist",       # cudart64_12.dll
    "CUDA.CUBLAS.Redist",        # cublas64_12.dll + cublasLt64_12.dll
    "CUDA.NVTX.Redist",          # nvToolsExt64_1.dll  
    "CUDA.cudart"                # ещё один вариант cudart
)

$totalDlls = 0
foreach ($pkg in $nugetPkgs) {
    $url = "https://www.nuget.org/api/v2/package/$pkg/$cudaVer"
    $zip = "$pkgDir\$pkg.zip"
    Write-Host "  Fetching $pkg ..." -ForegroundColor Gray
    try {
        curl.exe -L $url -o $zip --silent --max-time 60
        if ((Get-Item $zip -ErrorAction SilentlyContinue).Length -gt 10000) {
            Expand-Archive $zip "$pkgDir\$pkg" -Force
            $dlls = Get-ChildItem "$pkgDir\$pkg" -Recurse -Filter "*.dll" | Where-Object { $_.Name -match "cuda|cublas|nvtx|nv" }
            foreach ($dll in $dlls) {
                Copy-Item $dll.FullName $dllDest -Force
                Write-Host "    + $($dll.Name)" -ForegroundColor Green
                $totalDlls++
            }
        } else {
            Write-Host "    (package not found for v$cudaVer, skipping)" -ForegroundColor Gray
        }
    } catch { Write-Host "    Error: $_" -ForegroundColor Yellow }
}
Write-Host "  Total DLLs installed: $totalDlls" -ForegroundColor Green

# 3. Скачиваем CUDA билд llama.cpp
$tag = "b5248"
Write-Host "[3/6] Downloading CUDA 12.4 Engine..." -ForegroundColor Yellow
curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-cuda-cu12.4-x64.zip" -o "$W\engine.zip"
Expand-Archive -Path "$W\engine.zip" -DestinationPath "$W\bin" -Force
Remove-Item "$W\engine.zip"

$exePath = Get-ChildItem "$W\bin" -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
$binDir  = Split-Path $exePath -Parent

# Копируем все DLL из bin в папку где лежит exe (на случай подпапки)
Get-ChildItem "$W\bin" -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.FullName -ne "$binDir\$($_.Name)") { Copy-Item $_.FullName $binDir -Force }
}
Write-Host "  exe: $exePath" -ForegroundColor Green

# 4. Тест
Write-Host "[4/6] Testing CUDA build..." -ForegroundColor Yellow
$p = Start-Process $exePath -ArgumentList "--version" -PassThru -Wait -NoNewWindow `
     -RedirectStandardOutput "$W\ver_out.txt" -RedirectStandardError "$W\ver_err.txt"
$out = (Get-Content "$W\ver_out.txt" -ErrorAction SilentlyContinue) -join " "
$err = (Get-Content "$W\ver_err.txt" -ErrorAction SilentlyContinue) -join " "
Write-Host "  Exit=$($p.ExitCode) out=$out err=$($err | Select-Object -First 100)" -ForegroundColor Gray

if ($p.ExitCode -ne 0) {
    Write-Host "  CUDA still failing, falling back to Vulkan..." -ForegroundColor Red
    $vulkanDir = "$W\bin_vulkan"
    New-Item -ItemType Directory -Path $vulkanDir -Force | Out-Null
    curl.exe -L "https://github.com/ggerganov/llama.cpp/releases/download/$tag/llama-$tag-bin-win-vulkan-x64.zip" -o "$W\vk.zip"
    Expand-Archive "$W\vk.zip" $vulkanDir -Force; Remove-Item "$W\vk.zip"
    $exePath = Get-ChildItem $vulkanDir -Recurse -Filter "llama-server.exe" | Select-Object -First 1 -ExpandProperty FullName
    $binDir  = Split-Path $exePath -Parent
    Write-Host "  Using Vulkan: $exePath" -ForegroundColor Yellow
}

# 5. list-devices
Write-Host "[5/6] Listing devices..." -ForegroundColor Yellow
$deviceArg = ""
Start-Process $exePath -ArgumentList "--list-devices" -Wait -NoNewWindow `
    -RedirectStandardOutput "$W\dev_out.txt" -RedirectStandardError "$W\dev_err.txt" -ErrorAction SilentlyContinue
$devLines = @()
if (Test-Path "$W\dev_out.txt") { $devLines += Get-Content "$W\dev_out.txt" }
if (Test-Path "$W\dev_err.txt") { $devLines += Get-Content "$W\dev_err.txt" }
$devLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
$line = $devLines | Where-Object { $_ -match "5060" } | Select-Object -First 1
if ($line -match "([A-Za-z]+\d+)\s*[=:]") { $deviceArg = "--device $($Matches[1])"; Write-Host "  -> $deviceArg" -ForegroundColor Green }

# 6. Модель
$m = "$W\models\saiga.gguf"
if (!(Test-Path $m) -or (Get-Item $m).Length -lt 4GB) {
    Write-Host "[6/6] Downloading model..." -ForegroundColor Yellow
    Import-Module BitsTransfer
    Start-BitsTransfer -Source "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -Destination $m -Priority High
} else { Write-Host "[6/6] Model exists." -ForegroundColor Green }

# Запуск
$cmd = "Set-Location '$binDir'; .\llama-server.exe --model '$m' --port 8010 --n-gpu-layers 99 --ctx-size 8192 --host 0.0.0.0 $deviceArg > '$W\server.log' 2>&1"
Write-Host "CMD: $cmd" -ForegroundColor Gray
[System.IO.File]::WriteAllText("$W\run.ps1", $cmd, [System.Text.UTF8Encoding]::new($false))
Start-Process "powershell.exe" -ArgumentList "-WindowStyle Hidden", "-File", "$W\run.ps1"
Start-Sleep -s 15

if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    Write-Host "--- SUCCESS! API: http://localhost:8010/v1 ---" -ForegroundColor Green
} else {
    Write-Host "ERROR:" -ForegroundColor Red
    if (Test-Path "$W\server.log") { Get-Content "$W\server.log" -Tail 30 }
    else {
        Write-Host "(нет лога - запускаем напрямую для диагностики)" -ForegroundColor Yellow
        Start-Process $exePath -ArgumentList "--model `"$m`" --n-gpu-layers 1 --port 8010" `
            -Wait -NoNewWindow -RedirectStandardError "$W\direct_err.txt"
        if (Test-Path "$W\direct_err.txt") { Get-Content "$W\direct_err.txt" | Select-Object -First 30 }
    }
}
