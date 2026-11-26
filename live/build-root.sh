#!/bin/sh
# Build the ZIGNOS Live root, initramfs, squashfs and EFI boot image.
# Run as root. The ISO itself is assembled afterwards by make-iso.py.
set -e

ROOT=${ROOT:-/var/tmp/live-root}
BUILD=${BUILD:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
OUT=${OUT:-/var/tmp/live-iso}
KVER=${KVER:-7.3.5}
MKSQUASHFS=${MKSQUASHFS:-/var/tmp/squashfs-tools-squashfs-tools-4.6.1/squashfs-tools/mksquashfs}

log() { printf '\n== %s\n' "$*"; }
die() { printf 'build-root: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$ROOT" ] || die "missing live root $ROOT"
[ -x "$MKSQUASHFS" ] || die "missing mksquashfs: $MKSQUASHFS"
[ -f "/boot/vmlinuz-$KVER" ] || die "missing /boot/vmlinuz-$KVER"

log "configuring the live root"
echo zignos-live > "$ROOT/etc/hostname"
cat > "$ROOT/etc/motd" <<'EOF'
Welcome to ZIGNOS Live (2026.11.24-alpha)

This is a live environment. The system runs from a read-only squashfs
image with a writable tmpfs overlay; changes are lost on reboot.

  zpkg          package manager
  root shell    available on ttyS0 (serial) and tty1 (VGA)

Documentation: https://studio-nosa-tech.github.io/docs/
EOF
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="ZIGNOS 2026.11.24-alpha Live"/' "$ROOT/etc/os-release"
grep -q '^VARIANT_ID=' "$ROOT/etc/os-release" || echo 'VARIANT_ID=live' >> "$ROOT/etc/os-release"

# Live account (UID/GID 1000). The serial console autologs in as root for
# rescue/install work; the VGA console autologs in as live.
grep -q '^live:' "$ROOT/etc/passwd" ||
	echo 'live:x:1000:1000:ZIGNOS Live:/home/live:/bin/bash' >> "$ROOT/etc/passwd"
grep -q '^live:' "$ROOT/etc/group" || echo 'live:x:1000:' >> "$ROOT/etc/group"
grep -q '^live:' "$ROOT/etc/shadow" || echo 'live::20777:0:99999:7:::' >> "$ROOT/etc/shadow"
for g in wheel audio video render input; do
	awk -F: -v g="$g" 'BEGIN{OFS=":"} $1==g { if ($4=="") $4="live"; else if ($4 !~ /(^|,)live(,|$)/) $4=$4",live" } {print}' \
		"$ROOT/etc/group" > "$ROOT/etc/group.new"
	mv "$ROOT/etc/group.new" "$ROOT/etc/group"
done
mkdir -p "$ROOT/home/live"
cat > "$ROOT/home/live/.bashrc" <<'EOF'
PS1='\[\e[1;35m\]live@zignos\[\e[0m\]:\w\$ '
export EDITOR=vi
EOF
chown -R 1000:1000 "$ROOT/home/live"

# The live root is an overlay, not a block device: drop the services that
# expect a root entry in /etc/fstab.
rm -f "$ROOT/etc/runlevels/boot/fsck" "$ROOT/etc/runlevels/boot/root" \
	"$ROOT/etc/runlevels/boot/root-rw"

# Root is passwordless in the live session; the serial console uses it.
sed -i 's/^root:!:/root::/' "$ROOT/etc/shadow"
sed -i 's/command_args_foreground="--noclear tty1 linux"/command_args_foreground="--autologin live --noclear tty1 linux"/' \
	"$ROOT/etc/init.d/console-vga"
sed -i 's/command_args_foreground="ttyS0 115200 vt100"/command_args_foreground="--autologin root ttyS0 115200 vt100"/' \
	"$ROOT/etc/init.d/console"

log "building the live initramfs"
IT=/var/tmp/live-initramfs
rm -rf "$IT"
mkdir -p "$IT"/{bin,sbin,etc,proc,sys,dev,run,tmp,var/tmp,newroot} \
	"$IT/lib/modules/$KVER/kernel/fs/squashfs" \
	"$IT/lib/modules/$KVER/kernel/fs/overlayfs"
cp "$ROOT/bin/busybox" "$IT/bin/busybox"
chmod 755 "$IT/bin/busybox"
"$IT/bin/busybox" --install -s "$IT/bin" 2>/dev/null || true
for l in "$IT"/bin/*; do
	[ -L "$l" ] || continue
	if [ "$(readlink "$l")" = "$IT/bin/busybox" ]; then
		ln -sfn /bin/busybox "$l"
	fi
done
for a in sh mount umount switch_root blkid mdev modprobe insmod sleep cat echo; do
	[ -e "$IT/bin/$a" ] || ln -sf /bin/busybox "$IT/bin/$a"
done
cp "/lib/modules/$KVER/kernel/fs/squashfs/squashfs.ko" \
	"$IT/lib/modules/$KVER/kernel/fs/squashfs/"
cp "/lib/modules/$KVER/kernel/fs/overlayfs/overlay.ko" \
	"$IT/lib/modules/$KVER/kernel/fs/overlayfs/"
depmod -b "$IT" "$KVER" 2>/dev/null || true
cp "$BUILD/init" "$IT/init"
chmod 755 "$IT/init"
mkdir -p "$OUT/boot" "$OUT/live"
( cd "$IT" && find . -print | LC_ALL=C sort | "$IT/bin/busybox" cpio -o -H newc ) |
	gzip -n -9 > "$OUT/boot/initramfs.img"

log "building the live squashfs"
"$MKSQUASHFS" "$ROOT" "$OUT/live/rootfs.squashfs" \
	-noappend -comp zstd -b 1M -no-progress

log "building the EFI boot image"
cp "/boot/vmlinuz-$KVER" "$OUT/boot/vmlinuz"
mkdir -p "$OUT/EFI/BOOT"
grub-mkstandalone -O x86_64-efi -o "$OUT/EFI/BOOT/BOOTX64.EFI" \
	--modules="iso9660 search search_fs_file linux echo normal part_gpt part_msdos" \
	--locales="" --themes="" "boot/grub/grub.cfg=$BUILD/grub.cfg"
dd if=/dev/zero of="$OUT/efi.img" bs=1M count=8 status=none
mkfs.vfat -F 16 "$OUT/efi.img" >/dev/null
mkdir -p /mnt/zignos-live-efi
mount -o loop "$OUT/efi.img" /mnt/zignos-live-efi
mkdir -p /mnt/zignos-live-efi/EFI/BOOT
cp "$OUT/EFI/BOOT/BOOTX64.EFI" /mnt/zignos-live-efi/EFI/BOOT/
sync
umount /mnt/zignos-live-efi
rmdir /mnt/zignos-live-efi
chmod -R a+rX "$OUT"
echo "live root build complete: $OUT"
