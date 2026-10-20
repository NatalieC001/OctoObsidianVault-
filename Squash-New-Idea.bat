@echo off
title Squash New Idea
set /p UNATTENDED=Run unattended (no questions)? (y/N): 
if /I "%UNATTENDED%"=="y" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0squash-idea.ps1" -Unattended
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0squash-idea.ps1"
)
echo.
pause