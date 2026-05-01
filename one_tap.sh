#!/bin/sh

# One-tap bootstrap for zapret2.
# The script is intentionally non-interactive: it detects the local runtime,
# writes a persistent config, installs/start services where supported, and
# reuses the saved config on later runs.

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR"; pwd)"
ZAPRET_BASE=${ZAPRET_BASE:-"$EXEDIR"}
ZAPRET_TARGET=${ZAPRET_TARGET:-/opt/zapret2}
ZAPRET_RW=${ZAPRET_RW:-"$ZAPRET_BASE"}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-"$ZAPRET_RW/config"}
ZAPRET_CONFIG_DEFAULT="$ZAPRET_BASE/config.default"
IPSET_DIR="$ZAPRET_BASE/ipset"

ONE_TAP_AUTOSCAN=${ONE_TAP_AUTOSCAN:-1}
ONE_TAP_FORCE_SCAN=${ONE_TAP_FORCE_SCAN:-0}
ONE_TAP_SCANLEVEL=${ONE_TAP_SCANLEVEL:-standard}
ONE_TAP_DOMAINS=${ONE_TAP_DOMAINS:-${DOMAINS:-rutracker.org}}
ONE_TAP_REPEATS=${ONE_TAP_REPEATS:-1}
ONE_TAP_ENABLE_HTTP3=${ONE_TAP_ENABLE_HTTP3:-1}
ONE_TAP_STATE_DIR=${ONE_TAP_STATE_DIR:-"$ZAPRET_RW/one_tap"}
BATCH=1

exitp()
{
	exit "$1"
}

log()
{
	printf '%s\n' "$*"
}

die()
{
	log "ERROR: $*"
	exit 1
}

ensure_config()
{
	[ -f "$ZAPRET_CONFIG" ] && return
	[ -f "$ZAPRET_CONFIG_DEFAULT" ] || die "config.default not found"
	local d
	d="$(dirname "$ZAPRET_CONFIG")"
	[ -d "$d" ] || mkdir -p "$d"
	cp "$ZAPRET_CONFIG_DEFAULT" "$ZAPRET_CONFIG"
}

ensure_default_files()
{
	mkdir -p "$ZAPRET_RW/ipset"
	[ -f "$ZAPRET_RW/ipset/zapret-hosts-user-exclude.txt" ] ||
		cp "$ZAPRET_BASE/ipset/zapret-hosts-user-exclude.txt.default" "$ZAPRET_RW/ipset/zapret-hosts-user-exclude.txt"
	[ -f "$ZAPRET_RW/ipset/zapret-hosts-user.txt" ] ||
		printf '%s\n' nonexistent.domain >"$ZAPRET_RW/ipset/zapret-hosts-user.txt"
	[ -f "$ZAPRET_RW/ipset/zapret-hosts-user-ipban.txt" ] ||
		: >"$ZAPRET_RW/ipset/zapret-hosts-user-ipban.txt"
}

