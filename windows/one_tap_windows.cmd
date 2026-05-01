@echo off
setlocal

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

net session >nul 2>nul
if not "%errorlevel%"=="0" (
	echo Requesting administrator rights...
	"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
	exit /b
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0one_tap_windows.ps1" %*
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
	echo Done.
) else (
	echo Failed with exit code %RC%.
)
pause
exit /b %RC%
