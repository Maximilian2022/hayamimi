@echo off
setlocal
cd /d "%~dp0"

:: Select PowerShell Runtime: pwsh (PS7) if available, otherwise powershell (PS5.1)
set "PS_CMD=powershell"
where pwsh >nul 2>&1
if %errorlevel% equ 0 set "PS_CMD=pwsh"

:: If start.vbs exists, run via wscript silently to prevent Windows Terminal popup
if exist "%~dp0start.vbs" (
    start "" wscript.exe "%~dp0start.vbs"
    endlocal
    exit /b 0
)

:: Fallback if start.vbs is missing
start "" %PS_CMD% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\launcher_gui.ps1"

endlocal
exit /b 0