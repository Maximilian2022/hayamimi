@echo off
setlocal
cd /d "%~dp0"

set "PS_CMD=powershell"
where pwsh >nul 2>&1
if %errorlevel% equ 0 set "PS_CMD=pwsh"

start "" %PS_CMD% -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\desktop_overlay.ps1" %*
endlocal
exit /b 0
