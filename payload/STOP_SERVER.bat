@echo off
title AzerothCore - Shutdown
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ServerControl.ps1" -Action Stop
echo.
pause
