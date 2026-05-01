@echo off
setlocal

cd /d "%~dp0"

if not exist "%~dp0windows\one_tap_windows.cmd" (
	echo ERROR: windows\one_tap_windows.cmd was not found.
	pause
	exit /b 1
)

call "%~dp0windows\one_tap_windows.cmd" %*
exit /b %errorlevel%
