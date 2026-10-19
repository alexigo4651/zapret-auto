@echo off
:: Forces a full strategy search even if the current one seems fine.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -Repick
pause
