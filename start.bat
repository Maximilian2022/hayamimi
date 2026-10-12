@echo off
setlocal
cd /d "%~dp0"

:: Check wslc existence
where wslc >nul 2>&1
if %errorlevel% equ 0 goto check_runtime

echo ===================================================
echo   hayamimi - WSL3 Native Launcher
echo ===================================================
echo.
echo [ERROR] wslc command not found.
echo WSL 3.0 or WSL Containers (WSLC) is required.
echo Please update WSL by running 'wsl --update' in PowerShell.
echo.
pause
exit /b 1

:check_runtime
:: Select PowerShell Runtime: pwsh (PS7) if available, otherwise powershell (PS5.1)
set "PS_CMD=powershell"
where pwsh >nul 2>&1
if %errorlevel% equ 0 set "PS_CMD=pwsh"

:: Check container image existence (auto build if missing)
wslc images 2>nul | findstr /i "hayamimi" >nul
if %errorlevel% equ 0 goto launch_gui

echo [*] Building hayamimi container image, please wait...
wslc build -t hayamimi:latest .
if %errorlevel% equ 0 goto launch_gui

echo [ERROR] Failed to build container image.
pause
exit /b 1

:launch_gui
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