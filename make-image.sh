#!/bin/bash
# Build the ZIGNOS rootfs disk image from the bootstrap result ($LFS).
#
# Copies the built system into a fresh ext4 image, skipping build-side
# junk (sources, zpkg cache), then installs the M3 boot files
# (busybox init). Run as root on the build VM.

set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
OUT="${OUT:-$(pwd)/zignos-rootfs.img}"
SIZE="${SIZE:-12G}"
BOOTFILES="$(cd "$(dirname "$0")" && pwd)/bootfiles"

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-image: %s\n' "$*" >&2; exit 1; }

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	local kern=""
	for kern in "$LFS"/boot/vmlinuz*; do
		[ -f "$kern" ] && break
		kern=""
	done
	[ -n "$kern" ] || die "no kernel in $LFS/boot - build the linux recipe first"
	[ -f "$BOOTFILES/inittab" ] || die "bootfiles not found next to this script"

	log "creating $OUT ($SIZE)"
	truncate -s "$SIZE" "$OUT"
	mkfs.ext4 -F -q "$OUT"

	local mnt
	mnt=$(mktemp -d)
	mount -o loop "$OUT" "$mnt"

	log "copying the system (this takes a few minutes)"
	# Tar pipe instead of rsync: the build host has no rsync; the excludes
	# keep the image free of bootstrap-side data.
	tar -C "$LFS" \
		--exclude='./sources' \
		--exclude='./var/cache/zpkg' \
		--exclude='./opt' \
		--exclude='./tmp/*' \
		-cf - . | tar -C "$mnt" -xf -

	log "installing boot files (busybox init)"
	install -m 644 "$BOOTFILES/inittab" "$mnt/etc/inittab"
	install -m 644 "$BOOTFILES/fstab" "$mnt/etc/fstab"
	install -m 755 "$BOOTFILES/rc.init" "$mnt/etc/rc.init"
	install -m 755 "$BOOTFILES/rc.shutdown" "$mnt/etc/rc.shutdown"

	umount "$mnt"
	rmdir "$mnt"
	log "done: $OUT"
}

main "$@"
