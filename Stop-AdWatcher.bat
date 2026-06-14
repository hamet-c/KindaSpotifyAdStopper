@echo off
rem Stops any running ad watcher (visible or hidden).
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*SpotifyAdRestarter.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Host 'Ad watcher stopped.'"
pause
