#!/bin/bash
# Enter a ZIGNOS root (an unpacked seed, an installed disk, or a directory
# chroot) with /dev, /proc, /sys and /run mounted, and clean them up when
# the shell exits.
#
#   zignos-enter.sh <root> [command...]
#
# With no command a login shell is started. This is the LFS-free way to
# work on a ZIGNOS system: unpack a seed, enter, run zpkg.

set -euo pipefail

ROOT="${1:?usage: zignos-enter.sh <root> [command...]}"
shift || true

die() { printf 'zignos-enter: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
ROOT=$(cd "$ROOT" && pwd)
[ -x "$ROOT/usr/bin/bash" ] || die "$ROOT has no /usr/bin/bash"
[ -f "$ROOT/etc/zignos-release" ] || die "$ROOT is not a ZIGNOS tree"

cleanup() {
	umount "$ROOT/dev" 2>/dev/null || true
	umount "$ROOT/proc" 2>/dev/null || true
	umount "$ROOT/sys" 2>/dev/null || true
	umount "$ROOT/run" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -pv "$ROOT"/{dev,proc,sys,run}
mount --bind /dev "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount -t tmpfs -o mode=755 tmpfs "$ROOT/run"

if [ $# -eq 0 ]; then
	exec chroot "$ROOT" /usr/bin/bash -l
fi
exec chroot "$ROOT" "$@"
