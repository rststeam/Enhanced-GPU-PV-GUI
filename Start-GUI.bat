@echo off
setlocal

set "PROJECT_ROOT=%~dp0"
set "GUI_SCRIPT=%PROJECT_ROOT%GUI\EnhancedGpuPv.Gui.ps1"

if not exist "%GUI_SCRIPT%" (
    echo Enhanced GPU-PV GUI script was not found:
    echo "%GUI_SCRIPT%"
    echo.
    pause
    exit /b 1
)

pushd "%PROJECT_ROOT%" >nul
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%GUI_SCRIPT%"
popd >nul

exit /b 0
