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
$TelegramIpsetFile = Join-Path $StateDir 'telegram-ipset.txt'
$DefaultReleaseRepos = @('fastyrer/zapret2_OneTap', 'bol-van/zapret2')
$OneTapWindowsVersion = '2026-05-02.3'

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

Info "Windows script version: $OneTapWindowsVersion"

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

function Get-TelegramIpsets {
	return @(
		'91.108.4.0/22',
		'91.108.8.0/22',
		'91.108.12.0/22',
		'91.108.16.0/22',
		'91.108.56.0/22',
		'149.154.160.0/22',
		'149.154.164.0/22',
		'149.154.168.0/22',
		'149.154.172.0/22'
	)
}

function Write-TelegramIpset {
	$Ips = Get-TelegramIpsets
	New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
	Set-Content -LiteralPath $TelegramIpsetFile -Value $Ips -Encoding ASCII
}

function Get-TelegramIpsetArg {
	return '--ipset="' + (To-ZapretPath $TelegramIpsetFile) + '"'
}

function Write-TargetHostlist {
	$Hosts = @(
		'youtube.com',
		'youtu.be',
		'youtube-nocookie.com',
		'googlevideo.com',
		'ytimg.com',
		'ggpht.com',
		'www.youtube.com',
		'm.youtube.com',
		'i.ytimg.com',
		's.ytimg.com',
		'yt3.ggpht.com',
		'youtubei.googleapis.com',
		'youtube.googleapis.com',
		'telegram.org',
		'telegram.me',
		't.me',
		'telegra.ph',
		'tdesktop.com',
		'telegram-cdn.org',
		'api.telegram.org',
		'web.telegram.org',
		'desktop.telegram.org',
		'updates.tdesktop.com',
		'telesco.pe'
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

function Get-QuicDesyncArg {
	param(
		[string]$Blob = 'fake_default_quic',
		[int]$Repeats = 11
	)
	if (Test-EnvFlag 'ZAPRET2_KEEP_QUIC') {
		return "--lua-desync=fake:blob=${Blob}:repeats=$Repeats"
	}
	return '--lua-desync=drop'
}

function New-QuicStrategyLine {
	param(
		[string]$FilterArg = '',
		[string]$Blob = 'fake_default_quic'
	)
	$FilterPart = ''
	if ($FilterArg) {
		$FilterPart = ' ' + $FilterArg
	}
	return '--filter-udp=443 --filter-l7=quic' + $FilterPart + ' --payload=quic_initial ' + (Get-QuicDesyncArg -Blob $Blob) + ' --new'
}

function New-TelegramMtprotoStrategyLine {
	param([Parameter(Mandatory = $true)][string]$IpsetArg)

	return '--filter-tcp=443,5222 --filter-l7=mtproto ' + $IpsetArg + ' --out-range=-d10 --payload=mtproto_initial --lua-desync=fake:blob=0x00000000:tcp_md5:repeats=2 --lua-desync=multisplit:pos=2 --new'
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
		if ($IsWebProfile -and ($Trim -notmatch '--hostlist=') -and ($Trim -notmatch '--ipset=')) {
			return $false
		}
	}
	return $true
}

function Test-StrategyNeedsQuicFallbackRefresh {
	param([Parameter(Mandatory = $true)][string[]]$Lines)

	if (Test-EnvFlag 'ZAPRET2_KEEP_QUIC') {
		return $false
	}
	foreach ($Line in $Lines) {
		$Trim = $Line.Trim()
		if (($Trim -match '--filter-l7=[^ ]*quic') -and ($Trim -match '--lua-desync=fake:') -and ($Trim -notmatch '--lua-desync=drop')) {
			return $true
		}
	}
	return $false
}

function Get-StrategyStorageName {
	param([string]$Name)

	$Clean = ''
	if ($Name) {
		$Clean = $Name.Trim() -replace '[^A-Za-z0-9_.-]', '_'
	}
	while ($Clean -match '^saved-(.+)$') {
		$Clean = $Matches[1]
	}
	if ($Clean.Length -eq 0) {
		return 'custom'
	}
	return $Clean
}

function Get-SavedCandidateName {
	$Name = 'saved'
	if (Test-Path -LiteralPath $StrategyNameFile) {
		$StoredName = Get-StrategyStorageName (Get-Content -LiteralPath $StrategyNameFile -TotalCount 1)
		if (($StoredName.Length -gt 0) -and ($StoredName -ne 'custom') -and ($StoredName -ne 'saved')) {
			$Name = 'saved-' + $StoredName
		}
	}
	return $Name
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
	param(
		[string]$HostlistArg = '',
		[string]$TelegramIpsetArg = ''
	)

	$HostlistPart = ''
	if ($HostlistArg) {
		$HostlistPart = ' ' + $HostlistArg
	}
	$Lines = @(
		('--filter-tcp=80 --filter-l7=http' + $HostlistPart + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --lua-desync=fakedsplit:ip_autottl=-2,3-20:ip6_autottl=-2,3-20:tcp_md5 --new'),
		('--filter-tcp=443 --filter-l7=tls' + $HostlistPart + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 --lua-desync=multidisorder:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $HostlistArg),
		'--filter-l7=wireguard,stun,discord --payload=wireguard_initiation,wireguard_cookie,stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
	)
	if ($TelegramIpsetArg) {
		$Lines += (New-TelegramMtprotoStrategyLine -IpsetArg $TelegramIpsetArg)
	}
	return $Lines
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
	Write-TelegramIpset
	$TargetHostlist = Get-TargetHostlistArg
	$DiscordHostlist = Get-DiscordHostlistArg
	$TelegramIpset = Get-TelegramIpsetArg
	$TelegramMtproto = New-TelegramMtprotoStrategyLine -IpsetArg $TelegramIpset
	$AllowBroadStrategies = Test-EnvFlag 'ZAPRET2_ALLOW_BROAD_STRATEGIES'
	$Candidates = New-Object System.Collections.Generic.List[object]
	if ((Test-Path -LiteralPath $StrategyFile) -and (-not $ResetStrategy)) {
		$Saved = @(Get-Content -LiteralPath $StrategyFile | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') })
		if ($Saved.Count -gt 0) {
			$SavedName = Get-SavedCandidateName
			if (Test-StrategyNeedsQuicFallbackRefresh $Saved) {
				Write-Warning "Skipping saved strategy $SavedName because it keeps QUIC enabled; rebuilding a TCP-fallback strategy. Set ZAPRET2_KEEP_QUIC=1 to keep QUIC."
			} elseif ($AllowBroadStrategies -or (Test-StrategyIsTargetScoped $Saved)) {
				$Candidates.Add((New-StrategyCandidate $SavedName $Saved))
			} else {
				Write-Warning "Skipping saved broad strategy $SavedName because it can affect unrelated HTTPS sites. Set ZAPRET2_ALLOW_BROAD_STRATEGIES=1 to allow it."
			}
		}
	}

	$Candidates.Add((New-StrategyCandidate 'target-light-multisplit' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'target-md5-fake-multisplit' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2 --new'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'target-quic-md5-fake' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5:repeats=1 --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1 --lua-desync=multisplit:pos=2 --new'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'target-tls-timestamp-quic-fake' @(
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_ts=-1000 --new'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'target-syndata-multisplit' @(
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-google-fake' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,sni=www.google.com:repeats=11 --lua-desync=multidisorder:pos=1,midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $DiscordHostlist -Blob 'quic_google'),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-padencap' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid,padencap:repeats=4 --lua-desync=multidisorder:pos=1,midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $DiscordHostlist),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'discord-hostlist-syndata' @(
		('--filter-tcp=80 --filter-l7=http ' + $TargetHostlist + ' --out-range=-d10 --payload=http_req --lua-desync=multisplit:pos=method+2 --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $DiscordHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new'),
		('--filter-tcp=443 --filter-l7=tls ' + $TargetHostlist + ' --out-range=-d10 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld --new'),
		(New-QuicStrategyLine -FilterArg $DiscordHostlist),
		(New-QuicStrategyLine -FilterArg $TargetHostlist),
		'--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
		$TelegramMtproto
	)))
	$Candidates.Add((New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines $TargetHostlist $TelegramIpset)))

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
			(New-QuicStrategyLine)
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tls-timestamp-quic-fake' @(
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_ts=-1000 --new',
			(New-QuicStrategyLine)
		)))
		$Candidates.Add((New-StrategyCandidate 'broad-tls-syndata-multisplit' @(
			'--filter-tcp=443 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello --lua-desync=syndata:blob=fake_default_tls:tls_mod=rnd,dupsid,rndsni --lua-desync=multisplit:pos=midsld --new',
			(New-QuicStrategyLine)
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
	Set-Content -LiteralPath $StrategyNameFile -Value (Get-StrategyStorageName $Candidate.Name) -Encoding ASCII
}

function Get-StrategySnapshot {
	$HasStrategy = Test-Path -LiteralPath $StrategyFile
	$HasName = Test-Path -LiteralPath $StrategyNameFile
	$Lines = @()
	$Name = ''
	if ($HasStrategy) {
		$Lines = @(Get-Content -LiteralPath $StrategyFile)
	}
	if ($HasName) {
		$Name = Get-Content -LiteralPath $StrategyNameFile -TotalCount 1
	}
	return [pscustomobject]@{
		HasStrategy = $HasStrategy
		Lines = @($Lines)
		HasName = $HasName
		Name = $Name
	}
}

function Restore-StrategySnapshot {
	param([Parameter(Mandatory = $true)]$Snapshot)

	if ($Snapshot.HasStrategy) {
		Set-Content -LiteralPath $StrategyFile -Value $Snapshot.Lines -Encoding ASCII
	} elseif (Test-Path -LiteralPath $StrategyFile) {
		Remove-Item -LiteralPath $StrategyFile -Force
	}
	if ($Snapshot.HasName) {
		Set-Content -LiteralPath $StrategyNameFile -Value $Snapshot.Name -Encoding ASCII
	} elseif (Test-Path -LiteralPath $StrategyNameFile) {
		Remove-Item -LiteralPath $StrategyNameFile -Force
	}
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
	Write-TelegramIpset
	Save-StrategyCandidate (New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines (Get-TargetHostlistArg) (Get-TelegramIpsetArg)))
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
	Write-TelegramIpset
	Ensure-StrategyFile

	$Lines = New-Object System.Collections.Generic.List[string]
	$Lines.Add('--wf-tcp-out=80,443,5222')
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
			try {
				Stop-Service -Name $ServiceName -Force -ErrorAction Stop
			} catch {
				Write-Warning "Stop-Service failed: $($_.Exception.Message)"
				try {
					& sc.exe stop $ServiceName | Out-Host
				} catch {
					Write-Warning "sc.exe stop failed: $($_.Exception.Message)"
				}
			}
			try {
				$SvcAfterStop = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
				if ($SvcAfterStop) {
					$SvcAfterStop.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
				}
			} catch {
				Write-Warning "Service did not report stopped cleanly: $($_.Exception.Message)"
			}
		}
	}
	$Processes = @(Get-Process -Name winws2 -ErrorAction SilentlyContinue)
	if ($Processes.Count -gt 0) {
		Info "Stopping existing winws2 process"
		$Processes | Stop-Process -Force -ErrorAction SilentlyContinue
	}
	$SvcFinal = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($SvcFinal -and $SvcFinal.Status -ne 'Stopped') {
		Write-Warning "Service $ServiceName status is still $($SvcFinal.Status)."
	}
}

