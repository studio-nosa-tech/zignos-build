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

	local loop=""
	trap '[ -n "${loop:-}" ] && losetup -d "$loop" 2>/dev/null || true' EXIT
	loop=$(losetup -Pf --show "$OUT")
	local part="${loop}p1"
	# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed
	# (e2fsprogs 1.47+ defaults); disable them for the boot filesystem.
	mkfs.ext4 -F -q -O ^orphan_file,^metadata_csum_seed -L "$FSLABEL" "$part"

	local mnt
	mnt=$(mktemp -d)
	mount "$part" "$mnt"

	log "copying the system (a few minutes)"
	# Leftover virtual filesystem mounts (from chroot work) would leak /proc
	# /sys /dev into the copy; drop them first. The mountpoint directories
	# themselves must still be copied (devtmpfs needs /dev to mount on), so
	# they are NOT excluded - the unmount above leaves them empty.
	umount "$LFS/dev/pts" "$LFS/dev" "$LFS/proc" "$LFS/sys" "$LFS/run" 2>/dev/null || true
	tar -C "$LFS" \
		--exclude='sources' \
		--exclude='var/cache/zpkg' \
		--exclude='opt' \
		--exclude='tmp' \
		-cf - . | tar -C "$mnt" -xf -

	log "creating runtime mount points"
	# Safety net in case the source tree lost one of them.
	mkdir -pv "$mnt"/{dev,proc,sys,run,tmp,opt} "$mnt/var/tmp" "$mnt/var/lib/seedrng"
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"

	log "installing GRUB (manual core.img: probing loop devices is unreliable)"
	# grub-install inside the chroot resolves loop devices back to the host
	# filesystem and embeds the wrong UUID. Instead: build a core.img with
	# an explicit prefix and dd boot.img + core.img into the MBR gap.
	mkdir -pv "$mnt/boot/grub/i386-pc"
	cp -a "$LFS"/usr/lib/grub/i386-pc/*.mod "$mnt/boot/grub/i386-pc/"
	cp -a "$LFS"/usr/lib/grub/i386-pc/*.lst "$mnt/boot/grub/i386-pc/" 2>/dev/null || true
	chroot "$LFS" grub-mkimage -O i386-pc -d /usr/lib/grub/i386-pc \
		-o /usr/lib/grub/i386-pc/core-zignos.img \
		-p '(hd0,msdos1)/boot/grub' \
		biosdisk part_msdos ext2 normal linux echo serial terminal test
	dd if="$LFS/usr/lib/grub/i386-pc/boot.img" of="$loop" bs=446 count=1 conv=notrunc
	dd if="$LFS/usr/lib/grub/i386-pc/core-zignos.img" of="$loop" seek=1 bs=512 conv=notrunc

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
