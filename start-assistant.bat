@echo off
setlocal
title Start Octo Assistant
echo ============================================
echo   Starting Octo Assistant
echo ============================================
echo.
set "VAULT_PATH=%~dp0.."
set "OCTO_BIN=%USERPROFILE%\.local\bin\octo.exe"
echo [1/2] Starting Ollama...
tasklist /FI "IMAGENAME eq ollama.exe" 2>nul | find /I "ollama.exe" >nul
if errorlevel 1 (
    start "" /B "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" serve
    echo     Ollama launching, waiting 3s...
    timeout /t 3 >nul
) else (
    echo     Ollama already running.
)
echo [2/2] Starting Octo server...
cd /d "%VAULT_PATH%"
start "" /B "%OCTO_BIN%" serve -d
echo     Octo server on http://127.0.0.1:8088
echo.
echo Ready. Double-click Squash-New-Idea.bat to use it.
timeout /t 5 >nul
endlocal
