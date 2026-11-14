#!/bin/bash
# ZIGNOS bootstrap orchestrator (skeleton).
#
# Builds the ZIGNOS base system from recipes in three stages:
#   stage0 — cross toolchain (binutils pass1 / gcc pass1 / kernel headers /
#            glibc), driven by a host-built zpkg
#   stage1 — temp chroot: rebuild the toolchain natively, build Go from
#            source, rebuild zpkg (self-hosting starts here)
#   stage2 — assemble the full base system with the chroot zpkg
#
# Reference: LFS 13.1 (https://www.linuxfromscratch.org/).
#
# Status: skeleton. Stage functions are placeholders — implement in M2
# (see zignos/docs/roadmap.md).

set -euo pipefail

ZIGNOS_MNT="${ZIGNOS_MNT:-/mnt/zignos}"         # build mount point
ZIGNOS_REPOS="${ZIGNOS_REPOS:-$PWD/../zignos-recipes/core}"
ZIGNOS_ZPKG="${ZIGNOS_ZPKG:-$PWD/../zpkg}"      # host zpkg checkout

die() { echo "bootstrap: $*" >&2; exit 1; }

require_env() {
	[ -d "$ZIGNOS_REPOS" ] || die "ZIGNOS_REPOS not a directory: $ZIGNOS_REPOS"
	[ -d "$ZIGNOS_ZPKG" ] || die "ZIGNOS_ZPKG not a directory: $ZIGNOS_ZPKG"
	# TODO(M2): check host prerequisites (go, bash, tar, curl, sha256sum, root).
}

host_zpkg() {
	# TODO(M2): go build -o "$ZIGNOS_MNT/hostbin/zpkg" ./cmd/zpkg in $ZIGNOS_ZPKG
	echo "TODO(M2): build host zpkg from $ZIGNOS_ZPKG"
}

stage0_cross_toolchain() {
	# TODO(M2): binutils pass1, gcc pass1, kernel headers, glibc (cross).
	echo "TODO(M2): stage0 — cross toolchain"
}

stage1_temp_chroot() {
	# TODO(M2): binutils pass2, gcc pass2, glibc rebuild, then
	# Go (C-only bootstrap) and zpkg rebuild inside the chroot.
	echo "TODO(M2): stage1 — temp chroot"
}

stage2_base_system() {
	# TODO(M2): run the chroot zpkg over the core recipes
	# (busybox, coreutils, tar, gzip, e2fsprogs, ...).
	echo "TODO(M2): stage2 — base system"
}

main() {
	require_env
	host_zpkg
	stage0_cross_toolchain
	stage1_temp_chroot
	stage2_base_system
	echo "bootstrap: done (skeleton — nothing built yet)"
}

main "$@"
