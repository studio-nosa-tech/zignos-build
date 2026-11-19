#!/bin/bash
# ZIGNOS bootstrap stage2 — runs INSIDE the chroot as root.
# Phase 1 builds the bootstrap core (glibc -> toolchain -> enough userland
# for zpkg and Go) with a hardcoded list: this phase predates zpkg and the
# recipe tree, so it cannot come from base.list.
# Phase 2 applies zignos-build/base.list — the canonical rolling base set.
# zpkg skips what phase 1 installed, so the two share the same DB.
#
# Copied to /tmp by bootstrap.sh and run via chroot.
# Requires: /sources/zignos-recipes (recipe tree), /sources/base.list,
# /sources/zignos-zpkg (source snapshot), /opt/go-bootstrap (Go bootstrap),
# /usr/bin/zpkg (static host build), /var/cache/zpkg (seeded source cache).

set -euo pipefail

# bubblewrap is not available until base.list has been built, so bootstrap
# runs without the build sandbox. The installed system uses it by default.
export ZPKG_SANDBOX=off

log() { printf '\n== %s\n' "$*"; }

CHANNEL="${CHANNEL:-stable}"
case "$CHANNEL" in
	stable|testing|unstable) ;;
	*) printf 'stage2: invalid CHANNEL=%s\n' "$CHANNEL" >&2; exit 1 ;;
esac

log "stage2 phase 1: bootstrap core (hardcoded, pre-zpkg) [$CHANNEL]"
export ZPKG_ROOT=/
export ZPKG_CHANNEL="$CHANNEL"
export ZPKG_REPOS="/sources/zignos-recipes/$CHANNEL/core:/sources/zignos-recipes/$CHANNEL/main"

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

log "stage2 phase 2: apply base.list (the rolling base set)"
[ -r /sources/base.list ] || { echo "stage2: /sources/base.list missing" >&2; exit 1; }
# Unquoted on purpose: one argument per package (SC2046).
# shellcheck disable=SC2046
zpkg install $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /sources/base.list)

log "finalize"
rm -rf /opt/go-bootstrap
cat > /etc/zignos-release <<'EOF'
NAME="ZIGNOS"
PRETTY_NAME="ZIGNOS (Beyond the Limits.)"
ID=zignos
EOF
cat /etc/zignos-release

printf '\n== stage2 complete: ZIGNOS base system is up ==\n'
