@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "ELEVATE_SCRIPT=%~f0"
set "ELEVATE_ARGS=%*"

net session >nul 2>nul
if not "%errorlevel%"=="0" (
	echo Requesting administrator rights...
	if "%~1"=="" (
		"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ELEVATE_SCRIPT -Verb RunAs -Wait"
	) else (
		"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ELEVATE_SCRIPT -ArgumentList $env:ELEVATE_ARGS -Verb RunAs -Wait"
	)
	set "RC=!errorlevel!"
	if not "!RC!"=="0" echo Administrator elevation failed or was cancelled. Exit code !RC!.
	pause
	exit /b !RC!
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0one_tap_windows.ps1" -Stop
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
	echo Stopped.
) else (
	echo Failed with exit code %RC%.
)
pause
exit /b %RC%
