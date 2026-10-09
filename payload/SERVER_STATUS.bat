@echo off
title AzerothCore - Status
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ServerControl.ps1" -Action Status
pause
