@echo off
setlocal
title Stop Octo Assistant
echo [1/4] Stopping watcher...
taskkill /F /IM node.exe   >nul 2>&1
taskkill /F /IM python.exe >nul 2>&1
taskkill /F /IM pythonw.exe >nul 2>&1
echo [2/4] Stopping Octo server...
taskkill /F /IM octo.exe        >nul 2>&1
taskkill /F /IM octo-server.exe >nul 2>&1
echo [3/4] Unloading models...
ollama stop qwen2.5:14b >nul 2>&1
ollama stop gemma2:9b   >nul 2>&1
echo [4/4] Shutting down Ollama...
taskkill /F /IM "ollama app.exe" >nul 2>&1
taskkill /F /IM ollama.exe       >nul 2>&1
echo.
echo All stopped. VRAM free for VR.
timeout /t 3 >nul
endlocal
