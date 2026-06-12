@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-standard.ps1" %*
exit /b %ERRORLEVEL%
