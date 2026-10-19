@echo off
:: Opens the exclusions list in Notepad; after it is saved, zapret stops touching those sites.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -EditExclusions
pause
