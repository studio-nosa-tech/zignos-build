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
	# shellcheck disable=SC2012  # vmlinuz names are well-behaved
	local f
	f=$(find /mnt/lfs/boot -name 'vmlinuz*' -type f 2>/dev/null | sort | tail -1) \
		|| die "no kernel in /mnt/lfs/boot - build the linux recipe first"
	[ -n "$f" ] || die "no kernel in /mnt/lfs/boot - build the linux recipe first"
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
			# $(uname -r) must stay literal: it runs in the guest shell.
			# shellcheck disable=SC2016
			# timeout cannot run a shell function, so pass the function
			# definition into a child bash.
			{ sleep 25; echo 'echo ZIGNOS-BOOT-OK $(uname -r)'; sleep 5; } \
				| timeout 150 bash -c "$(declare -f qemu_cmd)
qemu_cmd" > "$out" 2>&1 || true
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
