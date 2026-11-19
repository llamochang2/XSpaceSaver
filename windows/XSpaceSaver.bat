@echo off
rem XSpaceSaver launcher
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0XSpaceSaver.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to start. Please send a screenshot of this window.
  pause
)
