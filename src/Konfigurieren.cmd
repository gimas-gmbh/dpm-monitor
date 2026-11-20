@echo off
rem dpm-monitor: startet die Oberflaeche. Configure.ps1 fordert selbst Administratorrechte an.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Configure.ps1"
