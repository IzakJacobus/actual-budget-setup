@echo off
title Uninstall Actual Budget
echo.
echo  This stops Actual Budget, removes its automatic start and daily backup,
echo  and turns off phone access.
echo.
echo  Your budget data (C:\actual-server\data) and backups are KEPT.
echo.
choice /C YN /M " Uninstall now"
if errorlevel 2 exit /b
set "S=C:\actual-server\uninstall.ps1"
if not exist "%S%" set "S=%~dp0program\uninstall.ps1"
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%S%\" -RemoveTailscaleServe'"
