@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-mingw64.ps1" %*
exit /b %ERRORLEVEL%