function Invoke-ScCommand {
	param([Parameter(Mandatory = $true)][string[]]$Arguments)

	$Output = & sc.exe @Arguments 2>&1
	$Output | Out-Host
	if ($LASTEXITCODE -ne 0) {
		throw "sc.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
	}
}

function Get-Winws2ServiceDiagnostics {
	$Lines = New-Object System.Collections.Generic.List[string]
	$Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($Svc) {
		$Lines.Add("service status: $($Svc.Status)")
	}
	if (Test-Path -LiteralPath $ArgsFile) {
		$Lines.Add("args file: $ArgsFile")
	}
	try {
		$Query = @(& sc.exe queryex $ServiceName 2>&1)
		if ($Query.Count -gt 0) {
			$Lines.Add('sc queryex: ' + (($Query | ForEach-Object { "$_" }) -join ' '))
		}
	} catch {
		$Lines.Add("sc queryex failed: $($_.Exception.Message)")
	}
	try {
		$Events = @(Get-WinEvent -FilterHashtable @{
			LogName = 'System'
			ProviderName = 'Service Control Manager'
			StartTime = (Get-Date).AddMinutes(-5)
		} -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object {
			($_.Message -match [regex]::Escape($ServiceName)) -or ($_.Message -match 'zapret2 winws2')
		} | Select-Object -First 5)
		if ($Events.Count -gt 0) {
			$EventText = @($Events | ForEach-Object {
				$Message = ($_.Message -replace '\s+', ' ').Trim()
				"[$($_.Id)] $Message"
			})
			$Lines.Add('recent SCM events: ' + ($EventText -join ' || '))
		}
	} catch {
		$Lines.Add("event log query failed: $($_.Exception.Message)")
	}
	if ($Lines.Count -eq 0) {
		return 'no service diagnostics available'
	}
	return ($Lines -join '; ')
}