copy_self_to_target()
{
	[ "$(get_dir_inode "$EXEDIR")" = "$(get_dir_inode "$ZAPRET_TARGET" 2>/dev/null)" ] 2>/dev/null && return

	[ "$(id -u)" = 0 ] || return

	log "* installing project files to $ZAPRET_TARGET"
	stop_service_quiet
	local b
	b="$(dirname "$ZAPRET_TARGET")"
	[ -d "$b" ] || mkdir -p "$b"
	[ -d "$ZAPRET_TARGET" ] || mkdir -p "$ZAPRET_TARGET"

	local keep
	keep="${TMPDIR:-/tmp}/zapret2-one-tap-keep-$$"
	rm -rf "$keep"
	mkdir -p "$keep"
	[ -f "$ZAPRET_TARGET/config" ] && cp -p "$ZAPRET_TARGET/config" "$keep/config"
	[ -d "$ZAPRET_TARGET/ipset" ] && cp -Rp "$ZAPRET_TARGET/ipset" "$keep/ipset"
	[ -d "$ZAPRET_TARGET/init.d/sysv/custom.d" ] && {
		mkdir -p "$keep/init.d/sysv"
		cp -Rp "$ZAPRET_TARGET/init.d/sysv/custom.d" "$keep/init.d/sysv/custom.d"
	}
	[ -d "$ZAPRET_TARGET/init.d/openwrt/custom.d" ] && {
		mkdir -p "$keep/init.d/openwrt"
		cp -Rp "$ZAPRET_TARGET/init.d/openwrt/custom.d" "$keep/init.d/openwrt/custom.d"
	}

	(cd "$EXEDIR" && tar -cf - .) | (cd "$ZAPRET_TARGET" && tar -xf -)

	[ -f "$keep/config" ] && cp -p "$keep/config" "$ZAPRET_TARGET/config"
	[ -d "$keep/ipset" ] && {
		rm -rf "$ZAPRET_TARGET/ipset"
		cp -Rp "$keep/ipset" "$ZAPRET_TARGET/ipset"
	}
	[ -d "$keep/init.d/sysv/custom.d" ] && {
		mkdir -p "$ZAPRET_TARGET/init.d/sysv"
		rm -rf "$ZAPRET_TARGET/init.d/sysv/custom.d"
		cp -Rp "$keep/init.d/sysv/custom.d" "$ZAPRET_TARGET/init.d/sysv/custom.d"
	}
	[ -d "$keep/init.d/openwrt/custom.d" ] && {
		mkdir -p "$ZAPRET_TARGET/init.d/openwrt"
		rm -rf "$ZAPRET_TARGET/init.d/openwrt/custom.d"
		cp -Rp "$keep/init.d/openwrt/custom.d" "$ZAPRET_TARGET/init.d/openwrt/custom.d"
	}
	rm -rf "$keep"

	chmod 755 "$ZAPRET_TARGET/one_tap.sh" "$ZAPRET_TARGET/install_bin.sh" \
		"$ZAPRET_TARGET/blockcheck2.sh" "$ZAPRET_TARGET/install_easy.sh" \
		"$ZAPRET_TARGET/uninstall_easy.sh" 2>/dev/null

	log "* continuing from $ZAPRET_TARGET"
	exec "$ZAPRET_TARGET/one_tap.sh"
}

config_set()
{
	local name="$1" value="$2"
	eval "$name=\$value"
	write_config_var "$name"
}

detect_ipv6()
{
	if exists ping6 && ping6 -c 1 -w 1 2a02:6b8::feed:0ff >/dev/null 2>/dev/null; then
		DISABLE_IPV6=0
	elif ping -6 -c 1 -W 1 2a02:6b8::feed:0ff >/dev/null 2>/dev/null; then
		DISABLE_IPV6=0
	else
		DISABLE_IPV6=1
	fi
	config_set DISABLE_IPV6 "$DISABLE_IPV6"
}

install_runtime_prerequisites()
{
	[ "$ONE_TAP_SKIP_PREREQ" = 1 ] && return

	case "$SYSTEM" in
		openwrt)
			check_prerequisites_openwrt
			;;
		systemd|openrc|linux)
			check_prerequisites_linux
			;;
	esac
}

