@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "STATE=%~dp0windows\state"
set "LOG=%STATE%\one_tap_windows_launcher.log"
set "ELEVATE_SCRIPT=%~f0"
set "ELEVATE_ARGS=%*"

if not exist "%STATE%" mkdir "%STATE%" >nul 2>nul
echo [%date% %time%] one_tap_windows.bat %*>"%LOG%"

if not exist "%~dp0windows\one_tap_windows.ps1" (
	echo ERROR: windows\one_tap_windows.ps1 was not found.
	echo ERROR: windows\one_tap_windows.ps1 was not found.>>"%LOG%"
	pause
	exit /b 1
)

where powershell.exe >nul 2>nul
if not exist "%PS%" if errorlevel 1 (
	echo ERROR: PowerShell was not found.
	echo ERROR: PowerShell was not found.>>"%LOG%"
	pause
	exit /b 1
)

net session >nul 2>nul
if not "%errorlevel%"=="0" (
	echo Requesting administrator rights...
	echo Requesting administrator rights...>>"%LOG%"
	if "%~1"=="" (
		"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ELEVATE_SCRIPT -Verb RunAs -Wait"
	) else (
		"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ELEVATE_SCRIPT -ArgumentList $env:ELEVATE_ARGS -Verb RunAs -Wait"
	)
	set "RC=!errorlevel!"
	if not "!RC!"=="0" (
		echo Administrator elevation failed or was cancelled. Exit code !RC!.
		echo Administrator elevation failed or was cancelled. Exit code !RC!.>>"%LOG%"
	) else (
		echo Elevated run finished.
		echo Elevated run finished.>>"%LOG%"
	)
	echo Launcher log: %LOG%
	pause
	exit /b !RC!
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\one_tap_windows.ps1" %*
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
	echo Done.
) else (
	echo Failed with exit code %RC%.
)
echo Logs:
echo   %LOG%
echo   %STATE%\one_tap_windows.log
pause
exit /b %RC%