function Install-Winws2Service {
	param([Parameter(Mandatory = $true)][string]$Exe)

	$ArgRef = '@"' + (To-ZapretPath $ArgsFile) + '"'
	$BinPath = '"' + $Exe + '" ' + $ArgRef

	Stop-Winws2
	$Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($Svc) {
		Info "Updating service $ServiceName"
		Invoke-ScCommand -Arguments @('config', $ServiceName, 'binPath=', $BinPath, 'start=', 'auto')
	} else {
		Info "Creating service $ServiceName"
		Invoke-ScCommand -Arguments @('create', $ServiceName, 'binPath=', $BinPath, 'start=', 'auto', 'DisplayName=', 'zapret2 winws2')
		Invoke-ScCommand -Arguments @('description', $ServiceName, 'zapret2 One Tap WinDivert runner')
	}

	Info "Starting service $ServiceName"
	try {
		Start-Service -Name $ServiceName -ErrorAction Stop
		$SvcStarted = Get-Service -Name $ServiceName -ErrorAction Stop
		$SvcStarted.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(10))
	} catch {
		$Diagnostics = Get-Winws2ServiceDiagnostics
		throw "Could not start service ${ServiceName}: $($_.Exception.Message). $Diagnostics"
	}
}

function Test-Winws2RunnerAlive {
	if ($NoService) {
		return (@(Get-Process -Name winws2 -ErrorAction SilentlyContinue).Count -gt 0)
	}
	$Svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	return ($Svc -and $Svc.Status -eq 'Running')
}

