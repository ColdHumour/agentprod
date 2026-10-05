@echo off
chcp 65001 >nul
title WEBP to JPG

rem Scan the folder containing this batch file.
set "SCRIPT_DIR=%~dp0"

"D:\Anaconda3\python.exe" "%SCRIPT_DIR%webp_to_jpg.py"

if errorlevel 1 (
    echo.
    echo Script failed. Please check the error message above.
    pause
)
