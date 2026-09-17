@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RosePine.ps1" %*
set "installer_exit_code=%errorlevel%"
if not "%installer_exit_code%"=="0" pause
exit /b %installer_exit_code%
