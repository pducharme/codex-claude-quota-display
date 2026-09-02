#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
VERSION=2.9.6
ARCHIVE="Sparkle-$VERSION.tar.xz"
EXPECTED_SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
CACHE_DIR="$REPO_DIR/.build/sparkle-$VERSION"

if [ ! -d "$CACHE_DIR/Sparkle.framework" ]; then
  WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quota-display-sparkle.XXXXXX")
  trap '/bin/rm -rf -- "$WORK_DIR"' EXIT HUP INT TERM
  /usr/bin/curl -fL \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/$ARCHIVE" \
    -o "$WORK_DIR/$ARCHIVE"
  ACTUAL_SHA256=$(/usr/bin/shasum -a 256 "$WORK_DIR/$ARCHIVE" | /usr/bin/awk '{print $1}')
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "Somme SHA-256 Sparkle invalide." >&2
    exit 1
  fi
  /bin/mkdir -p "$CACHE_DIR"
  /usr/bin/tar -xJf "$WORK_DIR/$ARCHIVE" -C "$CACHE_DIR"
fi

printf '%s\n' "$CACHE_DIR"
