#!/bin/bash
# ZIGNOS boot test in QEMU.
#
#   qemu-test.sh          - boot interactively (-nographic serial console)
#   qemu-test.sh check    - boot once, require the ZIGNOS banner and a
#                           working shell echo, exit 0/1 (used by CI/manual)
#
# Uses direct kernel boot (no bootloader yet - GRUB comes with M4).

set -euo pipefail

IMG="${IMG:-$(pwd)/zignos-rootfs.img}"
KERNEL="${KERNEL:-}"
MEM="${MEM:-1G}"
SMP="${SMP:-2}"
MODE="${1:-run}"

die() { echo "qemu-test: $*" >&2; exit 1; }

pick_kernel() {
	[ -n "$KERNEL" ] && return
	local f
	f=$(ls -t /mnt/lfs/boot/vmlinuz-* 2>/dev/null | head -1) \
		|| die "no kernel in /mnt/lfs/boot - build the linux recipe first"
	KERNEL="$f"
}

qemu_cmd() {
	# kvm if available, otherwise TCG fallback
	local accel="tcg"
	[ -w /dev/kvm ] && accel="kvm"
	qemu-system-x86_64 \
		-machine accel="$accel" \
		-m "$MEM" -smp "$SMP" \
		-drive file="$IMG",format=raw,if=virtio \
		-kernel "$KERNEL" \
		-append "root=/dev/vda console=ttyS0" \
		-nographic -no-reboot
}

main() {
	[ -f "$IMG" ] || die "rootfs image not found: $IMG (run make-image.sh first)"
	pick_kernel
	log_kernel="$KERNEL"

	case "$MODE" in
		run)
			echo "kernel: $log_kernel"
			qemu_cmd
			;;
		check)
			local out
			out=$(mktemp)
			# type a marker command into the booted shell via stdin, then quit
			{ sleep 8; echo 'echo ZIGNOS-BOOT-OK $(uname -r)'; sleep 4; } \
				| timeout 90 qemu_cmd > "$out" 2>&1 || true
			if grep -q "ZIGNOS-BOOT-OK" "$out" && grep -q "Welcome to ZIGNOS" "$out"; then
				echo "BOOT CHECK PASSED"
				grep -a "ZIGNOS-BOOT-OK" "$out"
				exit 0
			fi
			die "boot check failed - see $out"
			;;
		*)
			die "usage: qemu-test.sh [run|check]"
			;;
	esac
}

main "$@"
