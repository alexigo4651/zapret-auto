@echo off
:: Only checks which sites open with the current setup. Changes nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -CheckOnly
pause
