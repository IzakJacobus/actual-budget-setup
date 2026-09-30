@echo off
title Install Actual Budget
echo.
echo  This installs your own private Actual Budget server on this laptop.
echo  Windows will ask for permission - click Yes.
echo.
pause
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0program\install.ps1\"'"
