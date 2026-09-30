@echo off
title Install Actual Budget
echo.
echo  This installs your own private Actual Budget server on this laptop.
echo  Windows will ask for permission - click Yes.
echo.
pause
rem The path goes through an environment variable so quotes/apostrophes in folder names can't break it.
set "ACTUAL_SETUP_PS1=%~dp0program\install.ps1"
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -NoExit -ExecutionPolicy Bypass -File \"' + $env:ACTUAL_SETUP_PS1 + '\"')"
