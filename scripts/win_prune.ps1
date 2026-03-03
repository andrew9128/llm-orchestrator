$ErrorActionPreference = 'SilentlyContinue'
Write-Host "--- LLM ORCHESTRATOR: TOTAL SYSTEM WIPE ---" -ForegroundColor Red -BackgroundColor Black

# 1. СТОП ВСЕХ ПРОЦЕССОВ, ДЕРЖАЩИХ GPU (Самое важное для очистки памяти)
Write-Host "[1/5] Force killing all processes using GPU..." -ForegroundColor Yellow
$gpu_pids = nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>$null | ForEach-Object { $_.Trim() }

foreach ($pid in $gpu_pids) {
    if ($pid -match '^\d+$') {
        Write-Host "  Terminating PID $pid..." -ForegroundColor Gray
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    }
}

# 2. ДОПОЛНИТЕЛЬНАЯ ЗАЧИСТКА ПО ИМЕНАМ (на всякий случай)
$TargetNames = @("llama-server", "python", "vllm", "sglang", "lmdeploy", "uvicorn", "api_server")
foreach ($n in $TargetNames) {
    Get-Process | Where-Object { $_.Name -match $n } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# 3. ЧИСТКА ПЛАНИРОВЩИКА ЗАДАЧ
Write-Host "[2/5] Removing all LLM scheduled tasks..." -ForegroundColor Yellow
$Tasks = @("LLM-Native-Server", "LLM-Server", "LLM-Native-API", "LLM-Watchdog", "LLM-Server-Native")
foreach ($t in $Tasks) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}

# 4. УДАЛЕНИЕ ДИРЕКТОРИИ (llm_native)
$W = "$env:USERPROFILE\llm_native"
if (Test-Path $W) {
    Write-Host "[3/5] Deleting entire directory: $W..." -ForegroundColor Red
    # Даем драйверу 2 секунды "отпустить" память перед удалением бинарников
    Start-Sleep -s 2
    
    # Снимаем защиту файлов (иногда блокируются как системные)
    Get-ChildItem -Path $W -Recurse | ForEach-Object { $_.Attributes = 'Normal' }
    
    # Рекурсивное удаление
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    
    if (Test-Path $W) {
        Write-Host "  Standard delete failed, using CMD force wipe..." -ForegroundColor Gray
        cmd.exe /c "rmdir /s /q `"$W`""
    }
}

# 5. ОЧИСТКА ВРЕМЕННЫХ СКРИПТОВ
Write-Host "[4/5] Cleaning up temp downloaders..." -ForegroundColor Yellow
$TempScripts = @("s.ps1", "d.ps1", "x.ps1", "f.ps1", "ask.ps1", "chat.ps1", "prune.ps1", "x75.ps1", "w.ps1")
foreach ($f in $TempScripts) {
    if (Test-Path "$env:TEMP\$f") { Remove-Item -Force "$env:TEMP\$f" }
}

# 6. ПРОВЕРКА DOCKER
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "[5/5] Stopping any LLM Docker containers..." -ForegroundColor Yellow
    $docker_llm = docker ps -q --filter "name=vllm" --filter "name=sglang" --filter "name=worker-server"
    if ($docker_llm) { docker stop $docker_llm | Out-Null }
}

Write-Host "`n--- SYSTEM WIPED CLEAN ---" -ForegroundColor Green
Write-Host "All files removed. Memory should be free."
Write-Host "Check 'nvidia-smi' to verify."
