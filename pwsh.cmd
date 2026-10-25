@echo off
if "%~1"=="--version" (
    echo PowerShell 7.4.0
    exit /b 0
)
powershell.exe %*
