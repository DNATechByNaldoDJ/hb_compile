@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-linux-docker.ps1" %*
exit /b %ERRORLEVEL%
