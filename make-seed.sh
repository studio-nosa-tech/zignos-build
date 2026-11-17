#!/bin/bash
# Build a ZIGNOS seed tarball from the current system tree ($ZIGNOS_ROOT).
#
# A seed is the supported bootstrap path for developers: unpack it into a
# directory or filesystem and you have a complete ZIGNOS root that zpkg can
# drive. No LFS book procedure is needed to use or extend the system; the
# cross toolchain in bootstrap.sh is a maintainer-only path that produces
# the seed in the first place.
#
# The archive keeps mount-point directories but none of their contents,
# and drops source tarballs, package caches and build leftovers.

set -euo pipefail

ZIGNOS_ROOT="${ZIGNOS_ROOT:-/mnt}"
OUT="${OUT:-$(pwd)/zignos-seed-$(date +%Y%m%d)-x86_64.tar.gz}"

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-seed: %s\n' "$*" >&2; exit 1; }

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -x "$ZIGNOS_ROOT/usr/bin/bash" ] || die "$ZIGNOS_ROOT does not look like a ZIGNOS tree"
	[ -f "$ZIGNOS_ROOT/etc/zignos-release" ] || die "$ZIGNOS_ROOT has no /etc/zignos-release"
	for v in dev proc sys run; do
		mountpoint -q "$ZIGNOS_ROOT/$v" && die "$ZIGNOS_ROOT/$v is mounted - unmount the vfs first"
	done

	log "packing $ZIGNOS_ROOT into $OUT"
	tar -C "$ZIGNOS_ROOT" \
		--exclude='./sources' \
		--exclude='./var/cache/zpkg' \
		--exclude='./opt' \
		--exclude='./dev/*' \
		--exclude='./proc/*' \
		--exclude='./sys/*' \
		--exclude='./run/*' \
		--exclude='./tmp/*' \
		--exclude='./var/tmp/*' \
		--exclude='./var/lib/seedrng/*' \
		-czf "$OUT" .

	log "done: $OUT ($(du -h "$OUT" | cut -f1))"
	echo "Unpack with: tar -xzf $OUT -C <target>"
	echo "Enter it with: zignos-enter.sh <target>"
}

main "$@"