try_install_build_prerequisites_linux()
{
	[ "$UNAME" = Linux ] || return 1
	[ "$ONE_TAP_INSTALL_BUILD_DEPS" = 0 ] && return 1

	local pkgs=
	if exists apt-get; then
		pkgs="make gcc pkg-config zlib1g-dev libcap-dev libnetfilter-queue-dev libmnl-dev libluajit2-5.1-dev"
		[ "$SYSTEM" = systemd ] && pkgs="$pkgs libsystemd-dev"
		apt-get update && apt-get install -y --no-install-recommends $pkgs
	elif exists dnf; then
		pkgs="make gcc pkgconf-pkg-config zlib-devel libcap-devel libnetfilter_queue-devel libmnl-devel luajit-devel"
		[ "$SYSTEM" = systemd ] && pkgs="$pkgs systemd-devel"
		dnf -y install $pkgs
	elif exists yum; then
		pkgs="make gcc pkgconfig zlib-devel libcap-devel libnetfilter_queue-devel libmnl-devel luajit-devel"
		[ "$SYSTEM" = systemd ] && pkgs="$pkgs systemd-devel"
		yum -y install $pkgs
	elif exists pacman; then
		pacman --noconfirm -Syu make gcc pkgconf zlib libcap libnetfilter_queue libmnl luajit
	elif exists zypper; then
		pkgs="make gcc pkg-config zlib-devel libcap-devel libnetfilter_queue-devel libmnl-devel luajit-devel"
		[ "$SYSTEM" = systemd ] && pkgs="$pkgs systemd-devel"
		zypper --non-interactive install $pkgs
	else
		return 1
	fi
}

ensure_binaries()
{
	log "* checking binaries"
	if sh "$ZAPRET_BASE/install_bin.sh"; then
		return
	fi

	exists make || die "compatible binaries not found and make is absent"

	log "* trying to build from source"
	local target=
	[ "$SYSTEM" = systemd ] && target=systemd
	if ! CFLAGS="${CFLAGS:+$CFLAGS }-O2" make -C "$ZAPRET_BASE" $target; then
		log "* build failed, trying to install build dependencies"
		try_install_build_prerequisites_linux || true
		CFLAGS="${CFLAGS:+$CFLAGS }-O2" make -C "$ZAPRET_BASE" $target || die "could not build binaries"
	fi
	sh "$ZAPRET_BASE/install_bin.sh" || die "built binaries are not compatible with this system"
}

sanitize_strategy()
{
	printf '%s\n' "$1" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ *//' -e 's/ *$//'
}

extract_strategy()
{
	# $1 - blockcheck log, $2 - test name regexp
	awk -v test="$2" '
		$0 ~ ("^" test " ipv[46] ") && index($0, " : nfqws2 ") {
			sub(/^.* : nfqws2 /, "")
			print
			exit
		}
	' "$1"
}

build_opt_from_scan()
{
	# $1 - blockcheck log
	local http tls tls13 quic opt tcp_ports udp_ports

	http="$(sanitize_strategy "$(extract_strategy "$1" curl_test_http)")"
	tls="$(sanitize_strategy "$(extract_strategy "$1" curl_test_https_tls12)")"
	tls13="$(sanitize_strategy "$(extract_strategy "$1" curl_test_https_tls13)")"
	quic="$(sanitize_strategy "$(extract_strategy "$1" curl_test_http3)")"
	[ -n "$tls" ] || tls="$tls13"

	[ -n "$http" ] && {
		opt="${opt:+$opt --new }--filter-tcp=80 --filter-l7=http <HOSTLIST> $http"
		tcp_ports=80
	}
	[ -n "$tls" ] && {
		opt="${opt:+$opt --new }--filter-tcp=443 --filter-l7=tls <HOSTLIST> $tls"
		tcp_ports="${tcp_ports:+$tcp_ports,}443"
	}
	[ -n "$quic" ] && {
		opt="${opt:+$opt --new }--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> $quic"
		udp_ports=443
	}

	[ -n "$opt" ] || return 1

	config_set NFQWS2_OPT "$opt"
	config_set NFQWS2_PORTS_TCP "${tcp_ports:-443}"
	config_set NFQWS2_PORTS_UDP "$udp_ports"
	return 0
}

