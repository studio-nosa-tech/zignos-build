#!/bin/bash
# Build a ZIGNOS seed tarball from the current system tree ($LFS).
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

LFS="${LFS:-/mnt/lfs}"
OUT="${OUT:-$(pwd)/zignos-seed-$(date +%Y%m%d)-x86_64.tar.gz}"

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-seed: %s\n' "$*" >&2; exit 1; }

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -x "$LFS/usr/bin/bash" ] || die "$LFS does not look like a ZIGNOS tree"
	[ -f "$LFS/etc/zignos-release" ] || die "$LFS has no /etc/zignos-release"
	for v in dev proc sys run; do
		mountpoint -q "$LFS/$v" && die "$LFS/$v is mounted - unmount the vfs first"
	done

	log "packing $LFS into $OUT"
	tar -C "$LFS" \
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
