#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
VERSION=${1:-1.0.3}
if ! printf '%s\n' "$VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Version invalide: $VERSION" >&2
  exit 2
fi

WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quota-display-pkg.XXXXXX")
APP="$WORK_DIR/root/Applications/Quota Display.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
OUTPUT_DIR="$REPO_DIR/dist"
PACKAGE_NAME="Quota-Display-$VERSION.pkg"

/bin/mkdir -p "$MACOS" "$RESOURCES" "$OUTPUT_DIR"
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -target "$arch-apple-macosx13.0" \
    -parse-as-library -swift-version 5 -O \
    -framework AppKit -framework Foundation -framework LocalAuthentication \
    -framework Security -lsqlite3 \
    "$SCRIPT_DIR/quota_menu.swift" -o "$WORK_DIR/QuotaDisplayMenu-$arch"
done
/usr/bin/lipo -create \
  "$WORK_DIR/QuotaDisplayMenu-arm64" \
  "$WORK_DIR/QuotaDisplayMenu-x86_64" \
  -output "$MACOS/QuotaDisplayMenu"
/usr/bin/install -m 644 "$SCRIPT_DIR/QuotaDisplayMenu-Info.plist" "$APP/Contents/Info.plist"
/usr/bin/install -m 644 "$SCRIPT_DIR/Assets/CodexIcon.png" "$RESOURCES/CodexIcon.png"
/usr/bin/install -m 644 "$REPO_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/bin/install -m 755 "$SCRIPT_DIR/quota_bridge.py" "$RESOURCES/quota_bridge.py"
/usr/bin/install -m 600 \
  "$SCRIPT_DIR/com.pducharme.quota-display.plist.template" \
  "$RESOURCES/com.pducharme.quota-display.plist.template"
/usr/bin/install -m 600 \
  "$SCRIPT_DIR/com.pducharme.quota-display-menu.plist.template" \
  "$RESOURCES/com.pducharme.quota-display-menu.plist.template"

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP"
"$MACOS/QuotaDisplayMenu" --self-test
COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
  --root "$WORK_DIR/root" \
  --scripts "$SCRIPT_DIR/package" \
  --identifier com.pducharme.quota-display \
  --version "$VERSION" \
  --ownership recommended \
  --install-location / \
  "$WORK_DIR/$PACKAGE_NAME"
/usr/bin/install -m 644 "$WORK_DIR/$PACKAGE_NAME" "$OUTPUT_DIR/$PACKAGE_NAME"
(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$PACKAGE_NAME" > "$PACKAGE_NAME.sha256"
)

echo "$OUTPUT_DIR/$PACKAGE_NAME"
