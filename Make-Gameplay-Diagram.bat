@echo off
setlocal
title Make Gameplay Diagram
cd /d "%~dp0"
echo ============================================
echo   Make Gameplay Diagram
echo ============================================
echo.
echo   Folder: %~dp0
echo.
echo   Checking files...
if not exist "%~dp0make-gameplay-diagram.ps1" (
    echo   ERROR: make-gameplay-diagram.ps1 not found in this folder.
    echo   It must be next to this .bat.
    echo.
    pause
    endlocal
    exit /b 1
)
if not exist "%~dp0rules.md" (
    echo   WARNING: rules.md not found. The diagram needs it.
    echo   Create octo-config\rules.md with the rules text, then run again.
    echo.
    pause
    endlocal
    exit /b 1
)
echo   Found make-gameplay-diagram.ps1 and rules.md.
echo.
echo   Running...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-gameplay-diagram.ps1" -Open
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo   The script exited with code %RC%.
) else (
    echo   Done.
)
echo.
pause
endlocal
exit /b %RC%