@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-standard.ps1" %*
exit /b %ERRORLEVEL%
