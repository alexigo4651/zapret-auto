@echo off
:: Removes the scheduled task. zapret itself keeps working.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -RemoveTask
pause
