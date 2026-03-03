# LLM WIN PRUNE - полная очистка всего что установил оркестратор
# Удаляет: сервер, watchdog, модели, dll, engine, все папки llm_native
# Usage: powershell -ExecutionPolicy Bypass -File win_prune.ps1 [-KeepModels]
param(
    [switch]$KeepModels  # -KeepModels: удалить всё кроме .gguf моделей
)

$W = "$env:USERPROFILE\llm_native"

Write-Host ""
Write-Host "============================================" -ForegroundColor Red
Write-Host "   LLM ORCHESTRATOR - FULL PRUNE           " -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red
if ($KeepModels) {
    Write-Host "  Mode: keep models (.gguf files)" -ForegroundColor Yellow
} else {
    Write-Host "  Mode: remove EVERYTHING including models" -ForegroundColor Red
}
Write-Host ""

# =============================================================================
# STEP 1: STOP SERVER + WATCHDOG
# =============================================================================
Write-Host "[1/5] Stopping server and watchdog..." -ForegroundColor Yellow

$killed = 0
Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
    Stop-Process $_ -Force -ErrorAction SilentlyContinue
    Write-Host "  Killed: $($_.Name) (PID $($_.Id))" -ForegroundColor Gray
    $killed++
}
Write-Host "  llama processes stopped: $killed" -ForegroundColor Green

$wdKilled = 0
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -eq "powershell.exe" -and (
        $_.CommandLine -match "watchdog" -or
        $_.CommandLine -match "win_deploy" -or
        $_.CommandLine -match "llm_native"
    )
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  Killed PS: PID $($_.ProcessId)" -ForegroundColor Gray
    $wdKilled++
}
Write-Host "  PS processes stopped: $wdKilled" -ForegroundColor Green
Start-Sleep -s 2

# =============================================================================
# STEP 2: REMOVE llm_native FOLDER
# =============================================================================
Write-Host "[2/5] Removing $W ..." -ForegroundColor Yellow

if (Test-Path $W) {
    if ($KeepModels) {
        # Удаляем всё кроме папки models
        $foldersToRemove = @("bin", "bin_vulkan", "cuda_dlls")
        foreach ($f in $foldersToRemove) {
            $p = "$W\$f"
            if (Test-Path $p) {
                Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue
                Write-Host "  Removed: $p" -ForegroundColor Gray
            }
        }
        # Удаляет файлы в корне (логи, скрипты)
        Get-ChildItem $W -File | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed file: $($_.Name)" -ForegroundColor Gray
        }
        Write-Host "  Kept: $W\models" -ForegroundColor Green
    } else {
        Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
        if (Test-Path $W) {
            Write-Host "  Could not fully remove (files in use?), retrying..." -ForegroundColor Yellow
            Start-Sleep -s 3
            Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
        }
        if (!(Test-Path $W)) {
            Write-Host "  Removed: $W" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: some files could not be removed" -ForegroundColor Yellow
            Get-ChildItem $W -Recurse | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Gray }
        }
    }
} else {
    Write-Host "  Not found: $W (already clean)" -ForegroundColor Gray
}

# =============================================================================
# STEP 3: REMOVE CUDA DLLs pip packages
# =============================================================================
Write-Host "[3/5] Removing CUDA pip packages..." -ForegroundColor Yellow

$pyOk = $false
try { $null = & python --version 2>&1; $pyOk = ($LASTEXITCODE -eq 0) } catch {}

if ($pyOk) {
    $pkgs = @("nvidia-cuda-runtime-cu12", "nvidia-cublas-cu12", "nvidia-cuda-nvrtc-cu12", "huggingface-hub")
    foreach ($pkg in $pkgs) {
        & python -m pip uninstall -y $pkg 2>&1 | Out-Null
        Write-Host "  Uninstalled: $pkg" -ForegroundColor Gray
    }
    Write-Host "  pip packages removed" -ForegroundColor Green
} else {
    Write-Host "  Python not found, skipping pip cleanup" -ForegroundColor Gray
}

# =============================================================================
# STEP 4: REMOVE TEMP FILES
# =============================================================================
Write-Host "[4/5] Removing temp deploy files..." -ForegroundColor Yellow

$tempFiles = @(
    "$env:TEMP\s.ps1",
    "$env:TEMP\stop.ps1",
    "$env:TEMP\deploy.ps1",
    "$env:TEMP\status.ps1"
)
foreach ($f in $tempFiles) {
    if (Test-Path $f) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $f" -ForegroundColor Gray
    }
}
Write-Host "  Temp files cleaned" -ForegroundColor Green

# =============================================================================
# STEP 5: SUMMARY
# =============================================================================
Write-Host "[5/5] Summary" -ForegroundColor Yellow
Write-Host ""

$remaining = @()
if (Test-Path $W)                { $remaining += $W }
if (Test-Path "$W\models")       { $remaining += "$W\models (models kept)" }

if ($remaining.Count -eq 0) {
    Write-Host "  All LLM orchestrator files removed." -ForegroundColor Green
} else {
    Write-Host "  Remaining:" -ForegroundColor Yellow
    foreach ($r in $remaining) { Write-Host "    $r" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "  NOT removed (system-wide installs):" -ForegroundColor Gray
Write-Host "    - Python 3.12 (winget)" -ForegroundColor Gray
Write-Host "    - Visual C++ Runtime (winget)" -ForegroundColor Gray
Write-Host "  To remove those: winget uninstall Python.Python.3.12" -ForegroundColor Gray
Write-Host ""
Write-Host "Prune complete." -ForegroundColor Green
