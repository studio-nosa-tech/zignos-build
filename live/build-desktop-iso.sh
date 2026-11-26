#!/bin/sh
# Build the desktop Live ISO from /var/tmp/desktop-live/root.
# Run as root; the ISO is assembled afterwards by make-iso.py.
set -e

ROOT=/var/tmp/desktop-live/root
OUT=/var/tmp/desktop-live/iso
BUILD=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
KVER=7.3.5
MKSQUASHFS=/var/tmp/squashfs-tools-squashfs-tools-4.6.1/squashfs-tools/mksquashfs

log() { printf '\n== %s\n' "$*"; }
die() { echo "build-desktop-iso: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -x "$ROOT/usr/bin/plasmashell" ] || die "no Plasma in $ROOT"
[ -x "$MKSQUASHFS" ] || die "missing mksquashfs"
[ -f "/boot/vmlinuz-$KVER" ] || die "missing /boot/vmlinuz-$KVER"

rm -rf "$OUT"
mkdir -p "$OUT"/{boot,live,EFI/BOOT}

log "building the live initramfs"
IT=/var/tmp/desktop-initramfs
rm -rf "$IT"
mkdir -p "$IT"/{bin,sbin,etc,proc,sys,dev,run,tmp,var/tmp,newroot} \
	"$IT/lib/modules/$KVER/kernel/fs/squashfs" \
	"$IT/lib/modules/$KVER/kernel/fs/overlayfs"
cp /bin/busybox "$IT/bin/busybox"
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
( cd "$IT" && find . -print | LC_ALL=C sort | "$IT/bin/busybox" cpio -o -H newc ) |
	gzip -n -9 > "$OUT/boot/initramfs.img"

log "building the desktop squashfs (gzip)"
"$MKSQUASHFS" "$ROOT" "$OUT/live/rootfs.squashfs" \
	-noappend -comp gzip -b 1M -no-progress

# BIOS El Torito: GRUB's eltorito.img finds /boot/grub on the ISO, so the
# whole i386-pc module tree and the config must be present.
log "staging the BIOS GRUB tree"
[ -d "$ROOT/usr/lib/grub/i386-pc" ] ||
	die "no i386-pc GRUB modules in $ROOT (rebuild grub with USE=bios)"
# grub-make install does not ship eltorito.img; generate it from the
# installed modules (cdboot.img + core) when a fresh tree lacks it.
if [ ! -f "$ROOT/usr/lib/grub/i386-pc/eltorito.img" ]; then
	log "generating eltorito.img"
	grub-mkimage -O i386-pc-eltorito 		-d "$ROOT/usr/lib/grub/i386-pc" -p /boot/grub 		-o "$ROOT/usr/lib/grub/i386-pc/eltorito.img" iso9660 biosdisk
fi
mkdir -p "$OUT/boot/grub/i386-pc"
cp "$BUILD/grub.cfg" "$OUT/boot/grub/grub.cfg"
cp -a "$ROOT/usr/lib/grub/i386-pc/." "$OUT/boot/grub/i386-pc/"

log "building the EFI boot image"
cp "/boot/vmlinuz-$KVER" "$OUT/boot/vmlinuz"
grub-mkstandalone -O x86_64-efi -o "$OUT/EFI/BOOT/BOOTX64.EFI" \
	--modules="iso9660 search search_fs_file linux echo normal part_gpt part_msdos" \
	--locales="" --themes="" "boot/grub/grub.cfg=$BUILD/grub.cfg"
dd if=/dev/zero of="$OUT/efi.img" bs=1M count=16 status=none
mkfs.vfat -F 16 "$OUT/efi.img" >/dev/null
mkdir -p /mnt/zignos-desktop-efi
mount -o loop "$OUT/efi.img" /mnt/zignos-desktop-efi
mkdir -p /mnt/zignos-desktop-efi/EFI/BOOT
cp "$OUT/EFI/BOOT/BOOTX64.EFI" /mnt/zignos-desktop-efi/EFI/BOOT/
sync
umount /mnt/zignos-desktop-efi
rmdir /mnt/zignos-desktop-efi
chmod -R a+rX "$OUT"
echo "desktop live root build complete: $OUT"
