$ErrorActionPreference = 'SilentlyContinue'
$W = "$env:USERPROFILE\llm_native"

Write-Host "--- LLM ORCHESTRATOR: TOTAL WIPE ---" -ForegroundColor Red -BackgroundColor Black

# 1. Вызов стоп-скрипта (если он существует)
if (Test-Path "$W\scripts\win_stop.ps1") {
    Write-Host "Running win_stop.ps1..." -ForegroundColor Gray
    powershell -ExecutionPolicy Bypass -File "$W\scripts\win_stop.ps1"
}

# 2. Агрессивное убийство всех процессов на GPU (чтобы освободить память)
Write-Host "[1/4] Force-killing GPU processes to free memory..." -ForegroundColor Yellow
$gpu_pids = nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>$null
foreach ($line in $gpu_pids) {
    $clean_pid = $line.Trim()
    if ($clean_pid -match '^\d+$') {
        Write-Host "  Killing PID $clean_pid..." -ForegroundColor Gray
        taskkill /F /PID $clean_pid /T 2>$null
    }
}

# Дополнительно добиваем по именам
taskkill /F /IM "llama-server.exe" /T 2>$null
taskkill /F /IM "python.exe" /T 2>$null

# 3. Удаление задач из Планировщика
Write-Host "[2/4] Removing scheduled tasks..." -ForegroundColor Yellow
$Tasks = @("LLM-Native-Server", "LLM-Server", "LLM-Native-API", "LLM-Watchdog", "LLM-Server-Native")
foreach ($t in $Tasks) {
    & schtasks.exe /Delete /TN "$t" /F 2>$null
}

# 4. Полное удаление папки llm_native
if (Test-Path $W) {
    Write-Host "[3/4] Deleting directory: $W..." -ForegroundColor Red
    # Даем системе 3 секунды, чтобы отпустить заблокированные файлы
    Start-Sleep -s 3
    
    # Снимаем все блокировки и атрибуты
    attrib -r -s -h "$W\*.*" /s /d 2>$null
    
    # Самый мощный способ удаления папки в Windows - через CMD
    cmd.exe /c "rd /s /q `"$W`""
    
    if (Test-Path $W) {
        Write-Host "  Retry deleting folder..." -ForegroundColor Gray
        Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    }
}

# 5. Чистка временных файлов
Write-Host "[4/4] Cleaning temp scripts..." -ForegroundColor Yellow
Get-ChildItem "$env:TEMP\*.ps1" | Where-Object { $_.Name -match "prune|deploy|ask|chat|s\.ps1|d\.ps1" } | Remove-Item -Force

Write-Host "`n--- SYSTEM CLEANED ---" -ForegroundColor Green
Write-Host "Verify with 'nvidia-smi' - memory should be 0."
