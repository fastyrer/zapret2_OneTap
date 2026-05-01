#!/bin/sh

# macOS utility launcher for zapret2.
# Transparent DPI bypass is intentionally not started here: current macOS
# versions do not expose the packet divert mechanism used by zapret2's core.

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR"; pwd)"
ZAPRET_BASE="$(cd "$EXEDIR/.."; pwd)"
STATE_DIR="${ONE_TAP_MACOS_STATE_DIR:-"$EXEDIR/state"}"
SELF_TEST=0
NO_BUILD=${ONE_TAP_MACOS_NO_BUILD:-0}

log()
{
	printf '%s\n' "$*"
}

die()
{
	log "ERROR: $*"
	exit 1
}

usage()
{
	cat <<EOF
Usage: macos/one_tap_macos.sh [--self-test] [--no-build]

This macOS entrypoint verifies and builds supported user-space utilities only.
Transparent zapret2 traffic interception is not available on macOS in the
current architecture.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--self-test)
			SELF_TEST=1
			;;
		--no-build)
			NO_BUILD=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 1
			;;
	esac
	shift
done

build_tool()
{
	# $1 - directory, $2 - executable
	local dir="$1" exe="$2"

	if [ -x "$ZAPRET_BASE/$dir/$exe" ]; then
		return 0
	fi
	[ "$NO_BUILD" = 1 ] && return 1

	command -v make >/dev/null 2>&1 || return 1
	command -v cc >/dev/null 2>&1 || return 1

	log "* building $dir/$exe"
	make -C "$ZAPRET_BASE/$dir" >/dev/null
}

smoke_ip2net()
{
	printf '%s\n%s\n' 127.0.0.1 127.0.0.2 | "$ZAPRET_BASE/ip2net/ip2net" >/dev/null
}

smoke_mdig()
{
	"$ZAPRET_BASE/mdig/mdig" --dns-make-query=example.org >/dev/null
}

write_state()
{
	# $1 - utility status
	local status="$1"

	mkdir -p "$STATE_DIR"
	cat >"$STATE_DIR/config.macos" <<EOF
PLATFORM=macos
STATUS=$status
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
IP2NET=$ZAPRET_BASE/ip2net/ip2net
MDIG=$ZAPRET_BASE/mdig/mdig
CORE_STATUS=unsupported
CORE_REASON=macOS has no supported ipdivert/PF divert-packet path for zapret2 packet interception
EOF
}

main()
{
	[ "$(uname -s)" = Darwin ] || die "This launcher is for macOS only."

	local ok=1
	build_tool ip2net ip2net || ok=0
	build_tool mdig mdig || ok=0
	[ "$ok" = 1 ] && smoke_ip2net || ok=0
	[ "$ok" = 1 ] && smoke_mdig || ok=0

	if [ "$ok" = 1 ]; then
		write_state utility-ok
		log "* macOS utility self-test passed"
	else
		write_state utility-failed
		log "* macOS utility self-test failed"
	fi

	log
	log "macOS cannot start the main zapret2 DPI bypass core."
	log "Use the Linux/OpenWrt one_tap.sh or the Windows one_tap_windows.cmd version for transparent traffic interception."

	if [ "$SELF_TEST" = 1 ]; then
		[ "$ok" = 1 ] && exit 0 || exit 1
	fi
	exit 78
}

main "$@"
