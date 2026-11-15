#!/bin/bash
# Build the ZIGNOS bootable disk image from the bootstrap result ($LFS).
#
# Creates a partitioned image (MBR, one bootable ext4 partition), copies
# the built system into it and installs GRUB with the system's own
# grub-install — so the image boots like a real install:
#   BIOS -> GRUB (MBR) -> kernel -> OpenRC -> agetty
#
# Requires: linux and grub recipes installed into $LFS.

set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
OUT="${OUT:-$(pwd)/zignos-rootfs.img}"
SIZE="${SIZE:-12G}"
FSLABEL="${FSLABEL:-zignos-root}"

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
	[ -x "$LFS/usr/sbin/grub-install" ] || die "grub not installed in $LFS - build the grub recipe first"

	log "creating $OUT ($SIZE, MBR + one ext4 partition)"
	truncate -s "$SIZE" "$OUT"
	sfdisk "$OUT" <<'SFDISK'
label: dos
start=2048, type=83, bootable
SFDISK

	local loop
	loop=$(losetup -Pf --show "$OUT")
	trap 'losetup -d "$loop" 2>/dev/null || true' EXIT
	local part="${loop}p1"
	mkfs.ext4 -F -q -L "$FSLABEL" "$part"

	local mnt
	mnt=$(mktemp -d)
	mount "$part" "$mnt"

	log "copying the system (a few minutes)"
	# Leftover virtual filesystem mounts (from chroot work) would leak /proc
	# /sys /dev into the copy; drop them first.
	umount "$LFS/dev/pts" "$LFS/dev" "$LFS/proc" "$LFS/sys" "$LFS/run" 2>/dev/null || true
	tar -C "$LFS" \
		--exclude='sources' \
		--exclude='var/cache/zpkg' \
		--exclude='opt' \
		--exclude='tmp' \
		--exclude='proc' \
		--exclude='sys' \
		--exclude='dev' \
		--exclude='run' \
		-cf - . | tar -C "$mnt" -xf -

	log "installing GRUB with the system's grub-install"
	mkdir -pv "$LFS"/{dev,proc,sys}
	mountpoint -q "$LFS/dev" || mount --bind /dev "$LFS/dev"
	mountpoint -q "$LFS/proc" || mount -vt proc proc "$LFS/proc"
	mountpoint -q "$LFS/sys" || mount -vt sysfs sysfs "$LFS/sys"
	chroot "$LFS" grub-install --boot-directory=/boot "$loop"

	log "writing grub.cfg (serial console)"
	mkdir -pv "$mnt/boot/grub"
	cat > "$mnt/boot/grub/grub.cfg" <<'GRUBCFG'
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=2
set default=0
menuentry "ZIGNOS" {
	linux /boot/vmlinuz root=/dev/vda1 console=ttyS0
}
GRUBCFG

	umount "$mnt"
	rmdir "$mnt"
	losetup -d "$loop"
	trap - EXIT

	log "done: $OUT (bootable: BIOS -> GRUB -> kernel -> OpenRC)"
}

main "$@"
