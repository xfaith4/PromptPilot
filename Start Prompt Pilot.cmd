@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-PromptPilot.ps1" -Restart
if errorlevel 1 pause
endlocal
