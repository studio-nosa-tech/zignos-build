#!/bin/bash
# ZIGNOS installer — copy the RUNNING system onto a target disk and make
# it bootable (MBR + GRUB). Run INSIDE the running ZIGNOS as root.
#
# Usage:
#   zignos-install [--yes] /dev/sdX
#
# The target disk is partitioned (one bootable ext4 partition) and every
# byte on it is destroyed. The root password of the running system is
# carried over (it lives in /etc/shadow, which is copied).

set -euo pipefail

YES=0
if [ "${1:-}" = "--yes" ]; then
	YES=1
	shift
fi
DISK="${1:-}"

log() { printf '\n== %s\n' "$*"; }
die() { echo "zignos-install: $*" >&2; exit 1; }

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -n "$DISK" ] || { echo "usage: zignos-install [--yes] /dev/sdX" >&2; exit 1; }
	[ -b "$DISK" ] || die "$DISK is not a block device"
	case "$(findmnt -n -o SOURCE /)" in
		"$DISK"|"$DISK"[0-9]*) die "refusing: $DISK is the running root disk" ;;
	esac
	for c in sfdisk mkfs.ext4 blkid grub-install; do
		command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
	done

	log "Installing ZIGNOS onto $DISK — ALL DATA ON IT WILL BE DESTROYED"
	if [ "$YES" != 1 ]; then
		read -r -p "Type YES to continue: " answer
		[ "$answer" = YES ] || die "aborted"
	fi

	log "partitioning $DISK (MBR, one bootable ext4 partition) — ALL DATA IS DESTROYED"
	sfdisk "$DISK" <<'SFDISK'
label: dos
start=2048, type=83, bootable
SFDISK
	partx -u "$DISK" 2>/dev/null || true
	sleep 1
	local part="${DISK}1"

	log "creating filesystem (label zignos-root)"
	# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed.
	mkfs.ext4 -F -q -O ^orphan_file,^metadata_csum_seed -L zignos-root "$part"
	# The minimal kernel has no initramfs and does not resolve root=UUID=;
	# PARTUUID (disk id + partition number) is resolved by the kernel and
	# survives vda/sda renumbering.
	local partuuid uuid
	partuuid=$(blkid -s PARTUUID -o value "$part" || true)
	uuid=$(blkid -s UUID -o value "$part")

	local mnt
	mnt=$(mktemp -d)
	mount "$part" "$mnt"

	log "copying the running system"
	# Same copy profile as make-image.sh: keep the system, drop runtime
	# mounts' contents, caches and seed state (recreated below).
	tar -C / \
		--exclude='./dev/*' \
		--exclude='./proc/*' \
		--exclude='./sys/*' \
		--exclude='./run/*' \
		--exclude='./tmp/*' \
		--exclude='./var/cache/zpkg/*' \
		--exclude='./var/lib/seedrng/*' \
		--exclude='./sources' \
		-cf - . | tar -C "$mnt" -xf -

	log "fixing the usr-merge layout and mount points"
	mkdir -pv "$mnt"/usr/{bin,lib,sbin} "$mnt"/{dev,proc,sys,run,tmp} "$mnt/var/tmp" "$mnt/var/lib/seedrng"
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
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"
	rm -f "$mnt/sbin/sbin" "$mnt/usr/sbin/sbin"

	log "writing /etc/fstab (PARTUUID-based)"
	printf 'PARTUUID=%s / ext4 defaults 1 1\n' "$partuuid" > "$mnt/etc/fstab"
	printf 'proc /proc proc defaults 0 0\n' >> "$mnt/etc/fstab"
	printf 'sysfs /sys sysfs defaults 0 0\n' >> "$mnt/etc/fstab"

	log "copying the kernel into the target /boot"
	mkdir -pv "$mnt/boot"
	cp -a /boot/vmlinuz* "$mnt/boot/" 2>/dev/null || true

	log "installing GRUB from the system's grub-install"
	mkdir -pv "$mnt"/{dev,proc,sys}
	mount --bind /dev "$mnt/dev"
	mount -vt proc proc "$mnt/proc"
	mount -vt sysfs sysfs "$mnt/sys"
	# The chroot IS the target partition, so grub-install probes the target
	# /boot directly and embeds its UUID search (no loop-device ambiguity).
	chroot "$mnt" grub-install --target=i386-pc --boot-directory=/boot "$DISK"
	umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true

	log "writing grub.cfg (serial console, PARTUUID root)"
	mkdir -pv "$mnt/boot/grub"
	cat > "$mnt/boot/grub/grub.cfg" <<GRUBCFG
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=2
set default=0
menuentry "ZIGNOS" {
	linux /boot/vmlinuz root=PARTUUID=$partuuid console=ttyS0
}
GRUBCFG

	log "recreating runtime mount points in the image"
	umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true
	mkdir -pv "$mnt"/{dev,proc,sys,run,tmp} "$mnt/var/tmp" "$mnt/var/lib/seedrng"
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"

	umount "$mnt"
	rmdir "$mnt" 2>/dev/null || true

	log "done — ZIGNOS-INSTALL-COMPLETE"
	echo "Boot from $DISK (root password is the running system's)."
}

main "$@"
