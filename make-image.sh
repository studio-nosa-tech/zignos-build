#!/bin/bash
# Build the ZIGNOS bootable disk image from the bootstrap result ($ZIGNOS_ROOT).
#
# The root filesystem is produced WITHOUT loop-mounting it: the system is
# staged into a plain directory and mke2fs -d populates the partition in one
# pass (-E offset= writes at the partition offset).
#
#   UEFI=0 (default): MBR disk, one ext4 partition, BIOS GRUB core.img.
#   UEFI=1:           GPT disk, ESP (FAT32) + ext4 root, removable-path
#                     BOOTX64.EFI built with grub-mkstandalone.
#
# Both variants boot through the initramfs (/boot/initramfs.img) and use
# root=UUID=..., so the image can be dd'd to any disk.
#
# Requires: linux (kernel + initramfs) and grub (BIOS + UEFI) installed into
# $ZIGNOS_ROOT. UEFI mode additionally requires mkfs.vfat and losetup on the host.

set -euo pipefail

ZIGNOS_ROOT="${ZIGNOS_ROOT:-/mnt}"
OUT="${OUT:-$(pwd)/zignos-rootfs.img}"
SIZE="${SIZE:-12G}"
FSLABEL="${FSLABEL:-zignos-root}"
UEFI="${UEFI:-0}"
CHANNEL="${CHANNEL:-stable}"
PART_START=2048       # sectors, 1 MiB alignment
ESP_SECTORS=204800    # 100 MiB EFI system partition (UEFI mode)
ROOT_START=$((PART_START + ESP_SECTORS))
STAGE=""              # staging dir, cleaned by the EXIT trap
ESP_IMG=""            # ESP image file (UEFI mode)
ESP_MNT=""            # ESP mount point (UEFI mode)
ESP_LOOP=""           # loop device backing the ESP image

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-image: %s\n' "$*" >&2; exit 1; }


# merge_dir <src> <dst>: copy entries that are missing from dst. Used when
# the source tree is not fully usr-merged: /usr wins for duplicates, and
# copying an identical symlink over itself would fail with "same file".
merge_dir() {
	local f base
	for f in "$1"/*; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		base=${f##*/}
		if [ -e "$2/$base" ] || [ -L "$2/$base" ]; then
			continue
		fi
		cp -a "$f" "$2/"
	done
}

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	local kern=""
	for kern in "$ZIGNOS_ROOT"/boot/vmlinuz*; do
		[ -f "$kern" ] && break
		kern=""
	done
	[ -n "$kern" ] || die "no kernel in $ZIGNOS_ROOT/boot - build the linux recipe first"
	[ -x "$ZIGNOS_ROOT/usr/sbin/grub-install" ] || die "grub not installed in $ZIGNOS_ROOT - build the grub recipe first"

	STAGE=$(mktemp -d /var/tmp/zignos-stage.XXXXXX)
	# shellcheck disable=SC2154  # rc is assigned by the trap itself
	cleanup() {
		rc=$?
		if [ -n "${ESP_MNT:-}" ] && mountpoint -q "$ESP_MNT"; then
			umount "$ESP_MNT" 2>/dev/null || true
		fi
		if [ -n "${ESP_LOOP:-}" ]; then
			losetup -d "$ESP_LOOP" 2>/dev/null || true
		fi
		[ -n "${ESP_MNT:-}" ] && rmdir "$ESP_MNT" 2>/dev/null
		[ -n "${ESP_IMG:-}" ] && rm -f "$ESP_IMG"
		rm -rf "${STAGE:-}"
		exit $rc
	}
	trap cleanup EXIT

	[ -f "$ZIGNOS_ROOT/boot/initramfs.img" ] ||
		die "no initramfs in $ZIGNOS_ROOT/boot - rebuild the linux recipe (initramfs)"
	ROOTUUID=$(cat /proc/sys/kernel/random/uuid)
	[ -n "$ROOTUUID" ] || die "could not generate a root filesystem UUID"

	log "staging the system into $STAGE"
	# Do NOT unmount $ZIGNOS_ROOT/dev, /proc, /sys or /run: $ZIGNOS_ROOT/dev is usually a
	# bind mount of the host /dev, and unmounting $ZIGNOS_ROOT/dev/pts there also
	# detaches the HOST's devpts (this broke sshd on the build VM twice).
	# The tar excludes below drop those directories; the staging tree
	# recreates the mount points.
	for v in dev proc sys run; do
		if mountpoint -q "$ZIGNOS_ROOT/$v"; then
			echo "make-image: note: $ZIGNOS_ROOT/$v is mounted; it is excluded from the copy"
		fi
	done
	tar -C "$ZIGNOS_ROOT" \
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
			# Not usr-merged yet: merge the contents into /usr instead of
			# dropping them (a package may have installed into /sbin).
			merge_dir "$STAGE/$s" "$STAGE/usr/$s"
			rm -rf "${STAGE:?}/$s"
			ln -s "usr/$s" "${STAGE:?}/$s"
		else
			ln -s "usr/$s" "${STAGE:?}/$s"
		fi
	done
	if [ -d "$STAGE/lib64" ] && [ ! -L "$STAGE/lib64" ]; then
		merge_dir "$STAGE/lib64" "$STAGE/lib"
		rm -rf "${STAGE:?}/lib64"
	fi
	ln -sfn lib "$STAGE/lib64"
	rm -f "$STAGE/sbin/sbin" "$STAGE/usr/sbin/sbin"
	# PID 1 must be reachable; rebuild the chain regardless of source state.
	ln -sfn /usr/sbin/openrc-init "$STAGE/sbin/init"
	ln -sfn /usr/sbin/openrc-init "$STAGE/usr/sbin/init"

	# The initramfs mounts root read-only by UUID, then OpenRC remounts it
	# rw. A boot-time fsck still cannot run on a busy root: pass 0 keeps the
	# fsck service away; run e2fsck from a rescue system.
	cat > "$STAGE/etc/fstab" <<FSTAB
