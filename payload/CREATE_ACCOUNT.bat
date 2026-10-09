@echo off
title AzerothCore - Create Game Account
cd /d "%~dp0"
echo.
echo  Create a new login for the game.
echo  Username: 3-17 letters or numbers.  Password: 4-16 characters.
echo.
set /p ACC_USER=  Username: 
set /p ACC_PASS=  Password: 
echo.
echo  Should this account be a Game Master (can use . commands)?
set /p ACC_GM=  Type Y for yes, N for no: 
set GMLEVEL=0
if /I "%ACC_GM%"=="Y" set GMLEVEL=3
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\New-GameAccount.ps1" -Username "%ACC_USER%" -Password "%ACC_PASS%" -GmLevel %GMLEVEL%
echo.
pause