run_autoscan()
{
	[ "$ONE_TAP_AUTOSCAN" = 1 ] || return 1

	mkdir -p "$ONE_TAP_STATE_DIR"
	local logf="$ONE_TAP_STATE_DIR/blockcheck.log"
	log "* running automatic strategy scan"
	log "  domains: $ONE_TAP_DOMAINS"
	log "  scan level: $ONE_TAP_SCANLEVEL"

	stop_service_quiet
	if BATCH=1 \
		DOMAINS="$ONE_TAP_DOMAINS" \
		SCANLEVEL="$ONE_TAP_SCANLEVEL" \
		REPEATS="$ONE_TAP_REPEATS" \
		ENABLE_HTTP=1 \
		ENABLE_HTTPS_TLS12=1 \
		ENABLE_HTTPS_TLS13=0 \
		ENABLE_HTTP3="$ONE_TAP_ENABLE_HTTP3" \
		sh "$ZAPRET_BASE/blockcheck2.sh" >"$logf" 2>&1
	then
		log "* blockcheck finished"
	else
		log "* blockcheck returned non-zero, trying to use partial results"
	fi

	if build_opt_from_scan "$logf"; then
		config_set ONE_TAP_LAST_SCAN_LOG "$logf"
		config_set ONE_TAP_LAST_SCAN_LEVEL "$ONE_TAP_SCANLEVEL"
		config_set ONE_TAP_LAST_SCAN_DOMAINS "$ONE_TAP_DOMAINS"
		return 0
	fi

	log "* no working strategy was extracted from blockcheck"
	return 1
}

configure_base_defaults()
{
	log "* writing automatic config"
	get_fwtype
	[ "$FWTYPE" = unsupported ] && die "unsupported firewall type"
	config_set FWTYPE "$FWTYPE"
	detect_ipv6
	config_set NFQWS2_ENABLE 1
	config_set MODE_FILTER autohostlist
	config_set GETLIST ""
	config_set INIT_APPLY_FW 1
	config_set FLOWOFFLOAD donttouch
}

configure_strategy_defaults()
{
	if [ "$ONE_TAP_FORCE_SCAN" = 1 ] || [ "$ONE_TAP_CONFIGURED" != 1 ] || [ -z "$NFQWS2_OPT" ]; then
		run_autoscan || log "* keeping fallback NFQWS2_OPT from config.default"
	fi

	config_set ONE_TAP_CONFIGURED 1
	config_set ONE_TAP_VERSION 1
	config_set ONE_TAP_LAST_RUN "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
}

download_lists_quiet()
{
	[ -n "$GETLIST" ] || return
	[ -x "$IPSET_DIR/$GETLIST" ] || return
	log "* downloading lists with $GETLIST"
	"$IPSET_DIR/clear_lists.sh"
	"$IPSET_DIR/$GETLIST"
}

install_service()
{
	case "$SYSTEM" in
		systemd)
			local systemd_dir=/lib/systemd
			[ -d "$systemd_dir" ] || systemd_dir=/usr/lib/systemd
			[ -d "$systemd_dir/system" ] || die "systemd unit directory not found"
			sed "s|/opt/zapret2|$ZAPRET_BASE|g" "$ZAPRET_BASE/init.d/systemd/zapret2.service" >"$systemd_dir/system/zapret2.service"
			sed "s|/opt/zapret2|$ZAPRET_BASE|g" "$ZAPRET_BASE/init.d/systemd/zapret2-list-update.service" >"$systemd_dir/system/zapret2-list-update.service"
			cp -f "$ZAPRET_BASE/init.d/systemd/zapret2-list-update.timer" "$systemd_dir/system"
			systemctl daemon-reload
			systemctl enable zapret2
			systemctl enable zapret2-list-update.timer
			systemctl start zapret2-list-update.timer
			;;
		openwrt)
			ln -fs "$ZAPRET_BASE/init.d/openwrt/zapret2" /etc/init.d/zapret2
			/etc/init.d/zapret2 enable
			ln -fs "$ZAPRET_BASE/init.d/openwrt/90-zapret2" /etc/hotplug.d/iface/90-zapret2 2>/dev/null || true
			ln -fs "$ZAPRET_BASE/init.d/openwrt/firewall.zapret2" /etc/firewall.zapret2 2>/dev/null || true
			;;
		openrc)
			ln -fs "$ZAPRET_BASE/init.d/openrc/zapret2" /etc/init.d/zapret2
			rc-update add zapret2 default
			;;
		linux)
			ln -fs "$ZAPRET_BASE/init.d/sysv/zapret2" /etc/init.d/zapret2 2>/dev/null || true
			if exists update-rc.d; then
				update-rc.d zapret2 defaults
			elif exists chkconfig; then
				chkconfig zapret2 on
			fi
			;;
	esac
}

