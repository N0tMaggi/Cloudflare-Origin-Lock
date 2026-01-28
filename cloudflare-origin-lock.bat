@echo off
setlocal
set SCRIPT=%~dp0cloudflare-origin-lock.ps1
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %errorlevel%
