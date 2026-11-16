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
unmount_vfs() {
	local lfs="$1" v n=0
	while [ "$n" -lt 5 ]; do
		n=$((n + 1))
		mountpoint -q "$lfs/dev/pts" && umount "$lfs/dev/pts" 2>/dev/null
		for v in dev proc sys run; do
			mountpoint -q "$lfs/$v" && umount "$lfs/$v" 2>/dev/null
		done
		if ! mountpoint -q "$lfs/proc" && ! mountpoint -q "$lfs/sys" 		   && ! mountpoint -q "$lfs/dev" && ! mountpoint -q "$lfs/run"; then
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
	# Stale loop attachments of the same backing file leave inconsistent
	# page caches behind (bad block bitmap checksums, "Structure needs
	# cleaning"); detach everything and drop caches before starting.
	losetup -D 2>/dev/null || true
	sync
	echo 3 > /proc/sys/vm/drop_caches
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
	unmount_vfs "$LFS"
	# Hard requirement: no virtual filesystem may remain under $LFS, or the
	# copy silently ingests /proc (huge, permission errors, corrupt image).
	for v in dev proc sys run; do
		mountpoint -q "$LFS/$v" && die "$LFS/$v is still mounted - refusing to copy"
	done
	# A stale $LFS/dev bind can make the umount above detach the BUILD VM's
	# own /dev/pts (pty allocation then fails everywhere). Self-heal:
	mountpoint -q /dev/pts || mount -vt devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=0666
	# Repair the source tree layout too: fs damage has repeatedly lost the
	# root usr-merge symlinks mid-session.
	for s in bin lib sbin; do
		[ -L "$LFS/$s" ] && continue
		rm -rf "${LFS:?}/$s"
		ln -s "usr/$s" "${LFS:?}/$s"
	done
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

	log "enforcing usr-merge layout in the image"
	# The /bin /lib /sbin -> usr/* symlinks are part of the base layout; the
	# bootstrap tree can lose them through fs damage, and without them
	# /sbin/init (a symlink chain) goes dangling and the kernel falls back
	# to /bin/sh. NOTE: ln -sfn does NOT replace an existing REAL directory
	# (it creates the link inside it), so drop real dirs first.
	mkdir -pv "$mnt"/usr/{bin,lib,sbin}
	for s in bin lib sbin; do
		if [ -L "$mnt/$s" ]; then
			ln -sfn "usr/$s" "$mnt/$s"
		elif [ -d "$mnt/$s" ]; then
			rm -rf "${mnt:?}/$s"
			ln -s "usr/$s" "${mnt:?}/$s"
		else
			ln -s "usr/$s" "${mnt:?}/$s"
		fi
	done
	[ -L "$mnt/lib64" ] && rm -rf "${mnt:?}/lib64"
	ln -sfn lib "$mnt/lib64"
	[ -e "$mnt/usr/sbin/openrc-init" ] || die "openrc-init missing in the system copy"

	# The same fs damage that loses the root symlinks also mangles the init
	# chain (/sbin/init -> /usr/sbin/init -> nowhere). Rebuild it so PID 1
	# is reachable regardless of what state the source tree came in.
	rm -f "$mnt/sbin/sbin" "$mnt/usr/sbin/sbin"   # stray self-referencing links
	ln -sfn /usr/sbin/openrc-init "$mnt/sbin/init"
	ln -sfn /usr/sbin/openrc-init "$mnt/usr/sbin/init"

	# Ship the real-disk installer so the guest can install itself onto a
	# second disk (see zignos-install.sh).
	SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
	if [ -f "$SELF_DIR/zignos-install.sh" ]; then
		install -m 755 "$SELF_DIR/zignos-install.sh" "$mnt/usr/sbin/zignos-install"
	fi

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
