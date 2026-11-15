#!/bin/bash
# ZIGNOS boot test in QEMU.
#
#   qemu-test.sh          - boot interactively (-nographic serial console)
#   qemu-test.sh check    - boot once, require the OpenRC startup and a
#                           working shell echo, exit 0/1
#
# Default: boot the partitioned image via its GRUB bootloader.
# Set KERNEL=<bzImage> (plus IMG=/var/lfs.img) for direct kernel boot of
# the bootstrap tree, like the M3 flow did.

set -euo pipefail

IMG="${IMG:-$(pwd)/zignos-rootfs.img}"
KERNEL="${KERNEL:-}"   # empty = boot via the image's GRUB
MEM="${MEM:-1G}"
SMP="${SMP:-2}"
MODE="${1:-run}"

die() { echo "qemu-test: $*" >&2; exit 1; }

qemu_cmd() {
	local accel="tcg"
	[ -w /dev/kvm ] && accel="kvm"
	local kern_args=()
	if [ -n "$KERNEL" ]; then
		kern_args=(-kernel "$KERNEL" -append "root=/dev/vda console=ttyS0")
	fi
	qemu-system-x86_64 \
		-machine accel="$accel" \
		-m "$MEM" -smp "$SMP" \
		-drive file="$IMG",format=raw,if=virtio \
		"${kern_args[@]}" \
		-nographic -no-reboot
}

main() {
	[ -f "$IMG" ] || die "rootfs image not found: $IMG (run make-image.sh first)"
	if [ -n "$KERNEL" ]; then
		[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
	fi

	case "$MODE" in
		run)
			if [ -n "$KERNEL" ]; then
				echo "direct kernel boot: $KERNEL"
			else
				echo "GRUB boot: $IMG"
			fi
			qemu_cmd
			;;
		check)
			local out
			out=$(mktemp)
			# $(uname -r) must stay literal: it runs in the guest shell.
			# shellcheck disable=SC2016
			# timeout cannot run a shell function, so pass the function
			# definition into a child bash. Login: root / zignos (set at
			# bootstrap via chpasswd; change it on any real install).
			{ sleep 30
			  echo 'root'
			  sleep 4
			  echo 'zignos'
			  sleep 4
			  echo 'echo ZIGNOS-BOOT-OK $(uname -r)'
			  sleep 5
			} \
				| KERNEL="$KERNEL" IMG="$IMG" MEM="$MEM" SMP="$SMP" \
				timeout 200 bash -c "$(declare -f qemu_cmd)
qemu_cmd" > "$out" 2>&1 || true
			# Require the RESOLVED marker output (kernel version appended),
			# not just the echoed input line.
			if grep -qE "ZIGNOS-BOOT-OK [0-9]+\." "$out" && grep -q "OpenRC" "$out"; then
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
