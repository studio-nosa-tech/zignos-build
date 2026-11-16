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
#
# A non-root user is created so the system can be used without logging in
# as root. In interactive mode the username/password are asked for; with
# --yes they come from ZIGNOS_USER / ZIGNOS_PASSWORD (defaults: zignos /
# zignos). An SSH public key for that user is taken from the running
# root's /root/.ssh/authorized_keys when present (interactive mode also
# accepts a key pasted at the prompt).

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
	local partuuid
	partuuid=$(blkid -s PARTUUID -o value "$part" || true)

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
			# Merge instead of dropping: packages may install into /sbin.
			cp -a "$mnt/$s/." "$mnt/usr/$s/"
			rm -rf "${mnt:?}/$s"
			ln -s "usr/$s" "${mnt:?}/$s"
		else
			ln -s "usr/$s" "${mnt:?}/$s"
		fi
	done
	if [ -d "$mnt/lib64" ] && [ ! -L "$mnt/lib64" ]; then
		cp -a "$mnt/lib64/." "$mnt/lib/"
		rm -rf "${mnt:?}/lib64"
	fi
	ln -sfn lib "$mnt/lib64"
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"
	rm -f "$mnt/sbin/sbin" "$mnt/usr/sbin/sbin"

	log "creating the user account"
	local user pass
	user="${ZIGNOS_USER:-}"
	pass="${ZIGNOS_PASSWORD:-}"
	if [ "$YES" = 1 ]; then
		user="${user:-zignos}"
		pass="${pass:-zignos}"
		echo "zignos-install: creating user '$user' (ZIGNOS_USER/ZIGNOS_PASSWORD override)"
	else
		[ -n "$user" ] || read -r -p "Username [zignos]: " user
		[ -n "$user" ] || user=zignos
		if [ -z "$pass" ]; then
			local p1 p2
			while :; do
				read -r -s -p "Password for $user: " p1; echo
				read -r -s -p "Repeat password: " p2; echo
				[ -n "$p1" ] && [ "$p1" = "$p2" ] && break
				echo "empty or mismatched password, try again" >&2
			done
			pass="$p1"
		fi
	fi
	# The single-quoted script runs inside the target chroot, so $1 is
	# expanded there (not by this shell).
	# shellcheck disable=SC2016
	chroot "$mnt" /bin/bash -c '
		set -e
		command -v useradd >/dev/null 2>&1
		getent group wheel >/dev/null || groupadd -g 10 wheel
		id -u "$1" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$1"
	' _ "$user"
	printf '%s:%s\n' "$user" "$pass" | chroot "$mnt" chpasswd

	# SSH key for the new user: reuse root's authorized_keys (the usual
	# "install from the machine you administer" flow); interactive mode
	# also allows pasting one when root has no keys.
	log "installing SSH authorized_keys for $user"
	local keys=""
	if [ -s /root/.ssh/authorized_keys ]; then
		keys=/root/.ssh/authorized_keys
	elif [ "$YES" != 1 ]; then
		local key=""
		echo "Paste an SSH public key for $user (empty to skip):"
		read -r key || key=""
		if [ -n "$key" ]; then
			mkdir -p /tmp/zignos-install-key
			printf '%s\n' "$key" > /tmp/zignos-install-key/authorized_keys
			keys=/tmp/zignos-install-key/authorized_keys
		fi
	fi
	if [ -n "$keys" ]; then
		local uid gid
		uid=$(chroot "$mnt" id -u "$user")
		gid=$(chroot "$mnt" id -g "$user")
		install -d -m 700 -o "$uid" -g "$gid" "$mnt/home/$user/.ssh"
		install -m 600 -o "$uid" -g "$gid" "$keys" "$mnt/home/$user/.ssh/authorized_keys"
		echo "installed authorized_keys for $user"
	else
		echo "no SSH key installed for $user (password login only)"
	fi

	log "writing /etc/fstab (PARTUUID-based)"
	# No initramfs: the kernel has already mounted / read-only when OpenRC
	# starts, so a boot-time fsck cannot run. pass 0 skips it.
	printf 'PARTUUID=%s / ext4 defaults 0 0\n' "$partuuid" > "$mnt/etc/fstab"
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
	echo "Boot from $DISK and log in as $user (root remains available on the console)."
	echo "SSH: ssh $user@<host>  (root SSH login is disabled)"
}

main "$@"