# ZIGNOS filesystem table (root is mounted by the initramfs)
UUID=$ROOTUUID  /     ext4  defaults  0 0
proc       /proc proc  defaults  0 0
sysfs      /sys  sysfs defaults  0 0
FSTAB

	[ -x "$STAGE/usr/bin/bash" ] || die "staged copy has no /usr/bin/bash"
	[ -f "$STAGE/etc/zignos-release" ] || die "staged copy has no /etc/zignos-release"
	[ -e "$STAGE/usr/sbin/openrc-init" ] || die "openrc-init missing in the staged copy"

	# Ship the selected channel so zpkg works on the installed system
	# without cloning anything. testing/unstable can be added with sync.
	if [ -d "$ZIGNOS_ROOT/sources/zignos-recipes/$CHANNEL/core" ]; then
		mkdir -pv "$STAGE/usr/share/zignos/recipes"
		cp -a "$ZIGNOS_ROOT/sources/zignos-recipes/$CHANNEL" "$STAGE/usr/share/zignos/recipes/$CHANNEL"
		rm -rf "$STAGE/usr/share/zignos/recipes/$CHANNEL/.git"
		mkdir -p "$STAGE/etc/zpkg"
		cat > "$STAGE/etc/zpkg/make.conf" <<EOF
# zpkg build options
# Release channel: stable, testing or unstable.
CHANNEL=$CHANNEL
EOF
	fi

	# Ship the real-disk installer so the guest can install itself.
	local self_dir
	self_dir="$(cd "$(dirname "$0")" && pwd)"
	if [ -f "$self_dir/zignos-install.sh" ]; then
		install -m 755 "$self_dir/zignos-install.sh" "$STAGE/usr/sbin/zignos-install"
	fi

	log "installing kernel and initramfs into the staging tree"
	cp -a "$ZIGNOS_ROOT"/boot/vmlinuz* "$STAGE/boot/"
	cp -a "$ZIGNOS_ROOT/boot/initramfs.img" "$STAGE/boot/initramfs.img"
	# BIOS GRUB loads extra modules from the prefix; copy them into /boot.
	mkdir -pv "$STAGE/boot/grub/i386-pc"
	cp -a "$ZIGNOS_ROOT"/usr/lib/grub/i386-pc/*.mod "$STAGE/boot/grub/i386-pc/"
	cp -a "$ZIGNOS_ROOT"/usr/lib/grub/i386-pc/*.lst "$STAGE/boot/grub/i386-pc/" 2>/dev/null || true

	# Both consoles: laptops/desktops use tty0, servers (and the QEMU test)
	# use ttyS0. The last console= is /dev/console, so keep ttyS0 last.
	# root=UUID works for both BIOS and UEFI images and survives dd to any
	# disk; the initramfs resolves it (busybox blkid).
	GRUB_ENTRY="menuentry \"ZIGNOS\" {
	linux /boot/vmlinuz root=UUID=$ROOTUUID console=tty0 console=ttyS0
	initrd /boot/initramfs.img
}"
	cat > "$STAGE/boot/grub/grub.cfg" <<GRUBCFG
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=2
set default=0
search --no-floppy --fs-uuid --set=root $ROOTUUID
$GRUB_ENTRY
GRUBCFG

	if [ "$UEFI" = 1 ]; then
		command -v mkfs.vfat >/dev/null 2>&1 ||
			die "UEFI mode needs mkfs.vfat (dosfstools) on the host"
		log "creating $OUT ($SIZE, GPT: 100MiB ESP + ext4 root)"
		rm -f "$OUT"
		truncate -s "$SIZE" "$OUT"
		# The GPT backup header/entries live in the last 34 sectors. Size
		# the root partition (and therefore the ext4 filesystem) to end
		# before them, otherwise mke2fs creates a filesystem larger than
		# the partition ("bad geometry ... exceeds size of device").
		local total_sectors root_sectors root_blocks
		total_sectors=$(( $(stat -c %s "$OUT") / 512 ))
		root_sectors=$(( ((total_sectors - ROOT_START - 34) / 8) * 8 ))
		root_blocks=$(( root_sectors / 8 ))
		[ "$root_blocks" -gt 0 ] || die "image is too small for a GPT root partition"
		sfdisk "$OUT" <<SFDISK
label: gpt
start=$PART_START, size=$ESP_SECTORS, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ZIGNOS ESP"
start=$ROOT_START, size=$root_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="zignos-root"
SFDISK

		# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed.
		# -b 4096 makes the trailing block count 4K units (mke2fs otherwise
		# treats an explicit size as 1KiB blocks and makes a 1/4-size fs).
		mke2fs -q -t ext4 -b 4096 -F -L "$FSLABEL" -U "$ROOTUUID" \
			-O ^orphan_file,^metadata_csum_seed \
			-d "$STAGE" -E offset=$((ROOT_START * 512)) "$OUT" "$root_blocks"

		log "building the EFI bootloader (grub-mkstandalone)"
		cat > "$ZIGNOS_ROOT/tmp/zignos-uefi-grub.cfg" <<GRUBCFG
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=2
set default=0
search --no-floppy --fs-uuid --set=root $ROOTUUID
$GRUB_ENTRY
GRUBCFG
		chroot "$ZIGNOS_ROOT" grub-mkstandalone -O x86_64-efi \
			-o /tmp/BOOTX64.EFI \
			--modules="part_gpt part_msdos fat ext2 normal search search_fs_uuid linux echo serial terminal" \
			"boot/grub/grub.cfg=/tmp/zignos-uefi-grub.cfg"

		log "populating the EFI system partition"
		ESP_IMG=$(mktemp /var/tmp/zignos-esp.XXXXXX)
		truncate -s $((ESP_SECTORS * 512)) "$ESP_IMG"
		mkfs.vfat -F32 -n ZIGNOSESP "$ESP_IMG" >/dev/null
		ESP_MNT=$(mktemp -d /var/tmp/zignos-esp-mnt.XXXXXX)
		ESP_LOOP=$(losetup -f --show "$ESP_IMG")
		mount -t vfat "$ESP_LOOP" "$ESP_MNT"
		mkdir -p "$ESP_MNT/EFI/BOOT"
		cp "$ZIGNOS_ROOT/tmp/BOOTX64.EFI" "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
		# The firmware fallback path is enough; no NVRAM entry is written.
		sync
		umount "$ESP_MNT"
		losetup -d "$ESP_LOOP"
		ESP_LOOP=""
		rmdir "$ESP_MNT"
		ESP_MNT=""
		dd if="$ESP_IMG" of="$OUT" bs=512 seek=$PART_START conv=notrunc status=none
		rm -f "$ESP_IMG"
		ESP_IMG=""
		rm -f "$ZIGNOS_ROOT/tmp/BOOTX64.EFI" "$ZIGNOS_ROOT/tmp/zignos-uefi-grub.cfg"

		log "done: $OUT (bootable: UEFI -> BOOTX64.EFI -> kernel + initramfs -> OpenRC)"
		return 0
	fi

	log "creating $OUT ($SIZE, MBR, one bootable ext4 partition)"
	rm -f "$OUT"
	truncate -s "$SIZE" "$OUT"
	sfdisk "$OUT" <<SFDISK
label: dos
start=$PART_START, type=83, bootable
SFDISK

	# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed.
	mke2fs -q -t ext4 -F -L "$FSLABEL" -U "$ROOTUUID" \
		-O ^orphan_file,^metadata_csum_seed \
		-d "$STAGE" -E offset=$((PART_START * 512)) "$OUT"

	log "installing GRUB (manual core.img and dd)"
	chroot "$ZIGNOS_ROOT" grub-mkimage -O i386-pc -d /usr/lib/grub/i386-pc \
		-o /usr/lib/grub/i386-pc/core-zignos.img \
		-p '(hd0,msdos1)/boot/grub' \
		biosdisk part_msdos ext2 normal linux echo serial terminal test \
		search search_fs_uuid
	# 440 bytes = the boot code only. 446 would also overwrite the MBR disk
	# signature at offset 440; GRUB's boot.img has zeros there.
	dd if="$ZIGNOS_ROOT/usr/lib/grub/i386-pc/boot.img" of="$OUT" bs=440 count=1 conv=notrunc status=none
	dd if="$ZIGNOS_ROOT/usr/lib/grub/i386-pc/core-zignos.img" of="$OUT" seek=1 bs=512 conv=notrunc status=none

	log "done: $OUT (bootable: BIOS -> GRUB -> kernel + initramfs -> OpenRC)"
}

main "$@"
