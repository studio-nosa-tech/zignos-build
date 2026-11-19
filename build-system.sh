#!/bin/bash
# build-system.sh — bring a ZIGNOS root up to the base.list package set.
#
#   build-system.sh <root> [zpkg args...]
#
# <root> is a bootstrap tree ($ZIGNOS_ROOT), an unpacked seed or an installed disk
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

CHANNEL="${CHANNEL:-stable}"
case "$CHANNEL" in
	stable|testing|unstable) ;;
	*) die "invalid CHANNEL=$CHANNEL (use stable, testing or unstable)" ;;
esac

# Recipe repos inside the root: bootstrap layout wins, then the shipped tree.
# A legacy flat tree is accepted only for stable.
if [ -d "$ROOT/sources/zignos-recipes/$CHANNEL/core" ]; then
	REPOS="/sources/zignos-recipes/$CHANNEL/core:/sources/zignos-recipes/$CHANNEL/main:/sources/zignos-recipes/$CHANNEL/desktop"
elif [ -d "$ROOT/usr/share/zignos/recipes/$CHANNEL/core" ]; then
	REPOS="/usr/share/zignos/recipes/$CHANNEL/core:/usr/share/zignos/recipes/$CHANNEL/main:/usr/share/zignos/recipes/$CHANNEL/desktop"
elif [ -d "$ROOT/sources/zignos-recipes/core" ] || [ -d "$ROOT/usr/share/zignos/recipes/core" ]; then
	[ "$CHANNEL" = stable ] || die "channel $CHANNEL is not installed under $ROOT (run zpkg sync)"
	REPOS="" # legacy flat tree: let zpkg discover it
else
	REPOS=""
fi

ENVARGS=(ZPKG_CHANNEL="$CHANNEL")
if [ -n "$REPOS" ]; then
	ENVARGS+=(ZPKG_REPOS="$REPOS")
fi

if [ "$ROOT" = "/" ]; then
	# Live system: no chroot juggling. $NAMES is intentionally unquoted:
	# base.list expands to one argument per package.
	# shellcheck disable=SC2086
	exec env "${ENVARGS[@]}" zpkg install "$@" $NAMES
fi

[ "$(id -u)" = 0 ] || die "run as root (it chroots into $ROOT)"
[ -x "$ROOT/usr/bin/bash" ] || die "$ROOT has no /usr/bin/bash"
[ -f "$ROOT/etc/zignos-release" ] || die "$ROOT is not a ZIGNOS tree (no /etc/zignos-release)"
ENTER="$DIR/zignos-enter.sh"
[ -x "$ENTER" ] || die "zignos-enter.sh not found next to this script"

# $NAMES is intentionally unquoted: one argument per base.list package.
# shellcheck disable=SC2086
exec "$ENTER" "$ROOT" /usr/bin/env "${ENVARGS[@]}" /usr/bin/zpkg install "$@" $NAMES
