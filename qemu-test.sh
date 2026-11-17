#!/bin/bash
# ZIGNOS boot test in QEMU.
#
#   qemu-test.sh          - boot interactively (-nographic serial console)
#   qemu-test.sh check    - boot once, require the OpenRC startup and a
#                           working shell echo, exit 0/1
#
# Default: boot the partitioned image via its GRUB bootloader.
# Set KERNEL=<bzImage> (plus IMG=/var/zignos.img) for direct kernel boot of
# the bootstrap tree, like the M3 flow did.
# Set UEFI=1 for a GPT/UEFI image: QEMU then boots OVMF (edk2) instead of
# SeaBIOS. OVMF_CODE/OVMF_VARS can override the firmware paths.

set -euo pipefail

IMG="${IMG:-$(pwd)/zignos-rootfs.img}"
KERNEL="${KERNEL:-}"   # empty = boot via the image's GRUB
MEM="${MEM:-1G}"
SMP="${SMP:-2}"
UEFI="${UEFI:-0}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
MODE="${1:-run}"

die() { echo "qemu-test: $*" >&2; exit 1; }

qemu_cmd() {
	local accel="tcg"
	[ -w /dev/kvm ] && accel="kvm"
	local kern_args=() fw_args=()
	if [ -n "$KERNEL" ]; then
		kern_args=(-kernel "$KERNEL" -append "root=/dev/vda console=ttyS0")
	fi
	if [ "$UEFI" = 1 ]; then
		local vars="/var/tmp/zignos-OVMF_VARS.fd"
		[ -f "$vars" ] || cp "$OVMF_VARS" "$vars"
		fw_args=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
			-drive "if=pflash,format=raw,file=$vars")
	fi
	# User-mode NIC with an SSH port forward (host 127.0.0.1:$SSH_PORT ->
	# guest 22) so dhcpcd/sshd can be exercised and the guest used remotely.
	qemu-system-x86_64 \
		-machine accel="$accel" \
		-m "$MEM" -smp "$SMP" \
		"${fw_args[@]}" \
		-drive file="$IMG",format=raw,if=virtio \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT:-2222}-:22" \
		-device virtio-net-pci,netdev=net0 \
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
			{ sleep 55
			  echo 'root'
			  sleep 4
			  echo 'zignos'
			  sleep 4
			  echo 'echo ZIGNOS-BOOT-OK $(uname -r)'
			  sleep 6
			} \
				| KERNEL="$KERNEL" IMG="$IMG" MEM="$MEM" SMP="$SMP" UEFI="$UEFI" \
				  OVMF_CODE="$OVMF_CODE" OVMF_VARS="$OVMF_VARS" \
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
