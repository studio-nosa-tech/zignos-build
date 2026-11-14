#!/bin/bash
# ZIGNOS boot test in QEMU (skeleton).
#
# Status: skeleton — implement in M3 together with the rootfs image builder.

set -euo pipefail

ZIGNOS_IMG="${ZIGNOS_IMG:-./zignos-rootfs.img}"   # raw rootfs image
ZIGNOS_KERNEL="${ZIGNOS_KERNEL:-}"                # path to the built bzImage
ZIGNOS_MEM="${ZIGNOS_MEM:-2G}"
ZIGNOS_SMP="${ZIGNOS_SMP:-2}"

die() { echo "qemu-test: $*" >&2; exit 1; }

main() {
	[ -n "$ZIGNOS_KERNEL" ] || die "set ZIGNOS_KERNEL to the built bzImage"
	[ -f "$ZIGNOS_IMG" ] || die "rootfs image not found: $ZIGNOS_IMG"
	[ -f "$ZIGNOS_KERNEL" ] || die "kernel not found: $ZIGNOS_KERNEL"
	# TODO(M3): decide direct kernel boot vs bootloader (GRUB) testing.
	exec qemu-system-x86_64 \
		-m "$ZIGNOS_MEM" \
		-smp "$ZIGNOS_SMP" \
		-drive file="$ZIGNOS_IMG",format=raw \
		-kernel "$ZIGNOS_KERNEL" \
		-append "root=/dev/sda1 console=ttyS0" \
		-nographic
}

main "$@"
