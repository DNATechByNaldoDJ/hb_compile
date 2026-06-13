@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-linux-docker.ps1" %*
exit /b %ERRORLEVEL%