function Assert-Winws2RunnerAlive {
	param([Parameter(Mandatory = $true)][string]$Context)

	if (Test-Winws2RunnerAlive) {
		return
	}
	if ($NoService) {
		throw "winws2 process is not running after $Context"
	}
	$Diagnostics = Get-Winws2ServiceDiagnostics
	throw "Service $ServiceName is not running after $Context. $Diagnostics"
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

function Get-EnvList {
	param([Parameter(Mandatory = $true)][string]$Name)

	$Value = [Environment]::GetEnvironmentVariable($Name)
	if (-not $Value) {
		return @()
	}
	return @($Value -split '[,; ]+' | Where-Object { $_ -and $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() })
}

function New-ProbeUrl {
	param(
		[Parameter(Mandatory = $true)][string]$Url,
		[int[]]$OkStatus = @(200, 204),
		[switch]$AcceptAnyHttp,
		[int]$MinBytes = 0,
		[string]$ContainsText = ''
	)
	[pscustomobject]@{
		Url = $Url
		OkStatus = @($OkStatus)
		AcceptAnyHttp = [bool]$AcceptAnyHttp
		MinBytes = $MinBytes
		ContainsText = $ContainsText
	}
}

function New-ProbeTarget {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][object[]]$Urls,
		[int]$MinOkUrls = 0
	)
	$UrlSpecs = @()
	foreach ($Spec in $Urls) {
		if ($Spec -is [string]) {
			$UrlSpecs += (New-ProbeUrl -Url $Spec)
		} else {
			$UrlSpecs += $Spec
		}
	}
	$RequiredOkUrls = $MinOkUrls
	if ($RequiredOkUrls -le 0) {
		$RequiredOkUrls = $UrlSpecs.Count
	}
	if ($RequiredOkUrls -gt $UrlSpecs.Count) {
		$RequiredOkUrls = $UrlSpecs.Count
	}
	[pscustomobject]@{
		Name = $Name
		Urls = @($UrlSpecs)
		MinOkUrls = $RequiredOkUrls
	}
}

