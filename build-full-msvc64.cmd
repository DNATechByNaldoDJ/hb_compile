@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-msvc64.ps1" %*
exit /b %ERRORLEVEL%
