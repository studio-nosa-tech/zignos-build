#!/bin/bash
# Build the ZIGNOS bootable disk image from the bootstrap result ($LFS).
#
# The image is produced WITHOUT loop-mounting it: the system is staged into
# a plain directory and mke2fs -d populates the partition in one pass
# (-E offset= writes at the partition offset). GRUB is installed by
# hand-building core.img and dd'ing it into the MBR gap. This avoids the
# loop/page-cache races that corrupted earlier images on the build VM.
#
# Requires: linux and grub recipes installed into $LFS.

set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
OUT="${OUT:-$(pwd)/zignos-rootfs.img}"
SIZE="${SIZE:-12G}"
FSLABEL="${FSLABEL:-zignos-root}"
PART_START=2048   # sectors, 1 MiB alignment
STAGE=""         # staging dir, cleaned by the EXIT trap

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-image: %s\n' "$*" >&2; exit 1; }

# unmount_vfs <lfs>: detach dev/proc/sys/run (and dev/pts) with retries and
# a lazy fallback.
unmount_vfs() {
	local lfs="$1" v n=0
	while [ "$n" -lt 5 ]; do
		n=$((n + 1))
		mountpoint -q "$lfs/dev/pts" && umount "$lfs/dev/pts" 2>/dev/null
		for v in dev proc sys run; do
			mountpoint -q "$lfs/$v" && umount "$lfs/$v" 2>/dev/null
		done
		if ! mountpoint -q "$lfs/proc" && ! mountpoint -q "$lfs/sys" &&
		   ! mountpoint -q "$lfs/dev" && ! mountpoint -q "$lfs/run"; then
			return 0
		fi
		sleep 1
	done
	mountpoint -q "$lfs/dev/pts" && umount -l "$lfs/dev/pts" 2>/dev/null
	for v in dev proc sys run; do
		mountpoint -q "$lfs/$v" && umount -l "$lfs/$v" 2>/dev/null
	done
	sleep 1
	return 0
}

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	local kern=""
	for kern in "$LFS"/boot/vmlinuz*; do
		[ -f "$kern" ] && break
		kern=""
	done
	[ -n "$kern" ] || die "no kernel in $LFS/boot - build the linux recipe first"
	[ -x "$LFS/usr/sbin/grub-install" ] || die "grub not installed in $LFS - build the grub recipe first"

	STAGE=$(mktemp -d /var/tmp/zignos-stage.XXXXXX)
	trap 'rm -rf "${STAGE:-}"' EXIT

	log "staging the system into $STAGE"
	unmount_vfs "$LFS"
	for v in dev proc sys run; do
		mountpoint -q "$LFS/$v" && die "$LFS/$v is still mounted - refusing to copy"
	done
	tar -C "$LFS" \
		--exclude='sources' \
		--exclude='var/cache/zpkg' \
		--exclude='opt' \
		--exclude='tmp' \
		--exclude='proc' \
		--exclude='sys' \
		--exclude='dev' \
		--exclude='run' \
		-cf - . | tar -C "$STAGE" -xf -

	log "fixing layout and runtime mount points"
	mkdir -pv "$STAGE"/usr/{bin,lib,sbin} "$STAGE"/{dev,proc,sys,run,tmp} \
		"$STAGE/var/tmp" "$STAGE/var/lib/seedrng" "$STAGE/boot"
	chmod 1777 "$STAGE/tmp" "$STAGE/var/tmp"
	for s in bin lib sbin; do
		if [ -L "$STAGE/$s" ]; then
			ln -sfn "usr/$s" "$STAGE/$s"
		elif [ -d "$STAGE/$s" ]; then
			rm -rf "${stage:?}/$s"
			ln -s "usr/$s" "${stage:?}/$s"
		else
			ln -s "usr/$s" "${stage:?}/$s"
		fi
	done
	[ -L "$STAGE/lib64" ] && rm -rf "${stage:?}/lib64"
	ln -sfn lib "$STAGE/lib64"
	rm -f "$STAGE/sbin/sbin" "$STAGE/usr/sbin/sbin"
	# PID 1 must be reachable; rebuild the chain regardless of source state.
	ln -sfn /usr/sbin/openrc-init "$STAGE/sbin/init"
	ln -sfn /usr/sbin/openrc-init "$STAGE/usr/sbin/init"

	[ -x "$STAGE/usr/bin/bash" ] || die "staged copy has no /usr/bin/bash"
	[ -f "$STAGE/etc/zignos-release" ] || die "staged copy has no /etc/zignos-release"
	[ -e "$STAGE/usr/sbin/openrc-init" ] || die "openrc-init missing in the staged copy"

	# Ship the real-disk installer so the guest can install itself.
	local self_dir
	self_dir="$(cd "$(dirname "$0")" && pwd)"
	if [ -f "$self_dir/zignos-install.sh" ]; then
		install -m 755 "$self_dir/zignos-install.sh" "$STAGE/usr/sbin/zignos-install"
	fi

	log "installing kernel and GRUB payload into the staging tree"
	cp -a "$LFS"/boot/vmlinuz* "$STAGE/boot/"
	mkdir -pv "$STAGE/boot/grub/i386-pc"
	cp -a "$LFS"/usr/lib/grub/i386-pc/*.mod "$STAGE/boot/grub/i386-pc/"
	cp -a "$LFS"/usr/lib/grub/i386-pc/*.lst "$STAGE/boot/grub/i386-pc/" 2>/dev/null || true
	cat > "$STAGE/boot/grub/grub.cfg" <<'GRUBCFG'
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=2
set default=0
menuentry "ZIGNOS" {
	linux /boot/vmlinuz root=/dev/vda1 console=ttyS0
}
GRUBCFG

	log "creating $OUT ($SIZE, MBR, one bootable ext4 partition)"
	rm -f "$OUT"
	truncate -s "$SIZE" "$OUT"
	sfdisk "$OUT" <<'SFDISK'
label: dos
start=2048, type=83, bootable
SFDISK
	# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed.
	mke2fs -q -t ext4 -F -L "$FSLABEL" \
		-O ^orphan_file,^metadata_csum_seed \
		-d "$STAGE" -E offset=$((PART_START * 512)) "$OUT"

	log "installing GRUB (manual core.img and dd)"
	chroot "$LFS" grub-mkimage -O i386-pc -d /usr/lib/grub/i386-pc \
		-o /usr/lib/grub/i386-pc/core-zignos.img \
		-p '(hd0,msdos1)/boot/grub' \
		biosdisk part_msdos ext2 normal linux echo serial terminal test
	dd if="$LFS/usr/lib/grub/i386-pc/boot.img" of="$OUT" bs=446 count=1 conv=notrunc status=none
	dd if="$LFS/usr/lib/grub/i386-pc/core-zignos.img" of="$OUT" seek=1 bs=512 conv=notrunc status=none

	log "done: $OUT (bootable: BIOS -> GRUB -> kernel -> OpenRC)"
}

main "$@"
