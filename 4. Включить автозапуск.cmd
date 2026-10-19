@echo off
:: Installs the hidden scheduled task (runs 2 min after boot). Run again after editing zapret-auto.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -InstallTask
pause
