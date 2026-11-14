#!/bin/bash
# ZIGNOS bootstrap stage2 — runs INSIDE the chroot as root.
# zpkg builds the final system from the core recipes: glibc -> compression
# libs -> toolchain (gmp/mpfr/mpc -> binutils -> gcc) -> userland ->
# go -> zpkg (self-hosting).
#
# Copied to /tmp by bootstrap.sh and run via chroot.
# Requires: /sources/zignos-recipes (recipe tree), /sources/zignos-zpkg
# (source snapshot), /opt/go-bootstrap (Go bootstrap), /usr/bin/zpkg
# (static host build), /var/cache/zpkg (seeded source cache).

set -euo pipefail

log() { printf '\n== %s\n' "$*"; }

log "stage2: zpkg builds the final system"
export ZPKG_REPOS=/sources/zignos-recipes/core
export ZPKG_ROOT=/

zpkg install \
	glibc \
	zlib bzip2 xz zstd \
	file flex pkgconf \
	gmp mpfr mpc \
	binutils \
	gcc \
	ncurses readline bash \
	pcre2 grep sed make \
	coreutils tar gzip busybox \
	go zpkg

log "post-glibc glue"
localedef -i C -f UTF-8 C.UTF-8
ldconfig

log "self-hosting check"
zpkg --help >/dev/null
go version

log "finalize"
rm -rf /opt/go-bootstrap
cat > /etc/zignos-release <<'EOF'
NAME="ZIGNOS"
PRETTY_NAME="ZIGNOS (Beyond the Limits.)"
ID=zignos
EOF
cat /etc/zignos-release

printf '\n== stage2 complete: ZIGNOS base system is up ==\n'
