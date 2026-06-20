@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-HarbourBuilds.ps1" %*
exit /b %ERRORLEVEL%