function Get-ConnectivityTargets {
	$Targets = @(
		(New-ProbeTarget -Name 'GeneralWeb' -Urls @(
			(New-ProbeUrl -Url 'https://example.com/' -MinBytes 500 -ContainsText 'Example Domain')
		) -MinOkUrls 1),
		(New-ProbeTarget -Name 'YouTube' -Urls @(
			(New-ProbeUrl -Url 'https://www.youtube.com/generate_204' -OkStatus @(204)),
			(New-ProbeUrl -Url 'https://www.youtube.com/' -MinBytes 2000),
			(New-ProbeUrl -Url 'https://www.youtube.com/robots.txt' -MinBytes 100),
			(New-ProbeUrl -Url 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg' -MinBytes 1000)
		) -MinOkUrls 3),
		(New-ProbeTarget -Name 'Telegram' -Urls @(
			(New-ProbeUrl -Url 'https://api.telegram.org' -MinBytes 20),
			(New-ProbeUrl -Url 'https://web.telegram.org/k/' -MinBytes 1000),
			(New-ProbeUrl -Url 'https://telegram.org/img/t_logo.png' -MinBytes 500)
		) -MinOkUrls 1),
		(New-ProbeTarget -Name 'Discord' -Urls @(
			(New-ProbeUrl -Url 'https://discord.com/api/v9/experiments' -MinBytes 20),
			(New-ProbeUrl -Url 'https://discord.com/app' -MinBytes 2000),
			(New-ProbeUrl -Url 'https://discord.com/api/v9/gateway' -MinBytes 20 -ContainsText 'gateway.discord.gg'),
			(New-ProbeUrl -Url 'https://gateway.discord.gg' -AcceptAnyHttp),
			(New-ProbeUrl -Url 'https://cdn.discordapp.com/embed/avatars/0.png' -MinBytes 500)
		) -MinOkUrls 4)
	)
	$RequestedTargets = Get-EnvList 'ZAPRET2_PROBE_TARGETS'
	if ($RequestedTargets.Count -gt 0) {
		$Wanted = @{}
		foreach ($TargetName in $RequestedTargets) {
			$Wanted[$TargetName.ToLowerInvariant()] = $true
		}
		$SelectedTargets = @($Targets | Where-Object { ($_.Name -eq 'GeneralWeb') -or $Wanted.ContainsKey($_.Name.ToLowerInvariant()) })
		if ($SelectedTargets.Count -gt 1) {
			return @($SelectedTargets)
		}
		Write-Warning "ZAPRET2_PROBE_TARGETS did not match any known target; using all probe targets."
	}
	return @($Targets)
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

function Read-ProbeBody {
	param(
		[Parameter(Mandatory = $true)]$Response,
		[Parameter(Mandatory = $true)][int]$MaxBytes
	)

	$Stream = $null
	$Memory = New-Object System.IO.MemoryStream
	try {
		$Stream = $Response.GetResponseStream()
		if ($Stream) {
			$Buffer = New-Object byte[] 8192
			while ($Memory.Length -lt $MaxBytes) {
				$Read = $Stream.Read($Buffer, 0, $Buffer.Length)
				if ($Read -le 0) {
					break
				}
				$Remaining = $MaxBytes - [int]$Memory.Length
				$ToWrite = [Math]::Min($Read, $Remaining)
				$Memory.Write($Buffer, 0, $ToWrite)
				if ($ToWrite -lt $Read) {
					break
				}
			}
		}
		$Bytes = $Memory.ToArray()
		return [pscustomobject]@{
			Bytes = $Bytes
			Length = $Bytes.Length
		}
	} finally {
		if ($Stream) {
			try {
				$Stream.Close()
			} catch {
			}
		}
		$Memory.Dispose()
	}
}

function Test-ProbeResponse {
	param(
		[Parameter(Mandatory = $true)]$Spec,
		[Parameter(Mandatory = $true)]$Response,
		[Parameter(Mandatory = $true)][int]$MaxBytes
	)

	$StatusCode = 0
	if ($Response -is [Net.HttpWebResponse]) {
		$StatusCode = [int]$Response.StatusCode
	}

	$NeedBody = (($Spec.MinBytes -gt 0) -or ($Spec.ContainsText -and $Spec.ContainsText.Length -gt 0))
	$Body = [pscustomobject]@{
		Bytes = [byte[]]@()
		Length = 0
	}
	if ($NeedBody) {
		$Body = Read-ProbeBody $Response $MaxBytes
	}
	$BytesRead = $Body.Length

	$Failures = @()
	if (-not $Spec.AcceptAnyHttp) {
		$OkStatuses = @($Spec.OkStatus)
		if (($OkStatuses.Count -gt 0) -and ($OkStatuses -notcontains $StatusCode)) {
			$Failures += "expected HTTP $($OkStatuses -join '/')"
		}
	}
	if (($Spec.MinBytes -gt 0) -and ($BytesRead -lt $Spec.MinBytes)) {
		$Failures += "expected at least $($Spec.MinBytes) bytes"
	}
	if ($Spec.ContainsText -and $Spec.ContainsText.Length -gt 0) {
		$BodyText = [Text.Encoding]::UTF8.GetString([byte[]]$Body.Bytes)
		if ($BodyText.IndexOf($Spec.ContainsText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
			$Failures += "expected text '$($Spec.ContainsText)'"
		}
	}

	$Detail = "HTTP $StatusCode"
	if ($NeedBody) {
		$Detail = "$Detail, $BytesRead bytes"
	}
	if ($Failures.Count -gt 0) {
		$Detail = "$Detail; $($Failures -join '; ')"
	}

	return [pscustomobject]@{
		Ok = ($Failures.Count -eq 0)
		Url = $Spec.Url
		Detail = $Detail
	}
}

function Test-UrlReachable {
	param(
		[Parameter(Mandatory = $true)]$Spec,
		[Parameter(Mandatory = $true)][int]$TimeoutSec,
		[Parameter(Mandatory = $true)][int]$MaxBytes
	)

	if ($Spec -is [string]) {
		$Spec = New-ProbeUrl -Url $Spec
	}
	$Url = $Spec.Url
	$Response = $null
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$Request = [Net.WebRequest]::Create($Url)
		$Request.Method = 'GET'
		$Request.Timeout = $TimeoutSec * 1000
		$Request.ReadWriteTimeout = $TimeoutSec * 1000
		$Request.UserAgent = 'zapret2-one-tap'
		if ($Request -is [Net.HttpWebRequest]) {
			$Request.Accept = '*/*'
			$Request.AllowAutoRedirect = $true
			$Request.MaximumAutomaticRedirections = 3
			try {
				$Request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
			} catch {
			}
		}
		$Response = $Request.GetResponse()
		return Test-ProbeResponse $Spec $Response $MaxBytes
	} catch {
		$Response = Get-HttpResponseFromException $_.Exception
		if ($Response) {
			return Test-ProbeResponse $Spec $Response $MaxBytes
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
	$MaxBytes = Get-EnvInt 'ZAPRET2_PROBE_MAX_BYTES' 262144
	$StrictProbes = Test-EnvFlag 'ZAPRET2_STRICT_PROBES'
	$TargetResults = @()

	foreach ($Target in Get-ConnectivityTargets) {
		Info "Testing $($Target.Name)"
		$UrlResults = @()
		foreach ($UrlSpec in $Target.Urls) {
			$UrlResult = Test-UrlReachable $UrlSpec $TimeoutSec $MaxBytes
			$UrlResults += $UrlResult
		}
		$OkUrls = @($UrlResults | Where-Object { $_.Ok }).Count
		$RequiredOkUrls = $Target.MinOkUrls
		if ($StrictProbes) {
			$RequiredOkUrls = @($Target.Urls).Count
		}
		$TargetOk = ($OkUrls -ge $RequiredOkUrls)
		$TargetResults += [pscustomobject]@{
			Name = $Target.Name
			Ok = $TargetOk
			OkUrls = $OkUrls
			RequiredOkUrls = $RequiredOkUrls
			TotalUrls = @($Target.Urls).Count
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
	$Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ProbeReportFile -Encoding UTF8
	return $Report
}

function Get-ConnectivityReportScore {
	param([Parameter(Mandatory = $true)]$Report)

	$Score = 0
	foreach ($Target in $Report.Targets) {
		if ($Target.Ok) {
			$Score += 1000
		}
		if ($Target.PSObject.Properties['OkUrls']) {
			$Score += [int]$Target.OkUrls
		}
	}
	return $Score
}

function Test-ConnectivityReportCanBeKept {
	param([Parameter(Mandatory = $true)]$Report)

	$GeneralWeb = @($Report.Targets | Where-Object { $_.Name -eq 'GeneralWeb' } | Select-Object -First 1)
	if (($GeneralWeb.Count -eq 0) -or (-not $GeneralWeb[0].Ok)) {
		return $false
	}
	$PassedTargetServices = @($Report.Targets | Where-Object { ($_.Name -ne 'GeneralWeb') -and $_.Ok })
	return ($PassedTargetServices.Count -gt 0)
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
	$PreviousStrategy = $null
	$BestCandidate = $null
	$BestReport = $null
	$BestReportScore = -1
	if (-not $ResetStrategy) {
		$PreviousStrategy = Get-StrategySnapshot
	}

	foreach ($Candidate in $Candidates) {
		Info "Trying strategy: $($Candidate.Name)"
		Save-StrategyCandidate $Candidate
		try {
			Start-Winws2Runner $Exe $Candidate.Name
			Start-Sleep -Seconds $DelaySec
			Assert-Winws2RunnerAlive "starting strategy $($Candidate.Name)"
			$Report = Test-ConnectivityTargets
			$ReportScore = Get-ConnectivityReportScore $Report
			if ($ReportScore -gt $BestReportScore) {
				$BestCandidate = $Candidate
				$BestReport = $Report
				$BestReportScore = $ReportScore
			}
			if ($Report.Ok) {
				Start-Sleep -Seconds 2
				Assert-Winws2RunnerAlive "successful connectivity test for $($Candidate.Name)"
				Info "Strategy selected: $($Candidate.Name)"
				return
			}
			$FailedDetails = @($Report.Targets | Where-Object { -not $_.Ok } | ForEach-Object {
				$TargetName = $_.Name
				$TargetSummary = "$($_.OkUrls)/$($_.RequiredOkUrls) required URLs passed"
				$FailedUrls = @($_.Urls | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.Url) ($($_.Detail))" })
				if ($FailedUrls.Count -gt 0) {
					"$TargetName ($TargetSummary): $($FailedUrls -join '; ')"
				} else {
					$TargetName
				}
			})
			Write-Warning "Strategy $($Candidate.Name) failed connectivity test: $($FailedDetails -join ' | ')"
		} catch {
			Write-Warning "Strategy $($Candidate.Name) failed to start or test: $($_.Exception.Message)"
		}
	}

	if ((-not (Test-EnvFlag 'ZAPRET2_STRICT_PROBES')) -and $BestCandidate -and $BestReport -and (Test-ConnectivityReportCanBeKept $BestReport)) {
		$PassedTargets = @($BestReport.Targets | Where-Object { $_.Ok } | ForEach-Object { $_.Name })
		$FailedTargets = @($BestReport.Targets | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
		Write-Warning "No strategy passed every selected probe target. Keeping best degraded strategy $($BestCandidate.Name): passed $($PassedTargets -join ', '); failed $($FailedTargets -join ', '). Set ZAPRET2_STRICT_PROBES=1 to require the old all-probes-pass behavior."
		Save-StrategyCandidate $BestCandidate
		try {
			Start-Winws2Runner $Exe $BestCandidate.Name
			Start-Sleep -Seconds $DelaySec
			Assert-Winws2RunnerAlive "degraded fallback strategy $($BestCandidate.Name)"
			$BestReport | Add-Member -NotePropertyName SelectedStrategy -NotePropertyValue $BestCandidate.Name -Force
			$BestReport | Add-Member -NotePropertyName Degraded -NotePropertyValue $true -Force
			$BestReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ProbeReportFile -Encoding UTF8
			return
		} catch {
			Write-Warning "Best degraded strategy $($BestCandidate.Name) failed to restart: $($_.Exception.Message)"
		}
	}

	if (Test-EnvFlag 'ZAPRET2_KEEP_FAILED_STRATEGY') {
		if (Test-Winws2RunnerAlive) {
			Write-Warning 'No strategy passed all probes, but ZAPRET2_KEEP_FAILED_STRATEGY=1 is set. Leaving the last started strategy running for manual app testing.'
			return
		}
		Write-Warning 'ZAPRET2_KEEP_FAILED_STRATEGY=1 is set, but winws2 is not running; stopping as usual.'
	}

	Stop-Winws2
	if ($PreviousStrategy) {
		Restore-StrategySnapshot $PreviousStrategy
		if ($PreviousStrategy.HasStrategy) {
			$RestoredName = Get-StrategyStorageName $PreviousStrategy.Name
			Write-Warning "Restored previous saved strategy after failed search: $RestoredName"
		}
	} else {
		$EmptyStrategy = [pscustomobject]@{
			HasStrategy = $false
			Lines = @()
			HasName = $false
			Name = ''
		}
		Restore-StrategySnapshot $EmptyStrategy
	}
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
		Write-TelegramIpset
		Save-StrategyCandidate (New-StrategyCandidate 'target-full-default' (Get-DefaultStrategyLines (Get-TargetHostlistArg) (Get-TelegramIpsetArg)))
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
