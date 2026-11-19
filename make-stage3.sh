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
CHANNEL="${CHANNEL:-stable}"
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=release.conf
# shellcheck disable=SC1091
[ -f "$DIR/release.conf" ] && . "$DIR/release.conf"
RELEASE="${RELEASE:-$(date -u +%Y.%m.%d)-alpha}"
STAGE3_REVISION="${STAGE3_REVISION:-0}"
AVAILABILITY="${AVAILABILITY:-coming-soon}"
REVISION="r$STAGE3_REVISION"
ZIGNOS_DIR="${ZIGNOS_DIR:-$(cd "$DIR/.." && pwd)}"
OUT="${OUT:-$(pwd)/zignos-stage3-$(date +%Y%m%d)-$REVISION-x86_64.tar.xz}"
WORK=""
VFS_MOUNTED=0

log() { printf '\n== %s\n' "$*"; }
die() { printf 'make-stage3: %s\n' "$*" >&2; exit 1; }

# Portable checksum file: "hash  name", no absolute build path.
write_sha256() {
	local f=$1
	(cd "$(dirname "$f")" && sha256sum "$(basename "$f")") > "$f.sha256"
}

case "$CHANNEL" in
	stable|testing|unstable) ;;
	*) die "invalid CHANNEL=$CHANNEL (use stable, testing or unstable)" ;;
esac

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
	command -v python3 >/dev/null 2>&1 || die "python3 is required for the release manifest"

	# base.list names top-level packages only (Gentoo-style minimal base).
	# The allowed set is their transitive closure — dependencies and build
	# dependencies included — minus the kernel and bootloader, which are the
	# user's job inside the chroot. The closure is resolved with the tree's
	# own zpkg and recipe tree after the copy.
	local names all_names base_closure
	all_names=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$DIR/base.list")
	names=$(printf '%s\n' "$all_names" | grep -vxE 'linux|grub' | tr '\n' ' ')
	all_names=$(printf '%s\n' "$all_names" | tr '\n' ' ')
	[ -n "$names" ] || die "empty package list"

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

	# Ship only the selected channel, but keep the channel directory so
	# zpkg can find it (and so testing/unstable can be added by sync later).
	[ -d "$ZIGNOS_ROOT/sources/zignos-recipes/$CHANNEL/core" ] ||
		die "channel $CHANNEL not found under $ZIGNOS_ROOT/sources/zignos-recipes"
	# Replace the copy inherited from the bootstrap root: cp -a into an
	# existing directory would nest the channel (stable/stable).
	rm -rf "$WORK/usr/share/zignos/recipes"
	mkdir -p "$WORK/usr/share/zignos/recipes"
	cp -a "$ZIGNOS_ROOT/sources/zignos-recipes/$CHANNEL" "$WORK/usr/share/zignos/recipes/$CHANNEL"
	rm -rf "$WORK/usr/share/zignos/recipes/$CHANNEL/.git"
	mkdir -p "$WORK/etc/zpkg"
	cat > "$WORK/etc/zpkg/make.conf" <<EOF
# zpkg build options
# Release channel: stable, testing or unstable.
CHANNEL=$CHANNEL
EOF
	local allowed
	# $names is intentionally unquoted: one argument per package.
	# shellcheck disable=SC2086
	allowed=$(chroot "$WORK" /usr/bin/env \
		ZPKG_CHANNEL="$CHANNEL" \
		ZPKG_REPOS="/usr/share/zignos/recipes/$CHANNEL/core:/usr/share/zignos/recipes/$CHANNEL/main:/usr/share/zignos/recipes/$CHANNEL/desktop" \
		/usr/bin/zpkg depends $names | tr '\n' ' ')
	[ -n "$allowed" ] || die "cannot resolve the base package closure"

	# Full base closure including linux/grub, recorded in the release
	# manifest. Best-effort: metadata must not fail the stage3 build.
	# shellcheck disable=SC2086
	base_closure=$(chroot "$WORK" /usr/bin/env \
		ZPKG_CHANNEL="$CHANNEL" \
		ZPKG_REPOS="/usr/share/zignos/recipes/$CHANNEL/core:/usr/share/zignos/recipes/$CHANNEL/main:/usr/share/zignos/recipes/$CHANNEL/desktop" \
		/usr/bin/zpkg depends $all_names 2>/dev/null | wc -l) || base_closure=""
	[ "${base_closure:-0}" -gt 0 ] 2>/dev/null || base_closure=""

	# Remove the kernel and bootloader first: packages they depend on (bc,
	# elfutils, initramfs, efibootmgr, ...) are "extras" from the stage3
	# point of view, and zpkg refuses to remove a package that a still-
	# installed package depends on.
	chroot "$WORK" /usr/bin/zpkg remove linux grub

	local installed extra p
	installed=$(chroot "$WORK" /usr/bin/zpkg list | awk '{print $1}')
	extra=""
	for p in $installed; do
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
	rm -f "$WORK/var/lib/zpkg/.security.json"
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

	log "writing stage3 metadata"
	local npkg
	npkg=$(chroot "$WORK" /usr/bin/zpkg list | wc -l)
	cat > "$WORK/etc/zignos-stage3" <<EOF
