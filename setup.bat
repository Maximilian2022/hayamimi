@echo off
setlocal
cd /d "%~dp0"

echo ===================================================
echo   hayamimi (Early Hearing) - Setup Launcher
echo ===================================================
echo.

:: 1. Check PowerShell Runtime (prefer pwsh if available, fallback to powershell)
set "PS_CMD=powershell"
where pwsh >nul 2>&1
if %errorlevel% equ 0 set "PS_CMD=pwsh"

:: 2. Check local setup.ps1 or download from GitHub
set "SETUP_SCRIPT=%~dp0setup.ps1"
if exist "%SETUP_SCRIPT%" goto run_setup

set "SETUP_SCRIPT=%TEMP%\hayamimi_setup.ps1"
set "GITHUB_RAW_URL=https://raw.githubusercontent.com/Maximilian2022/hayamimi/main/setup.ps1"

echo [*] Downloading setup script from GitHub...
echo     URL: %GITHUB_RAW_URL%
echo.

%PS_CMD% -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('%GITHUB_RAW_URL%', '%SETUP_SCRIPT%')"

if not exist "%SETUP_SCRIPT%" (
    echo [ERROR] Failed to download setup.ps1 from GitHub.
    echo Please check your internet connection or download manually:
    echo %GITHUB_RAW_URL%
    echo.
    pause
    exit /b 1
)

:run_setup
echo [*] Launching hayamimi setup GUI...
%PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%"

:: Clean up temp file if downloaded
if exist "%TEMP%\hayamimi_setup.ps1" (
    del /f /q "%TEMP%\hayamimi_setup.ps1" >nul 2>&1
)

endlocal
exit /b 0
