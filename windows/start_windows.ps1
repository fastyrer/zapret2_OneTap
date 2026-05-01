[CmdletBinding()]
param(
	[switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ConfigFile = Join-Path $ScriptDir 'config.windows.ps1'

function To-ZapretPath {
	param([Parameter(Mandatory = $true)][string]$Path)
	return ([System.IO.Path]::GetFullPath($Path) -replace '\\','/')
}

if (-not (Test-Path -LiteralPath $ConfigFile)) {
	Write-Error "Windows config is absent. Run windows\one_tap_windows.cmd first."
	exit 1
}

. $ConfigFile

if (-not (Test-Path -LiteralPath $Winws2Exe)) {
	Write-Error "winws2.exe was not found at saved path: $Winws2Exe"
	exit 1
}
if (-not (Test-Path -LiteralPath $ArgsFile)) {
	Write-Error "Arguments file was not found: $ArgsFile"
	exit 1
}

$ArgRef = '@"' + (To-ZapretPath $ArgsFile) + '"'
if ($Foreground) {
	& $Winws2Exe $ArgRef
	exit $LASTEXITCODE
}

Start-Process -FilePath $Winws2Exe -ArgumentList @($ArgRef) -WindowStyle Minimized
