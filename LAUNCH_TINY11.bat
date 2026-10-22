@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"

:: Self-elevate so the user can launch the builder normally.
net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%SCRIPT_DIR%tiny11maker.ps1" (
    echo ERROR: tiny11maker.ps1 was not found beside this launcher.
    pause
    exit /b 2
)

start "Windows 11 Optimized Builder V1" /max PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tiny11maker.ps1" -ScratchDisk "%SCRIPT_DIR%"
endlocal
