#!/bin/sh
# Probe real interpreters; /usr/bin/python3 can be an installer-launching shim.
set -eu

set -- /opt/homebrew/bin/python3 /usr/local/bin/python3 \
  /Library/Developer/CommandLineTools/usr/bin/python3
QUOTA_DEVELOPER_DIR=$(/usr/bin/xcode-select -p 2>/dev/null || true)
if [ -n "$QUOTA_DEVELOPER_DIR" ]; then
  set -- "$@" "$QUOTA_DEVELOPER_DIR/usr/bin/python3" \
    "$QUOTA_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/python3"
fi
for candidate in "$@"; do
  if [ "$candidate" != /usr/bin/python3 ] && [ -x "$candidate" ] && \
     "$candidate" -c 'import sys, ssl, zoneinfo; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done
exit 1
