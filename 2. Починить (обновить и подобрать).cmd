@echo off
:: Normal run: update zapret if a new release is out, re-pick the strategy only if something does not open.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1"
pause
