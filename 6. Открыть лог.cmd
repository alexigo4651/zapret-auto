@echo off
:: Opens the log of every run in Notepad.
if exist "C:\zapret-auto\zapret-auto.log" (
  start "" notepad "C:\zapret-auto\zapret-auto.log"
) else (
  echo Log not found yet: the program has not run on this PC.
  pause
)
