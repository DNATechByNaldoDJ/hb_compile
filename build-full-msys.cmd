@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-msys.ps1" %*
exit /b %ERRORLEVEL%
