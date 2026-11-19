#!/bin/bash
# Publish one release manifest to the repositories that consume it.
#
#   publish-release.sh <release.json>
#
# The generated manifest is the single source for the website, download
# page, release notes and install guide. This script validates it and copies
# the exact same bytes to:
#   <zignos>/releases/<release>.json        (archive)
#   <ZIGNOS-Official>/src/data/release.json (site build input)
#
# ZIGNOS_REPO_DIR / ZIGNOS_SITE_DIR override the locations.

set -euo pipefail

MANIFEST="${1:?usage: publish-release.sh <release.json>}"
DIR=$(cd "$(dirname "$0")" && pwd)

[ -f "$MANIFEST" ] || { echo "publish-release: not found: $MANIFEST" >&2; exit 1; }
python3 "$DIR/release-manifest.py" validate "$MANIFEST"

RELEASE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$MANIFEST")
[ -n "$RELEASE" ] || { echo "publish-release: empty release name" >&2; exit 1; }

find_dir() {
	local c
	for c in "$@"; do
		if [ -d "$c" ]; then
			(cd "$c" && pwd)
			return 0
		fi
	done
	return 1
}

REPO="${ZIGNOS_REPO_DIR:-$(find_dir "$DIR/../zignos" "$DIR/../../zignos" || true)}"
SITE="${ZIGNOS_SITE_DIR:-$(find_dir "$DIR/../ZIGNOS-Official" "$DIR/../../ZIGNOS-Official" || true)}"

if [ -n "$REPO" ]; then
	mkdir -p "$REPO/releases"
	cp "$MANIFEST" "$REPO/releases/$RELEASE.json"
	echo "published $REPO/releases/$RELEASE.json"
else
	echo "publish-release: zignos repo not found (set ZIGNOS_REPO_DIR)" >&2
fi

if [ -n "$SITE" ]; then
	mkdir -p "$SITE/src/data"
	cp "$MANIFEST" "$SITE/src/data/release.json"
	echo "published $SITE/src/data/release.json"
else
	echo "publish-release: site repo not found (set ZIGNOS_SITE_DIR)" >&2
fi
