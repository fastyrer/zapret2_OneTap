[CmdletBinding()]
param(
	[switch]$SelfTest,
	[switch]$NoService,
	[switch]$NoDownload,
	[switch]$NoProbe,
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
$StrategyNameFile = Join-Path $StateDir 'strategy.windows.name'
$ProbeReportFile = Join-Path $StateDir 'connectivity-test.json'
$DiscordHostlistFile = Join-Path $StateDir 'discord-hosts.txt'
$TargetHostlistFile = Join-Path $StateDir 'one-tap-target-hosts.txt'
$DefaultReleaseRepos = @('fastyrer/zapret2_OneTap', 'bol-van/zapret2')

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

function Get-DiscordHosts {
	return @(
		'discord.com',
		'discord.gg',
		'discordapp.com',
		'discordapp.net',
		'discord.media',
		'discordcdn.com',
		'gateway.discord.gg',
		'cdn.discordapp.com',
		'media.discordapp.net'
	)
}

function Write-DiscordHostlist {
	$Hosts = Get-DiscordHosts
	New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
	Set-Content -LiteralPath $DiscordHostlistFile -Value $Hosts -Encoding ASCII
}

function Get-DiscordHostlistArg {
	return '--hostlist="' + (To-ZapretPath $DiscordHostlistFile) + '"'
}

function Write-TargetHostlist {
	$Hosts = @(
		'youtube.com',
		'youtu.be',
		'youtube-nocookie.com',
		'googlevideo.com',
		'ytimg.com',
		'ggpht.com',
		'youtubei.googleapis.com',
		'youtube.googleapis.com',
		'telegram.org',
		'telegram.me',
		't.me',
		'telegra.ph',
		'tdesktop.com',
		'telegram-cdn.org'
	) + (Get-DiscordHosts)
	New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
	Set-Content -LiteralPath $TargetHostlistFile -Value (@($Hosts | Select-Object -Unique)) -Encoding ASCII
}

function Get-TargetHostlistArg {
	return '--hostlist="' + (To-ZapretPath $TargetHostlistFile) + '"'
}

function Test-EnvFlag {
	param([Parameter(Mandatory = $true)][string]$Name)
	$Value = [Environment]::GetEnvironmentVariable($Name)
	return ($Value -match '^(1|true|yes|on)$')
}

function Test-StrategyIsTargetScoped {
	param([Parameter(Mandatory = $true)][string[]]$Lines)

	foreach ($Line in $Lines) {
		$Trim = $Line.Trim()
		if ($Trim.Length -eq 0 -or $Trim.StartsWith('#')) {
			continue
		}
		$IsWebProfile = (
			($Trim -match '--filter-tcp=[^ ]*(80|443)') -or
			($Trim -match '--filter-udp=[^ ]*443') -or
			($Trim -match '--filter-l7=[^ ]*(http|tls|quic)')
		)
		if ($IsWebProfile -and ($Trim -notmatch '--hostlist=')) {
			return $false
		}
	}
	return $true
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
		'init.d\windivert.filter.examples\windivert_part.discord_media.txt',
		'init.d\windivert.filter.examples\windivert_part.stun.txt',
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

function Get-WindowsArchName {
	if ([Environment]::Is64BitOperatingSystem) {
		return 'windows-x86_64'
	}
	return 'windows-x86'
}

function Test-RuntimeFiles {
	param([string]$Exe)
	if (-not $Exe) {
		Write-Warning 'winws2.exe is absent.'
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

function Get-ReleaseRepos {
	$Repos = New-Object System.Collections.Generic.List[string]
	if ($env:ZAPRET2_RELEASE_REPO) {
		foreach ($Repo in ($env:ZAPRET2_RELEASE_REPO -split '[,; ]+')) {
			if ($Repo.Trim().Length -gt 0) {
				$Repos.Add($Repo.Trim())
			}
		}
	}
	foreach ($Repo in $DefaultReleaseRepos) {
		$Repos.Add($Repo)
	}
	return @($Repos | Select-Object -Unique)
}

function Invoke-GitHubRequest {
	param([Parameter(Mandatory = $true)][string]$Uri)

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$Headers = @{ 'User-Agent' = 'zapret2-one-tap' }
	Invoke-RestMethod -Uri $Uri -Headers $Headers -UseBasicParsing
}

function Download-File {
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[Parameter(Mandatory = $true)][string]$OutFile
	)

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$Headers = @{ 'User-Agent' = 'zapret2-one-tap' }
	$OldProgress = $ProgressPreference
	$ProgressPreference = 'SilentlyContinue'
	try {
		Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $Headers -UseBasicParsing
	} finally {
		$ProgressPreference = $OldProgress
	}
}

function Expand-Zip {
	param(
		[Parameter(Mandatory = $true)][string]$ZipFile,
		[Parameter(Mandatory = $true)][string]$Destination
	)

	if (Test-Path -LiteralPath $Destination) {
		Remove-Item -LiteralPath $Destination -Recurse -Force
	}
	New-Item -ItemType Directory -Force -Path $Destination | Out-Null

	try {
		Expand-Archive -LiteralPath $ZipFile -DestinationPath $Destination -Force
	} catch {
		if (Test-Path -LiteralPath $Destination) {
			Remove-Item -LiteralPath $Destination -Recurse -Force
		}
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $Destination)
	}
}

function Find-RuntimeInExtractedRelease {
	param(
		[Parameter(Mandatory = $true)][string]$ExtractDir,
		[Parameter(Mandatory = $true)][string]$ArchName
	)

	$NeedSys = if ([Environment]::Is64BitOperatingSystem) { 'WinDivert64.sys' } else { 'WinDivert32.sys' }
	$Candidates = @(Get-ChildItem -LiteralPath $ExtractDir -Recurse -Filter winws2.exe | Where-Object { -not $_.PSIsContainer })
	foreach ($Candidate in $Candidates) {
		$Normalized = $Candidate.FullName -replace '/', '\'
		if ($Normalized -match ('\\binaries\\' + [regex]::Escape($ArchName) + '\\winws2\.exe$')) {
			return $Candidate.FullName
		}
	}
	foreach ($Candidate in $Candidates) {
		$Dir = Split-Path -Parent $Candidate.FullName
		if (
			(Test-Path -LiteralPath (Join-Path $Dir 'cygwin1.dll')) -and
			(Test-Path -LiteralPath (Join-Path $Dir 'WinDivert.dll')) -and
			(Test-Path -LiteralPath (Join-Path $Dir $NeedSys))
		) {
			return $Candidate.FullName
		}
	}
	return $null
}

function Install-WindowsRuntimeFromRelease {
	$ArchName = Get-WindowsArchName
	$ArchToken = if ($ArchName -eq 'windows-x86_64') { 'x86_64' } else { 'x86' }
	$Repos = Get-ReleaseRepos
	$LastError = $null

	foreach ($Repo in $Repos) {
		try {
			Info "Trying to download Windows runtime from GitHub release: $Repo"
			$Release = Invoke-GitHubRequest "https://api.github.com/repos/$Repo/releases/latest"
			$Assets = @($Release.assets)
			$Asset = @($Assets | Where-Object {
				$_.name -match '\.zip$' -and $_.name -match "win.*$ArchToken"
			} | Select-Object -First 1)
			if (-not $Asset -or $Asset.Count -eq 0) {
				$Asset = @($Assets | Where-Object {
					$_.name -match '\.zip$' -and $_.name -notmatch 'openwrt|embedded'
				} | Select-Object -First 1)
			}
			if (-not $Asset -or $Asset.Count -eq 0) {
				throw "No suitable zip asset found in latest release of $Repo"
			}

			$ZipPath = Join-Path $StateDir $Asset[0].name
			$ExtractDir = Join-Path $StateDir 'release_extract'
			Info "Downloading $($Asset[0].name)"
			Download-File $Asset[0].browser_download_url $ZipPath
			Info "Extracting $($Asset[0].name)"
			Expand-Zip $ZipPath $ExtractDir

			$ExtractedExe = Find-RuntimeInExtractedRelease $ExtractDir $ArchName
			if (-not $ExtractedExe) {
				throw "Downloaded release does not contain $ArchName runtime files"
			}

			$SourceDir = Split-Path -Parent $ExtractedExe
			$DestDir = Join-Path $Root (Join-Path 'binaries' $ArchName)
			New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
			Get-ChildItem -LiteralPath $SourceDir | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
				Copy-Item -LiteralPath $_.FullName -Destination $DestDir -Force
			}

			Info "Windows runtime installed to $DestDir"
			return (Join-Path $DestDir 'winws2.exe')
		} catch {
			$LastError = $_.Exception.Message
			Write-Warning "Could not use release repo ${Repo}: $LastError"
		}
	}

	throw "Automatic Windows runtime download failed. Last error: $LastError"
}

function Get-DefaultStrategyLines {
	param([string]$HostlistArg = '')

	$HostlistPart = ''
	if ($HostlistArg) {
		$HostlistPart = ' ' + $HostlistArg
	}
	return @(
		('--filter-tcp=80 --filter-l7=http' + $HostlistPart + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --lua-desync=fakedsplit:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --new'),
		('--filter-tcp=443 --filter-l7=tls' + $HostlistPart + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 --lua-desync=multidisorder:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic' + $HostlistPart + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=wireguard,stun,discord --payload=wireguard_initiation,wireguard_cookie,stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)
}

function New-StrategyCandidate {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][string[]]$Lines
	)
	[pscustomobject]@{
		Name = $Name
		Lines = $Lines
	}
}

function Get-StrategyCandidates {
	Write-DiscordHostlist
	Write-TargetHostlist
	$TargetHostlist = Get-TargetHostlistArg
	$DiscordHostlist = Get-DiscordHostlistArg
	$AllowBroadStrategies = Test-EnvFlag 'ZAPRET2_ALLOW_BROAD_STRATEGIES'
	$Candidates = New-Object System.Collections.Generic.List[object]
	if ((Test-Path -LiteralPath $StrategyFile) -and (-not $ResetStrategy)) {
		$Saved = @(Get-Content -LiteralPath $StrategyFile | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') })
		if ($Saved.Count -gt 0) {
			$SavedName = 'saved'
			if (Test-Path -LiteralPath $StrategyNameFile) {
				$SavedName = 'saved-' + ((Get-Content -LiteralPath $StrategyNameFile -TotalCount 1) -replace '[^A-Za-z0-9_.-]', '_')
			}
			if ($AllowBroadStrategies -or (Test-StrategyIsTargetScoped $Saved)) {
				$Candidates.Add((New-StrategyCandidate $SavedName $Saved))
			} else {
				Write-Warning "Skipping saved broad strategy $SavedName because it can affect unrelated HTTPS sites. Set ZAPRET2_ALLOW_BROAD_STRATEGIES=1 to allow it."
			}
		}
	}

	$Candidates.Add((New-StrategyCandidate 'target-light-multisplit' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'target-md5-fake-multisplit' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'target-quic-md5-fake' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'target-tls-timestamp-quic-fake' @(
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_ts=-1000 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'target-syndata-multisplit' @(
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-google-fake' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,sni=www.google.com:repeats=11 --lua-desync=multidisorder:pos=1,midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic ' + $DiscordHostlist + ' --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-padencap' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,padencap:repeats=4 --lua-desync=multidisorder:pos=1,midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic ' + $DiscordHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-syndata' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		('--filter-udp=443 --filter-l7=quic ' + $DiscordHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		('--filter-udp=443 --filter-l7=quic ' + $TargetHostlist + ' --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11 --new'),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)))
	$Candidates.Add((New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines $TargetHostlist)))

	if ($AllowBroadStrategies) {
		$Candidates.Add((New-StrategyCandidate 'broad-tcp-light-multisplit' @(
			'--filter-tcp=80 --filter-l7=http --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new',
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld'
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tcp-md5-fake-multisplit' @(
			'--filter-tcp=80 --filter-l7=http --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new',
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2'
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tcp-quic-md5-fake' @(
			'--filter-tcp=80 --filter-l7=http --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new',
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2 --new',
			'--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11'
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tls-timestamp-quic-fake' @(
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_ts=-1000 --new',
			'--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11'
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tls-syndata-multisplit' @(
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new',
			'--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=11'
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-full-default' (Get-DefaultStrategyLines)))
	}

	$Seen = @{}
	$Unique = New-Object System.Collections.Generic.List[object]
	foreach ($Candidate in $Candidates) {
		$Key = ($Candidate.Lines -join "`n")
		if (-not $Seen.ContainsKey($Key)) {
			$Seen[$Key] = $true
			$Unique.Add($Candidate)
		}
	}
	return $Unique
}

function Save-StrategyCandidate {
	param([Parameter(Mandatory = $true)]$Candidate)

	Set-Content -LiteralPath $StrategyFile -Value $Candidate.Lines -Encoding ASCII
	Set-Content -LiteralPath $StrategyNameFile -Value $Candidate.Name -Encoding ASCII
}

function Ensure-StrategyFile {
	if (Test-Path -LiteralPath $StrategyFile) {
		$Existing = @(Get-Content -LiteralPath $StrategyFile | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') })
		if (($Existing.Count -gt 0) -and ((Test-EnvFlag 'ZAPRET2_ALLOW_BROAD_STRATEGIES') -or (Test-StrategyIsTargetScoped $Existing))) {
			return
		}
		Write-Warning 'Replacing missing or broad saved strategy with target-scoped default to keep unrelated sites working.'
	}
	Write-DiscordHostlist
	Write-TargetHostlist
	Save-StrategyCandidate (New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines (Get-TargetHostlistArg)))
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
	param(
		[Parameter(Mandatory = $true)][string]$Exe,
		[string]$StrategyName = ''
	)

	New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
	New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
	Write-DiscordHostlist
	Write-TargetHostlist
	Ensure-StrategyFile

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
		'$StrategyName = ' + "'" + $StrategyName.Replace("'", "''") + "'",
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
	$Processes = @(Get-Process -Name winws2 -ErrorAction SilentlyContinue)
	if ($Processes.Count -gt 0) {
		Info "Stopping existing winws2 process"
		$Processes | Stop-Process -Force -ErrorAction SilentlyContinue
	}
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

function Get-EnvInt {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][int]$Default
	)

	$Value = [Environment]::GetEnvironmentVariable($Name)
	if (-not $Value) {
		return $Default
	}
	$Parsed = 0
	if ([int]::TryParse($Value, [ref]$Parsed) -and $Parsed -gt 0) {
		return $Parsed
	}
	return $Default
}

function New-ProbeTarget {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][string[]]$Urls
	)
	[pscustomobject]@{
		Name = $Name
		Urls = $Urls
	}
}

function Get-ConnectivityTargets {
	return @(
		(New-ProbeTarget 'GeneralWeb' @(
			'https://example.com/'
		)),
		(New-ProbeTarget 'YouTube' @(
			'https://www.youtube.com/generate_204',
			'https://www.youtube.com/robots.txt'
		)),
		(New-ProbeTarget 'Telegram' @(
			'https://api.telegram.org',
			'https://web.telegram.org'
		)),
		(New-ProbeTarget 'Discord' @(
			'https://discord.com/api/v9/experiments',
			'https://discord.com',
			'https://discord.com/api/v9/gateway',
			'https://gateway.discord.gg',
			'https://cdn.discordapp.com'
		))
	)
}

function Get-HttpResponseFromException {
	param([Parameter(Mandatory = $true)][System.Exception]$Exception)

	$Current = $Exception
	while ($Current) {
		if (($Current -is [System.Net.WebException]) -and $Current.Response) {
			return $Current.Response
		}
		$Current = $Current.InnerException
	}
	return $null
}

function Test-UrlReachable {
	param(
		[Parameter(Mandatory = $true)][string]$Url,
		[Parameter(Mandatory = $true)][int]$TimeoutSec
	)

	$Response = $null
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$Request = [Net.WebRequest]::Create($Url)
		$Request.Method = 'GET'
		$Request.Timeout = $TimeoutSec * 1000
		$Request.ReadWriteTimeout = $TimeoutSec * 1000
		$Request.UserAgent = 'zapret2-one-tap'
		if ($Request -is [Net.HttpWebRequest]) {
			$Request.AllowAutoRedirect = $true
			$Request.MaximumAutomaticRedirections = 3
		}
		$Response = $Request.GetResponse()
		$StatusCode = 'OK'
		if ($Response -is [Net.HttpWebResponse]) {
			$StatusCode = [int]$Response.StatusCode
		}
		return [pscustomobject]@{
			Ok = $true
			Url = $Url
			Detail = "HTTP $StatusCode"
		}
	} catch {
		$Response = Get-HttpResponseFromException $_.Exception
		if ($Response) {
			$StatusCode = 'response'
			try {
				$StatusCode = [int]$Response.StatusCode
			} catch {
			}
			return [pscustomobject]@{
				Ok = $true
				Url = $Url
				Detail = "HTTP $StatusCode"
			}
		}
		return [pscustomobject]@{
			Ok = $false
			Url = $Url
			Detail = $_.Exception.Message
		}
	} finally {
		if ($Response) {
			try {
				$Response.Close()
			} catch {
			}
		}
	}
}

function Test-ConnectivityTargets {
	$TimeoutSec = Get-EnvInt 'ZAPRET2_PROBE_TIMEOUT_SEC' 6
	$TargetResults = @()

	foreach ($Target in Get-ConnectivityTargets) {
		Info "Testing $($Target.Name)"
		$UrlResults = @()
		$TargetOk = $true
		foreach ($Url in $Target.Urls) {
			$UrlResult = Test-UrlReachable $Url $TimeoutSec
			$UrlResults += $UrlResult
			if (-not $UrlResult.Ok) {
				$TargetOk = $false
			}
		}
		$TargetResults += [pscustomobject]@{
			Name = $Target.Name
			Ok = $TargetOk
			Urls = @($UrlResults)
		}
	}

	$Ok = $true
	foreach ($TargetResult in $TargetResults) {
		if (-not $TargetResult.Ok) {
			$Ok = $false
			break
		}
	}

	$Report = [pscustomobject]@{
		Ok = $Ok
		CheckedAt = (Get-Date -Format s)
		Targets = @($TargetResults)
	}
	$Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ProbeReportFile -Encoding ASCII
	return $Report
}

function Start-Winws2Runner {
	param(
		[Parameter(Mandatory = $true)][string]$Exe,
		[Parameter(Mandatory = $true)][string]$StrategyName
	)

	Write-RunConfig $Exe $StrategyName
	if ($NoService) {
		Stop-Winws2
		Info 'Config saved. Starting winws2 in a minimized process.'
		& (Join-Path $ScriptDir 'start_windows.ps1')
	} else {
		Install-Winws2Service $Exe
	}
}

function Invoke-StrategySearch {
	param([Parameter(Mandatory = $true)][string]$Exe)

	$Candidates = @(Get-StrategyCandidates)
	$DelaySec = Get-EnvInt 'ZAPRET2_PROBE_START_DELAY_SEC' 4

	foreach ($Candidate in $Candidates) {
		Info "Trying strategy: $($Candidate.Name)"
		Save-StrategyCandidate $Candidate
		try {
			Start-Winws2Runner $Exe $Candidate.Name
			Start-Sleep -Seconds $DelaySec
			$Report = Test-ConnectivityTargets
			if ($Report.Ok) {
				Info "Strategy selected: $($Candidate.Name)"
				return
			}
			$FailedDetails = @($Report.Targets | Where-Object { -not $_.Ok } | ForEach-Object {
				$TargetName = $_.Name
				$FailedUrls = @($_.Urls | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Url) ($($_.Detail))" })
				if ($FailedUrls.Count -gt 0) {
					"$TargetName`: $($FailedUrls -join '; ')"
				} else {
					$TargetName
				}
			})
			Write-Warning "Strategy $($Candidate.Name) failed connectivity test: $($FailedDetails -join ' | ')"
		} catch {
			Write-Warning "Strategy $($Candidate.Name) failed to start or test: $($_.Exception.Message)"
		}
	}

	Stop-Winws2
	throw "No built-in Windows strategy passed general web plus YouTube/Telegram/Discord connectivity tests. Service was stopped to keep normal connectivity. See $ProbeReportFile"
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
		Info 'Windows runtime bundle is not present in this checkout. Normal launch will try to download it automatically.'
	}
	exit 0
}

if (-not (Test-Admin)) {
	Write-Error 'Administrator rights are required. Start windows\one_tap_windows.cmd.'
	exit 1
}
if (-not $Exe -or -not $RuntimeOk) {
	if (-not $NoDownload) {
		$Exe = Install-WindowsRuntimeFromRelease
		$RuntimeOk = Test-RuntimeFiles $Exe
	}
}
if (-not $Exe -or -not $RuntimeOk) {
	throw 'Windows binaries are not ready. Automatic download failed or was disabled. Put winws2.exe, cygwin1.dll, WinDivert.dll and WinDivert*.sys into binaries\windows-x86_64 or binaries\windows-x86, or build Windows artifacts from docs\compile.'
}

if ($NoProbe) {
	if ($ResetStrategy -or -not (Test-Path -LiteralPath $StrategyFile)) {
		Write-DiscordHostlist
		Write-TargetHostlist
		Save-StrategyCandidate (New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines (Get-TargetHostlistArg)))
	}
	$StrategyName = 'manual'
	if (Test-Path -LiteralPath $StrategyNameFile) {
		$StrategyName = Get-Content -LiteralPath $StrategyNameFile -TotalCount 1
	}
	Start-Winws2Runner $Exe $StrategyName
} else {
	Invoke-StrategySearch $Exe
}

Info "Saved config: $ConfigFile"
Info "Saved strategy: $StrategyFile"
Info "Connectivity report: $ProbeReportFile"
