@echo off
title AzerothCore - Prerequisites Installer
rem Standalone entry point: opens the Control Center directly on the Prerequisites page.
powershell -NoProfile -STA -ExecutionPolicy Bypass -Command ". '%~dp0..\..\src\App.ps1' -StartPage Prereqs"
if errorlevel 1 (
  echo.
  echo Something went wrong starting the installer. Please take a screenshot of this window.
  pause
)
