@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-linux-wsl.ps1" %*
exit /b %ERRORLEVEL%
