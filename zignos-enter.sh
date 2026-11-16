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

# Refuse to start on top of a previous interrupted run: a host /dev or
# /proc left mounted under $ROOT is how a later `rm -rf $ROOT` can destroy
# the host's device nodes. Unmount them first, or abort if we cannot.
for v in dev proc sys run; do
	if mountpoint -q "$ROOT/$v"; then
		umount "$ROOT/$v" || die "cannot unmount the stale $ROOT/$v (stop what uses it first)"
	fi
done

# shellcheck disable=SC2329  # invoked by the EXIT trap
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
	# Do not exec: the EXIT trap must run to unmount the vfs. (Leaving
	# /proc, /sys and /dev mounted in a seed directory is dangerous:
	# a later rm -rf would walk into the host's /dev.)
	rc=0
	chroot "$ROOT" /usr/bin/bash -l || rc=$?
else
	rc=0
	chroot "$ROOT" "$@" || rc=$?
fi
exit "$rc"
