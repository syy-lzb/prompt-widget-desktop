@echo off
rem Stop the prompt polish widget. Delegates to stop.ps1 so there is only
rem one place that knows how to find the running instance.
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"

timeout /t 2 >nul
