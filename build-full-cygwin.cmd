@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-full-cygwin.ps1" %*
exit /b %ERRORLEVEL%