ZIGNOS stage3 (x86_64)
built: $(date -u +%Y-%m-%d)
packages: $npkg
kernel: not installed — run 'zpkg install linux grub' inside the chroot
recipes: /usr/share/zignos/recipes
channel: $CHANNEL
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
	write_sha256 "$OUT"

	# Release assets and the machine-readable manifest. The stage3 tarball
	# cannot contain its own hash, so the manifest is a sidecar.
	local outdir asset_date recipes_out zpkg_out zpkg_version
	outdir=$(dirname "$OUT")
	asset_date=$(date -u +%Y%m%d)
	zpkg_version=$(cat "$WORK/var/lib/zpkg/zpkg/version" 2>/dev/null || true)
	recipes_out="${RECIPES_OUT:-$outdir/zignos-recipes-$asset_date-$REVISION.tar.xz}"
	zpkg_out="${ZPKG_OUT:-$outdir/zpkg-${zpkg_version:-unknown}-x86_64}"

	local -a artifacts=()
	if [ "${MAKE_ASSETS:-1}" = 1 ]; then
		if [ -d "$ZIGNOS_ROOT/sources/zignos-recipes" ]; then
			log "packing recipes $recipes_out"
			local rtmp
			rtmp=$(mktemp -d /var/tmp/zignos-recipes-release.XXXXXX)
			mkdir -p "$rtmp/usr/share/zignos"
			cp -a "$ZIGNOS_ROOT/sources/zignos-recipes" "$rtmp/usr/share/zignos/recipes"
			rm -rf "$rtmp/usr/share/zignos/recipes/.git"
			rm -f "$recipes_out"
			tar -C "$rtmp" -cJf "$recipes_out" ./usr
			rm -rf "$rtmp"
			write_sha256 "$recipes_out"
			artifacts+=(--artifact "recipes=$recipes_out")
		else
			log "warning: no $ZIGNOS_ROOT/sources/zignos-recipes; skipping recipes tarball"
		fi
		if [ -x "$WORK/usr/bin/zpkg" ]; then
			cp "$WORK/usr/bin/zpkg" "$zpkg_out"
			chmod 755 "$zpkg_out"
			write_sha256 "$zpkg_out"
			artifacts+=(--artifact "zpkg=$zpkg_out")
		fi
	fi

	log "writing release manifest"
	local -a manifest_args=(
		generate
		--release "$RELEASE"
		--revision "$REVISION"
		--channel "$CHANNEL"
		--availability "$AVAILABILITY"
		--build-date "$(date -u +%Y-%m-%d)"
		--stage3 "$OUT"
		--db-root "$WORK/var/lib/zpkg"
		--recipes "$ZIGNOS_ROOT/sources/zignos-recipes"
		--base-list "$DIR/base.list"
		--source-repo "zpkg=$ZIGNOS_ROOT/sources/zignos-zpkg"
		--source-repo "recipes=$ZIGNOS_ROOT/sources/zignos-recipes"
		--source-repo "zignos=$ZIGNOS_DIR/zignos"
		--source-repo "build=$ZIGNOS_DIR/zignos-build"
		--boot-tests "${BOOT_TESTS:-/var/tmp/zignos-boot-tests.json}"
		--out "$OUT.release.json"
	)
	[ -n "${base_closure:-}" ] && manifest_args+=(--base-closure "$base_closure")
	local -a commit_args=()
	[ -n "${ZIGNOS_COMMIT:-}" ] && commit_args+=(--commit "zignos=$ZIGNOS_COMMIT")
	[ -n "${ZPKG_COMMIT:-}" ] && commit_args+=(--commit "zpkg=$ZPKG_COMMIT")
	[ -n "${RECIPES_COMMIT:-}" ] && commit_args+=(--commit "recipes=$RECIPES_COMMIT")
	[ -n "${BUILD_COMMIT:-}" ] && commit_args+=(--commit "build=$BUILD_COMMIT")
	if [ ${#commit_args[@]} -gt 0 ]; then
		manifest_args+=("${commit_args[@]}")
	fi
	if [ ${#artifacts[@]} -gt 0 ]; then
		manifest_args+=("${artifacts[@]}")
	fi
	python3 "$DIR/release-manifest.py" "${manifest_args[@]}"
	write_sha256 "$OUT.release.json"

	log "done: $OUT ($(du -h "$OUT" | cut -f1), $npkg packages)"
	echo "Manifest: $OUT.release.json"
	echo "Install: tar -xpf $OUT -C <target>"
	echo "Enter:   zignos-enter.sh <target>"
	echo "Then:    zpkg install linux grub"
}

main "$@"
