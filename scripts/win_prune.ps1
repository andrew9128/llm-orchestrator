# LLM WIN PRUNE v15.0
# Kills everything started by the orchestrator, removes all files.
# Usage:
#   win_prune.ps1              -- remove everything including models
#   win_prune.ps1 -KeepModels  -- keep .gguf and ONNX model files
param([switch]$KeepModels)

$W = "$env:USERPROFILE\llm_native"

Write-Host ""
Write-Host "============================================" -ForegroundColor Red
Write-Host "   LLM ORCHESTRATOR - FULL PRUNE v15.0     " -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red
if ($KeepModels) {
    Write-Host "  Mode: keep models" -ForegroundColor Yellow
} else {
    Write-Host "  Mode: remove EVERYTHING" -ForegroundColor Red
}
Write-Host ""

# =============================================================================
# [1] Kill all processes
# =============================================================================
Write-Host "[1/5] Killing all services..." -ForegroundColor Yellow

# llama-server
Get-Process | Where-Object { $_.Name -match "llama|whisper" } | ForEach-Object {
    Stop-Process $_ -Force -EA SilentlyContinue
    Write-Host "  Killed: $($_.Name) (PID $($_.Id))" -ForegroundColor Gray
}

# Python services (asr, ocr, embed, proxy)
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -match "python" -and $_.CommandLine -match "asr_service|ocr_service|embed_service|proxy_service"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
    Write-Host "  Killed Python: PID $($_.ProcessId)" -ForegroundColor Gray
}

# PowerShell services (watchdog, deploy)
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -eq "powershell.exe" -and (
        $_.CommandLine -match "watchdog|llm_native|win_deploy|asr_run"
    )
} | ForEach-Object {
    if ($_.ProcessId -ne $PID) {
        Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
        Write-Host "  Killed PS: PID $($_.ProcessId)" -ForegroundColor Gray
    }
}

# Kill anything holding ports 8010-8014, 18011-18014
foreach ($port in 8010, 8011, 8012, 8013, 8014, 18011, 18013, 18014) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -EA SilentlyContinue | Where-Object State -eq "Listen" | Select-Object -First 1
        if ($conn -and $conn.OwningProcess -gt 4) {
            $proc = Get-Process -Id $conn.OwningProcess -EA SilentlyContinue
            if ($proc) {
                Stop-Process -Id $conn.OwningProcess -Force -EA SilentlyContinue
                Write-Host "  Freed port $port ($($proc.Name) PID $($conn.OwningProcess))" -ForegroundColor Gray
            }
        }
    } catch {}
}

Start-Sleep -s 2
Write-Host "  All processes stopped" -ForegroundColor Green

# =============================================================================
# [2] Remove llm_native folder
# =============================================================================
Write-Host "[2/5] Removing $W..." -ForegroundColor Yellow

if (Test-Path $W) {
    if ($KeepModels) {
        # Remove everything except models folder
        Get-ChildItem $W -File | ForEach-Object {
            Remove-Item $_.FullName -Force -EA SilentlyContinue
            Write-Host "  Removed: $($_.Name)" -ForegroundColor Gray
        }
        foreach ($dir in @("bin", "bin_vulkan", "cuda_dlls", "whisper")) {
            $p = "$W\$dir"
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -EA SilentlyContinue; Write-Host "  Removed: $dir" -ForegroundColor Gray }
        }
        Write-Host "  Kept: $W\models" -ForegroundColor Green
    } else {
        Remove-Item $W -Recurse -Force -EA SilentlyContinue
        Start-Sleep -s 1
        if (Test-Path $W) {
            # Force remove locked files
            Get-ChildItem $W -Recurse -File | ForEach-Object {
                Remove-Item $_.FullName -Force -EA SilentlyContinue
            }
            Remove-Item $W -Recurse -Force -EA SilentlyContinue
        }
        if (Test-Path $W) {
            Write-Host "  WARNING: some files locked, manual cleanup needed:" -ForegroundColor Yellow
            Get-ChildItem $W -Recurse | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Gray }
        } else {
            Write-Host "  Removed: $W" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  Not found (already clean)" -ForegroundColor Gray
}

# =============================================================================
# [3] Remove ONNX pip packages
# =============================================================================
Write-Host "[3/5] Removing pip packages..." -ForegroundColor Yellow

$pyOk = $false
try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}

if ($pyOk) {
    $pkgs = @(
        "nvidia-cuda-runtime-cu12", "nvidia-cublas-cu12", "nvidia-cuda-nvrtc-cu12",
        "onnxruntime-gpu", "onnxruntime",
        "onnx-asr",
        "rapidocr", "rapidocr-onnxruntime",
        "sentence-transformers", "optimum",
        "gigaam"
    )
    foreach ($pkg in $pkgs) {
        $installed = & python -m pip show $pkg 2>$null
        if ($installed) {
            & python -m pip uninstall -y $pkg 2>&1 | Out-Null
            Write-Host "  Uninstalled: $pkg" -ForegroundColor Gray
        }
    }
    Write-Host "  pip packages removed" -ForegroundColor Green
} else {
    Write-Host "  Python not found, skipping pip" -ForegroundColor Gray
}

# =============================================================================
# [4] Remove HuggingFace model cache (ONNX models)
# =============================================================================
Write-Host "[4/5] Removing HuggingFace model cache..." -ForegroundColor Yellow

if (-not $KeepModels) {
    $hfCacheDirs = @(
        "$env:USERPROFILE\.cache\huggingface\hub\models--istupakov--gigaam-v3-onnx",
        "$env:USERPROFILE\.cache\huggingface\hub\models--BAAI--bge-m3",
        "$env:USERPROFILE\.cache\huggingface\hub\models--vikp--surya_det3",
        "$env:USERPROFILE\.cache\huggingface\hub\models--vikp--surya_rec2",
        "$env:USERPROFILE\.cache\onnx_asr"
    )
    foreach ($d in $hfCacheDirs) {
        if (Test-Path $d) {
            Remove-Item $d -Recurse -Force -EA SilentlyContinue
            Write-Host "  Removed cache: $(Split-Path $d -Leaf)" -ForegroundColor Gray
        }
    }
    Write-Host "  HF cache cleaned" -ForegroundColor Green
} else {
    Write-Host "  Skipped (KeepModels)" -ForegroundColor Gray
}

# =============================================================================
# [5] Remove temp files
# =============================================================================
Write-Host "[5/5] Removing temp files..." -ForegroundColor Yellow

Get-ChildItem $env:TEMP -Filter "*.ps1" -EA SilentlyContinue | Where-Object { $_.Length -lt 500KB } | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -EA SilentlyContinue
    if ($content -match "llm_native|win_deploy|watchdog|llama") {
        Remove-Item $_.FullName -Force -EA SilentlyContinue
        Write-Host "  Removed temp: $($_.Name)" -ForegroundColor Gray
    }
}
Write-Host "  Temp files cleaned" -ForegroundColor Green

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "Prune complete." -ForegroundColor Green
if ($KeepModels -and (Test-Path "$W\models")) {
    $modelSize = (Get-ChildItem "$W\models" -Recurse -File -EA SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    Write-Host "  Models kept: $W\models ($([math]::Round($modelSize/1GB,1)) GB)" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  NOT removed (system installs):" -ForegroundColor Gray
Write-Host "    Python 3.12 -- winget uninstall Python.Python.3.12" -ForegroundColor Gray
Write-Host "    Visual C++ -- winget uninstall Microsoft.VCRedist.2015+.x64" -ForegroundColor Gray
Write-Host ""
