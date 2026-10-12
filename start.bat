@echo off
setlocal
cd /d "%~dp0"

:: Check wslc existence
where wslc >nul 2>&1
if %errorlevel% equ 0 goto check_runtime
if exist "C:\Program Files\WSL\wslc.exe" goto check_runtime
if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\wslc.exe" goto check_runtime

echo ===================================================
echo   hayamimi - WSL 3.0 (WSL Containers) セットアップ
echo ===================================================
echo.
echo [注意] WSL 3.0 / WSL Containers (wslc) が見つかりませんでした。
echo hayamimi の実行には WSL 3.0 が必要です。
echo.
set /p "DO_INSTALL=今すぐ全自動で WSL 3.0 をインストールしますか？ (Y/N): "
if /i "%DO_INSTALL%"=="Y" (
    echo [*] 管理者権限で WSL 3.0 の自動インストールを開始します...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& { Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\launcher_gui.ps1\"' }"
    exit /b 0
)
echo.
echo WSL 3.0 のインストールをキャンセルしました。
echo ランチャー GUI を起動して後からインストールすることも可能です。
echo.
pause
goto check_runtime

:check_runtime
:: Select PowerShell Runtime: pwsh (PS7) if available, otherwise powershell (PS5.1)
set "PS_CMD=powershell"
where pwsh >nul 2>&1
if %errorlevel% equ 0 set "PS_CMD=pwsh"

:: Check for --rebuild / -r flag
if /i "%~1"=="--rebuild" goto do_build
if /i "%~1"=="-r" goto do_build

:: Check container image existence (auto build if missing)
wslc images 2>nul | findstr /i "hayamimi" >nul
if %errorlevel% equ 0 goto launch_gui

:do_build
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