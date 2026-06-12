@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-zig.ps1" %*
exit /b %ERRORLEVEL%
