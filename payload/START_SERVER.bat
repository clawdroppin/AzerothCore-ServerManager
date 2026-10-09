@echo off
title AzerothCore - Server Control
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ServerControl.ps1" -Action Start
rem Keep the window open only when something went wrong, so the message can be read.
if errorlevel 1 (
    echo.
    pause
)
