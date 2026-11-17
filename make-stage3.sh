#!/bin/bash
# Build a ZIGNOS stage3 tarball — the Gentoo/Exherbo-style minimal base
# system that is unpacked onto a disk and chrooted into. It contains the
# base.list package set EXCEPT the kernel and bootloader; those are added
# afterwards inside the chroot with zpkg:
#
#   zpkg install linux grub
#
# The tree is copied from the bootstrap root and then brought down to the
# stage3 set with `zpkg remove` (non-base extras, linux, grub), so the
# package database in the tarball matches exactly what it contains.
#
#   make-stage3.sh
#   ZIGNOS_ROOT=/mnt OUT=/var/tmp/zignos-stage3.tar.xz make-stage3.sh

set -euo pipefail

ZIGNOS_ROOT="${ZIGNOS_ROOT:-/mnt}"
OUT="${OUT:-$(pwd)/zignos-stage3-$(date +%Y%m%d)-x86_64.tar.xz}"
DIR=$(cd "$(dirname "$0")" && pwd)
WORK=""
VFS_MOUNTED=0

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-stage3: %s\n' "$*" >&2; exit 1; }

# merge_dir <src> <dst>: copy entries missing from dst (usr wins).
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

cleanup() {
	local rc=$?
	if [ "$VFS_MOUNTED" = 1 ]; then
		for v in dev proc sys; do
			umount "$WORK/$v" 2>/dev/null || true
		done
	fi
	rm -rf "$WORK"
	exit $rc
}

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -x "$ZIGNOS_ROOT/usr/bin/zpkg" ] || die "$ZIGNOS_ROOT has no zpkg"
	[ -x "$ZIGNOS_ROOT/usr/bin/bash" ] || die "$ZIGNOS_ROOT does not look like a ZIGNOS tree"
	[ -f "$ZIGNOS_ROOT/etc/zignos-release" ] || die "$ZIGNOS_ROOT has no /etc/zignos-release"

	# base.list minus the packages that make this a *stage3*: the kernel
	# and bootloader are the user's job inside the chroot.
	local allowed
	allowed=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$DIR/base.list" |
		grep -vxE 'linux|grub' | tr '\n' ' ')
	[ -n "$allowed" ] || die "empty package list"

	WORK=$(mktemp -d /var/tmp/zignos-stage3.XXXXXX)
	trap cleanup EXIT

	log "copying $ZIGNOS_ROOT to $WORK"
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
		--exclude='./var/log/*' \
		--exclude='./var/lib/seedrng/*' \
		-cf - . | tar -C "$WORK" -xf -
	mkdir -p "$WORK"/{dev,proc,sys,run,tmp,var/tmp,var/log,var/lib/seedrng}

	log "removing packages that are not part of stage3"
	mount --bind /dev "$WORK/dev"
	mount -t proc proc "$WORK/proc"
	mount -t sysfs sysfs "$WORK/sys"
	VFS_MOUNTED=1

	local installed extra p
	installed=$(chroot "$WORK" /usr/bin/zpkg list | awk '{print $1}')
	extra=""
	for p in $installed; do
		# linux/grub are removed explicitly below.
		case "$p" in linux|grub) continue ;; esac
		case " $allowed " in
			*" $p "*) ;;
			*) extra="$extra $p" ;;
		esac
	done
	if [ -n "${extra// /}" ]; then
		log "extras:$extra"
		# shellcheck disable=SC2086
		chroot "$WORK" /usr/bin/zpkg remove $extra
	fi
	chroot "$WORK" /usr/bin/zpkg remove linux grub

	# make-image runs grub-mkimage inside the bootstrap tree, so an unowned
	# core.img can be left in /usr/lib/grub after the package is removed.
	# Same for any module build leftovers: a stage3 has neither.
	rm -rf "$WORK/usr/lib/grub" "$WORK/boot/grub" "$WORK/usr/lib/modules"

	for v in dev proc sys; do
		umount "$WORK/$v"
	done
	VFS_MOUNTED=0

	log "usr-merge layout"
	mkdir -p "$WORK"/usr/{bin,lib,sbin} "$WORK"/lib
	for s in bin lib sbin; do
		if [ -d "$WORK/$s" ] && [ ! -L "$WORK/$s" ]; then
			merge_dir "$WORK/$s" "$WORK/usr/$s"
			rm -rf "${WORK:?}/$s"
		fi
		ln -sfn "usr/$s" "$WORK/$s"
	done
	if [ -d "$WORK/lib64" ] && [ ! -L "$WORK/lib64" ]; then
		merge_dir "$WORK/lib64" "$WORK/lib"
		rm -rf "${WORK:?}/lib64"
	fi
	ln -sfn lib "$WORK/lib64"

	log "cleaning the stage3 root"
	rm -rf "$WORK/var/cache/zpkg" "$WORK/sources" "$WORK/opt"
	rm -rf "$WORK"/tmp/* "$WORK"/var/tmp/* "$WORK"/run/* "$WORK"/var/log/*
	rm -rf "$WORK"/var/lib/seedrng/*
	rm -f "$WORK"/etc/machine-id "$WORK"/var/lib/dbus/machine-id
	rm -rf "$WORK/root/.cache" "$WORK/root/.config/go" "$WORK/root/go"
	rm -f "$WORK"/root/.bash_history "$WORK"/root/.ssh/authorized_keys
	rm -rf "$WORK/var/lib/zpkg/.txn"
	rm -rf "${WORK:?}"/boot/*
	mkdir -p "$WORK"/{tmp,var/tmp,run,var/log,var/lib/seedrng,boot}
	chmod 1777 "$WORK/tmp" "$WORK/var/tmp"

	# The tarball is public-ish: lock root (set a password in the chroot)
	# and ship placeholder fstab/resolv.conf to fill in.
	sed -i 's/^root:[^:]*:/root:!:/' "$WORK/etc/shadow"
	cat > "$WORK/etc/fstab" <<'FSTAB'
# ZIGNOS stage3 — set the root filesystem device before booting.
# Use the filesystem UUID shown by blkid (the initramfs resolves root=UUID).
#UUID=00000000-0000-0000-0000-000000000000 / ext4 defaults 0 0
proc  /proc proc  defaults 0 0
sysfs /sys  sysfs defaults 0 0
FSTAB
	if [ -f "$ZIGNOS_ROOT/etc/resolv.conf" ]; then
		cp -L "$ZIGNOS_ROOT/etc/resolv.conf" "$WORK/etc/resolv.conf"
	else
		printf 'nameserver 1.1.1.1\n' > "$WORK/etc/resolv.conf"
	fi

	log "shipping the recipe tree and stage3 metadata"
	mkdir -p "$WORK/usr/share/zignos"
	cp -a "$ZIGNOS_ROOT/sources/zignos-recipes" "$WORK/usr/share/zignos/recipes"
	rm -rf "$WORK/usr/share/zignos/recipes/.git"
	local npkg
	npkg=$(chroot "$WORK" /usr/bin/zpkg list | wc -l)
	cat > "$WORK/etc/zignos-stage3" <<EOF
ZIGNOS stage3 (x86_64)
built: $(date -u +%Y-%m-%d)
packages: $npkg
kernel: not installed — run 'zpkg install linux grub' inside the chroot
recipes: /usr/share/zignos/recipes
EOF

	# No kernel, modules or bootloader files must have survived.
	if ls "$WORK"/boot/vmlinuz* >/dev/null 2>&1; then
		die "stage3 unexpectedly contains a kernel"
	fi
	[ ! -e "$WORK/usr/lib/modules" ] || die "stage3 unexpectedly contains modules"
	[ ! -e "$WORK/usr/lib/grub" ] || die "stage3 unexpectedly contains GRUB"

	log "packing $OUT"
	rm -f "$OUT"
	tar -C "$WORK" -cf - . | xz -T0 -6 > "$OUT"
	sha256sum "$OUT" > "$OUT.sha256"

	log "done: $OUT ($(du -h "$OUT" | cut -f1), $npkg packages)"
	echo "Install: tar -xpf $OUT -C <target>"
	echo "Enter:   zignos-enter.sh <target>"
	echo "Then:    zpkg install linux grub"
}

main "$@"
