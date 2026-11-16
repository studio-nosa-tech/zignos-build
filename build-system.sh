#!/bin/bash
# build-system.sh — bring a ZIGNOS root up to the base.list package set.
#
#   build-system.sh <root> [zpkg args...]
#
# <root> is a bootstrap tree ($LFS), an unpacked seed or an installed disk
# mount — anything with /usr/bin/bash and /etc/zignos-release. For the
# RUNNING system pass "/" and zpkg runs directly (no chroot nesting).
#
# This is the rolling-release workhorse: run it after updating the recipe
# tree and any missing base package is built and installed. Already
# installed packages are skipped, so it is safe to run any time. Pass -p to
# preview. Recipe repos come from the root's own tree (/sources/zignos-recipes
# on bootstrap hosts) or from the tree shipped in /usr/share/zignos/recipes.

set -euo pipefail

ROOT="${1:?usage: build-system.sh <root> [zpkg args...]}"
shift || true

DIR=$(cd "$(dirname "$0")" && pwd)
LIST="$DIR/base.list"

die() { printf 'build-system: %s\n' "$*" >&2; exit 1; }

[ -r "$LIST" ] || die "base.list not found next to this script: $LIST"
# Package names: comments and blank lines dropped.
NAMES=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LIST" | tr '\n' ' ')
[ -n "$NAMES" ] || die "base.list has no packages"

# Recipe repos inside the root: bootstrap layout wins, then the shipped tree.
if [ -d "$ROOT/sources/zignos-recipes" ]; then
	REPOS="/sources/zignos-recipes/core:/sources/zignos-recipes/main:/sources/zignos-recipes/desktop"
else
	REPOS="" # zpkg defaults to /usr/share/zignos/recipes inside the root
fi

if [ "$ROOT" = "/" ]; then
	# Live system: no chroot juggling.
	if [ -n "$REPOS" ]; then
		exec env ZPKG_REPOS="$REPOS" zpkg install "$@" $NAMES
	fi
	exec zpkg install "$@" $NAMES
fi

[ "$(id -u)" = 0 ] || die "run as root (it chroots into $ROOT)"
[ -x "$ROOT/usr/bin/bash" ] || die "$ROOT has no /usr/bin/bash"
[ -f "$ROOT/etc/zignos-release" ] || die "$ROOT is not a ZIGNOS tree (no /etc/zignos-release)"
ENTER="$DIR/zignos-enter.sh"
[ -x "$ENTER" ] || die "zignos-enter.sh not found next to this script"

if [ -n "$REPOS" ]; then
	exec "$ENTER" "$ROOT" /usr/bin/env ZPKG_REPOS="$REPOS" /usr/bin/zpkg install "$@" $NAMES
fi
exec "$ENTER" "$ROOT" /usr/bin/zpkg install "$@" $NAMES
