@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-zig.ps1" %*
exit /b %ERRORLEVEL%
