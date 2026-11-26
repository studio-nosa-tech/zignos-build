#!/usr/bin/env python3
"""Assemble the ZIGNOS Live ISO (BIOS El Torito + UEFI El Torito)."""
import os
import sys

import pycdlib

TREE = os.environ.get("TREE", "/var/tmp/live-iso")
OUT = sys.argv[1] if len(sys.argv) > 1 else "/var/tmp/zignos-live.iso"


def add_i386_pc(iso):
    """Add boot/grub/{grub.cfg,i386-pc/*} for the BIOS El Torito entry."""
    grub_dir = os.path.join(TREE, "boot/grub")
    pc_dir = os.path.join(grub_dir, "i386-pc")
    iso.add_directory("/BOOT/GRUB", rr_name="grub", joliet_path="/boot/grub")
    iso.add_directory(
        "/BOOT/GRUB/I386_PC", rr_name="i386-pc", joliet_path="/boot/grub/i386-pc"
    )
    iso.add_file(
        os.path.join(grub_dir, "grub.cfg"),
        "/BOOT/GRUB/GRUB.CFG;1",
        rr_name="grub.cfg",
        joliet_path="/boot/grub/grub.cfg",
    )
    for name in sorted(os.listdir(pc_dir)):
        path = os.path.join(pc_dir, name)
        if not os.path.isfile(path):
            continue
        iso.add_file(
            path,
            "/BOOT/GRUB/I386_PC/%s;1" % name.upper().replace("-", "_"),
            rr_name=name,
            joliet_path="/boot/grub/i386-pc/%s" % name,
        )


def main():
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="ZIGNOSLIVE")
    iso.add_directory("/BOOT", rr_name="boot", joliet_path="/boot")
    iso.add_directory("/LIVE", rr_name="live", joliet_path="/live")

    iso.add_file(
        os.path.join(TREE, "boot/vmlinuz"),
        "/BOOT/VMLINUZ.;1",
        rr_name="vmlinuz",
        joliet_path="/boot/vmlinuz",
    )
    iso.add_file(
        os.path.join(TREE, "boot/initramfs.img"),
        "/BOOT/INITRAM.IMG;1",
        rr_name="initramfs.img",
        joliet_path="/boot/initramfs.img",
    )
    iso.add_file(
        os.path.join(TREE, "live/rootfs.squashfs"),
        "/LIVE/ROOTFS.SQU;1",
        rr_name="rootfs.squashfs",
        joliet_path="/live/rootfs.squashfs",
    )
    iso.add_file(
        os.path.join(TREE, "efi.img"),
        "/EFI.IMG;1",
        rr_name="efi.img",
        joliet_path="/efi.img",
    )

    # BIOS first (default entry), UEFI second. The firmware picks the
    # entry that matches its platform id.
    add_i386_pc(iso)
    iso.add_eltorito(
        "/BOOT/GRUB/I386_PC/ELTORITO.IMG;1",
        platform_id=0,
        media_name="noemul",
        boot_load_size=4,
        boot_info_table=True,
    )
    iso.add_eltorito("/EFI.IMG;1", efi=True, platform_id=0xEF)

    iso.write(OUT)
    iso.close()
    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
