# LLM STOP - kills server and watchdog
$ProgressPreference = "SilentlyContinue"
Write-Host "Stopping LLM server and watchdog..." -ForegroundColor Yellow

# Kill llama-server
$killed = 0
Get-Process | Where-Object { $_.Name -match "llama" } | ForEach-Object {
    Stop-Process $_ -Force -ErrorAction SilentlyContinue
    $killed++
}
Write-Host "  Stopped $killed llama process(es)" -ForegroundColor Green

# Kill watchdog by finding the powershell that runs watchdog.ps1
Get-WmiObject Win32_Process | Where-Object {
    $_.Name -eq "powershell.exe" -and $_.CommandLine -match "watchdog"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped watchdog (PID $($_.ProcessId))" -ForegroundColor Green
}

Write-Host "All stopped." -ForegroundColor Green
