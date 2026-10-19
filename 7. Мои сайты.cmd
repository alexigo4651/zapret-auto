@echo off
:: Opens the "my sites" list in Notepad; after it is saved, adds the sites to zapret and checks them.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-auto.ps1" -EditSites
pause
