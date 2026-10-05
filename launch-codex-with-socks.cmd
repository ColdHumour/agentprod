@echo off
setlocal
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0launch-codex-with-socks.ps1" %*
set "launcherExitCode=%errorlevel%"
if not "%launcherExitCode%"=="0" pause
exit /b %launcherExitCode%
