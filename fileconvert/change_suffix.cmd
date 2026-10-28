@echo off
setlocal

set /p "from=Source extension (e.g. pdg): "
set /p "to=Target extension (e.g. png): "

rem Allow both pdg and .pdg
if "%from:~0,1%"=="." set "from=%from:~1%"
if "%to:~0,1%"=="." set "to=%to:~1%"

echo.
echo %from%  --^>  %to%
echo.
echo [C] Copy files and keep originals
echo [R] Rename files
echo.
set /p "mode=Choose C or R: "

echo.

if /I "%mode%"=="C" (
    for %%F in (*.%from%) do (
        if exist "%%F" (
            copy /Y "%%F" "%%~nF.%to%" >nul
            echo %%F --^> %%~nF.%to%
        )
    )
) else if /I "%mode%"=="R" (
    for %%F in (*.%from%) do (
        if exist "%%F" (
            echo %%F --^> %%~nF.%to%
            ren "%%F" "%%~nF.%to%"
        )
    )
) else (
    echo Invalid choice.
)

echo.
echo Done.
pause