[CmdletBinding()]
param(
	[switch]$SelfTest,
	[switch]$NoService,
	[switch]$Stop,
	[switch]$ResetStrategy
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'winws2'
$ScriptDir = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $ScriptDir
$StateDir = Join-Path $ScriptDir 'state'
$StrategyFile = Join-Path $ScriptDir 'strategy.windows.args'
$ArgsFile = Join-Path $ScriptDir 'winws2.args'
$ConfigFile = Join-Path $ScriptDir 'config.windows.ps1'
$LogFile = Join-Path $StateDir 'one_tap_windows.log'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
try {
	Start-Transcript -Path $LogFile -Append | Out-Null
} catch {
	Write-Warning "Could not start transcript log: $LogFile"
}

function Info {
	param([string]$Message)
	Write-Host "[one-tap] $Message"
}

function To-ZapretPath {
	param([Parameter(Mandatory = $true)][string]$Path)
	return ([System.IO.Path]::GetFullPath($Path) -replace '\\','/')
}

function Test-Admin {
	$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
	return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SourceLayout {
	$Required = @(
		'lua\zapret-lib.lua',
		'lua\zapret-antidpi.lua',
		'files\fake\quic_initial_www_google_com.bin',
		'init.d\windivert.filter.examples\windivert_part.quic_initial_ietf.txt'
	)
	$Ok = $true
	foreach ($Rel in $Required) {
		$Path = Join-Path $Root $Rel
		if (-not (Test-Path -LiteralPath $Path)) {
			Write-Warning "Missing required project file: $Rel"
			$Ok = $false
		}
	}
	return $Ok
}

function Get-Winws2Candidates {
	$Is64 = [Environment]::Is64BitOperatingSystem
	$Dirs = New-Object System.Collections.Generic.List[string]

	if ($Is64) {
		$Dirs.Add((Join-Path $Root 'binaries\windows-x86_64'))
		$Dirs.Add((Join-Path $Root 'windows\bin\x64'))
	}
	$Dirs.Add((Join-Path $Root 'binaries\windows-x86'))
	$Dirs.Add((Join-Path $Root 'windows\bin\x86'))
	$Dirs.Add((Join-Path $Root 'nfq2'))
	$Dirs.Add($Root)

	foreach ($Dir in $Dirs) {
		$Path = Join-Path $Dir 'winws2.exe'
		if (Test-Path -LiteralPath $Path) {
			[System.IO.Path]::GetFullPath($Path)
		}
	}
}

function Find-Winws2 {
	$Candidates = @(Get-Winws2Candidates | Select-Object -Unique)
	if ($Candidates.Count -gt 0) {
		return $Candidates[0]
	}
	return $null
}

function Test-RuntimeFiles {
	param([string]$Exe)
	if (-not $Exe) {
		Write-Warning 'winws2.exe is absent. Download a Windows release bundle or build Windows artifacts first.'
		return $false
	}

	$Dir = Split-Path -Parent $Exe
	$SysName = if ([Environment]::Is64BitOperatingSystem) { 'WinDivert64.sys' } else { 'WinDivert32.sys' }
	$Required = @('cygwin1.dll', 'WinDivert.dll', $SysName)
	$Ok = $true
	foreach ($Name in $Required) {
		if (-not (Test-Path -LiteralPath (Join-Path $Dir $Name))) {
			Write-Warning "Missing runtime file near winws2.exe: $Name"
			$Ok = $false
		}
	}
	return $Ok
}

function Write-DefaultStrategy {
	if ((Test-Path -LiteralPath $StrategyFile) -and (-not $ResetStrategy)) {
		return
	}

	$Strategy = @(
		'--filter-tcp=80 --filter-l7=http --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --lua-desync=fakedsplit:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --new',
		'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 --lua-desync=multidisorder:pos=midsld --new',
		'--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new',
		'--filter-l7=wireguard,stun,discord --payload=wireguard_initiation,wireguard_cookie,stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)
	Set-Content -LiteralPath $StrategyFile -Value $Strategy -Encoding ASCII
}

function Add-ExistingArgFile {
	param(
		[System.Collections.Generic.List[string]]$Lines,
		[string]$RelativePath
	)
	$Path = Join-Path $Root $RelativePath
	if (Test-Path -LiteralPath $Path) {
		$Lines.Add('--wf-raw-part=@"' + (To-ZapretPath $Path) + '"')
	}
}

function Write-RunConfig {
	param([Parameter(Mandatory = $true)][string]$Exe)

	New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
	New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
	Write-DefaultStrategy

	$Lines = New-Object System.Collections.Generic.List[string]
	$Lines.Add('--wf-tcp-out=80,443')
	$Lines.Add('--wf-udp-out=443')
	$Lines.Add('--wf-filter-lan=1')
	$Lines.Add('--wf-filter-loopback=0')
	$Lines.Add('--lua-init=@"' + (To-ZapretPath (Join-Path $Root 'lua\zapret-lib.lua')) + '"')
	$Lines.Add('--lua-init=@"' + (To-ZapretPath (Join-Path $Root 'lua\zapret-antidpi.lua')) + '"')
	$Lines.Add('"--lua-init=fake_default_tls = tls_mod(fake_default_tls,''rnd,rndsni'')"')
	$Lines.Add('--blob=quic_google:@"' + (To-ZapretPath (Join-Path $Root 'files\fake\quic_initial_www_google_com.bin')) + '"')

	Add-ExistingArgFile $Lines 'init.d\windivert.filter.examples\windivert_part.discord_media.txt'
	Add-ExistingArgFile $Lines 'init.d\windivert.filter.examples\windivert_part.stun.txt'
	Add-ExistingArgFile $Lines 'init.d\windivert.filter.examples\windivert_part.wireguard.txt'
	Add-ExistingArgFile $Lines 'init.d\windivert.filter.examples\windivert_part.quic_initial_ietf.txt'

	foreach ($Line in Get-Content -LiteralPath $StrategyFile) {
		if ($Line.Trim().Length -gt 0 -and -not $Line.Trim().StartsWith('#')) {
			$Lines.Add($Line)
		}
	}

	Set-Content -LiteralPath $ArgsFile -Value $Lines -Encoding ASCII

	$Config = @(
		'# Generated by windows\one_tap_windows.ps1',
		'$Winws2Exe = ' + "'" + $Exe.Replace("'", "''") + "'",
		'$ArgsFile = ' + "'" + $ArgsFile.Replace("'", "''") + "'",
		'$StrategyFile = ' + "'" + $StrategyFile.Replace("'", "''") + "'",
		'$ServiceName = ' + "'" + $ServiceName + "'",
		'$LastConfigured = ' + "'" + (Get-Date -Format s) + "'"
	)
	Set-Content -LiteralPath $ConfigFile -Value $Config -Encoding ASCII
}

function Stop-Winws2 {
	$Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($Svc) {
		if ($Svc.Status -ne 'Stopped') {
			Info "Stopping service $ServiceName"
			Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
			try {
				$SvcAfterStop = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
				if ($SvcAfterStop) {
					$SvcAfterStop.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
				}
			} catch {
			}
		}
	}
	taskkill.exe /IM winws2.exe /F 2>$null | Out-Null
}

function Install-Winws2Service {
	param([Parameter(Mandatory = $true)][string]$Exe)

	$ArgRef = '@"' + (To-ZapretPath $ArgsFile) + '"'
	$BinPath = '"' + $Exe + '" ' + $ArgRef

	Stop-Winws2
	$Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($Svc) {
		Info "Updating service $ServiceName"
		& sc.exe config $ServiceName binPath= $BinPath start= auto | Out-Host
	} else {
		Info "Creating service $ServiceName"
		& sc.exe create $ServiceName binPath= $BinPath start= auto DisplayName= 'zapret2 winws2' | Out-Host
		& sc.exe description $ServiceName 'zapret2 One Tap WinDivert runner' | Out-Host
	}

	Info "Starting service $ServiceName"
	Start-Service -Name $ServiceName
}

if ($Stop) {
	if (-not (Test-Admin)) {
		Write-Error 'Administrator rights are required to stop winws2.'
		exit 1
	}
	Stop-Winws2
	exit 0
}

$LayoutOk = Test-SourceLayout
$Exe = Find-Winws2
$RuntimeOk = Test-RuntimeFiles $Exe

if ($SelfTest) {
	if ($LayoutOk) {
		Info 'Source layout is OK.'
	} else {
		exit 1
	}
	if ($RuntimeOk) {
		Info "Windows runtime bundle is present: $Exe"
	} else {
		Info 'Windows runtime bundle is not present in this checkout. This is expected for source-only trees.'
	}
	exit 0
}

if (-not (Test-Admin)) {
	Write-Error 'Administrator rights are required. Start windows\one_tap_windows.cmd.'
	exit 1
}
if (-not $Exe -or -not $RuntimeOk) {
	throw 'Windows binaries are not ready. Use a release bundle with winws2.exe, cygwin1.dll, WinDivert.dll and WinDivert*.sys, or build Windows artifacts from docs\compile.'
}

Write-RunConfig $Exe
if ($NoService) {
	Info 'Config saved. Starting winws2 in a minimized process.'
	& (Join-Path $ScriptDir 'start_windows.ps1')
} else {
	Install-Winws2Service $Exe
}

Info "Saved config: $ConfigFile"
Info "Saved strategy: $StrategyFile"
