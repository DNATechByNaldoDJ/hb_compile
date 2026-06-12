@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-msvc64.ps1" %*
exit /b %ERRORLEVEL%