stop_service_quiet()
{
	case "$SYSTEM" in
		systemd)
			systemctl stop zapret2 >/dev/null 2>&1 || true
			;;
		openwrt|openrc|linux)
			[ -x /etc/init.d/zapret2 ] && /etc/init.d/zapret2 stop >/dev/null 2>&1 || true
			[ -x "$ZAPRET_BASE/init.d/sysv/zapret2" ] && "$ZAPRET_BASE/init.d/sysv/zapret2" stop >/dev/null 2>&1 || true
			;;
	esac
}

start_service()
{
	log "* starting zapret2"
	case "$SYSTEM" in
		systemd)
			systemctl restart zapret2
			;;
		openwrt)
			/etc/init.d/zapret2 restart
			if exists fw4; then
				fw4 -q restart || true
			elif exists fw3; then
				fw3 -q restart || true
			fi
			;;
		openrc|linux)
			if [ -x /etc/init.d/zapret2 ]; then
				/etc/init.d/zapret2 restart
			else
				"$ZAPRET_BASE/init.d/sysv/zapret2" restart
			fi
			;;
	esac
}

main()
{
	ensure_config
	. "$ZAPRET_CONFIG"
	. "$ZAPRET_BASE/common/base.sh"
	. "$ZAPRET_BASE/common/elevate.sh"
	. "$ZAPRET_BASE/common/fwtype.sh"
	. "$ZAPRET_BASE/common/dialog.sh"
	. "$ZAPRET_BASE/common/installer.sh"
	. "$ZAPRET_BASE/common/ipt.sh"
	. "$ZAPRET_BASE/common/nft.sh"
	. "$ZAPRET_BASE/common/virt.sh"
	. "$ZAPRET_BASE/common/list.sh"

	umask 0022
	fix_sbin_path
	fsleep_setup
	check_system accept_unknown_rc

	case "$UNAME" in
		Linux)
			;;
		Darwin)
			die "one_tap.sh supports Linux/OpenWrt. For macOS diagnostics run: macos/one_tap_macos.sh --self-test"
			;;
		CYGWIN*)
			die "one_tap.sh supports Linux/OpenWrt. For Windows run: windows\\one_tap_windows.cmd"
			;;
		*)
			die "one_tap.sh supports Linux/OpenWrt only. Detected: $UNAME"
			;;
	esac
	require_root

	copy_self_to_target

	ZAPRET_BASE="$EXEDIR"
	ZAPRET_RW="$EXEDIR"
	ZAPRET_CONFIG="$EXEDIR/config"
	ZAPRET_CONFIG_DEFAULT="$EXEDIR/config.default"
	IPSET_DIR="$EXEDIR/ipset"
	ONE_TAP_STATE_DIR="$EXEDIR/one_tap"

	ensure_config
	ensure_default_files
	configure_base_defaults
	install_runtime_prerequisites
	ensure_binaries
	configure_strategy_defaults
	download_lists_quiet
	install_service
	start_service

	log
	log "Done. Saved config: $ZAPRET_CONFIG"
	log "Next run will reuse it. To rescan: ONE_TAP_FORCE_SCAN=1 $EXEDIR/one_tap.sh"
}

main "$@"
