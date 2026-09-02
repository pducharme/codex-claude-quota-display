#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
VERSION=${1:-1.0.6}
ZIP_NAME="Quota-Display-$VERSION.zip"
SPARKLE_ROOT=$("$SCRIPT_DIR/prepare_sparkle.sh")
WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quota-display-appcast.XXXXXX")
trap '/bin/rm -rf -- "$WORK_DIR"' EXIT HUP INT TERM

/usr/bin/install -m 644 "$REPO_DIR/dist/$ZIP_NAME" "$WORK_DIR/$ZIP_NAME"
if [ -f "$REPO_DIR/appcast.xml" ]; then
  /usr/bin/install -m 644 "$REPO_DIR/appcast.xml" "$WORK_DIR/appcast.xml"
fi

"$SPARKLE_ROOT/bin/generate_appcast" \
  --account quota-display \
  --download-url-prefix "https://github.com/pducharme/codex-claude-quota-display/releases/download/v$VERSION/" \
  --link "https://github.com/pducharme/codex-claude-quota-display/releases/latest" \
  --versions "$VERSION" \
  --maximum-deltas 0 \
  -o "$WORK_DIR/appcast.xml" \
  "$WORK_DIR"
/usr/bin/install -m 644 "$WORK_DIR/appcast.xml" "$REPO_DIR/appcast.xml"

printf '%s\n' "$REPO_DIR/appcast.xml"
