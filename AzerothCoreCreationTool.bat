@echo off
title AzerothCore Control Center
powershell -NoProfile -STA -ExecutionPolicy Bypass -Command ". '%~dp0src\App.ps1'"
if errorlevel 1 (
  echo.
  echo Something went wrong starting the app. Please take a screenshot of this window.
  pause
)
