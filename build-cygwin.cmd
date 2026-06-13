@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-cygwin.ps1" %*
exit /b %ERRORLEVEL%
