@echo off
REM One-time setup: creates a desktop shortcut to launch EverQuest on Theo and Co.
REM Safe to run multiple times - it just overwrites the shortcut.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_Setup_Helper.ps1"

echo.
pause
