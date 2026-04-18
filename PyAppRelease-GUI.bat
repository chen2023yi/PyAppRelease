@echo off
REM Launch PyAppRelease GUI without a visible console window.
start "" /B powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PyAppRelease-GUI.ps1"
