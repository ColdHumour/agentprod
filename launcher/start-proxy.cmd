@echo off
setlocal
rem Edit the configuration at the top of start-proxy.ps1.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxy.ps1"
set "LaunchExitCode=%ERRORLEVEL%"
if not "%LaunchExitCode%"=="0" (
    echo.
    echo Launch failed. Review the message above.
    pause
)
exit /b %LaunchExitCode%
