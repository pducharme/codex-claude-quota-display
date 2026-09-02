#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$HOME/Library/Application Support/Quota Display"
PYTHON=$(command -v python3)
PLIST="$HOME/Library/LaunchAgents/com.pducharme.quota-display.plist"
MENU_PLIST="$HOME/Library/LaunchAgents/com.pducharme.quota-display-menu.plist"
LABEL="com.pducharme.quota-display"
MENU_LABEL="com.pducharme.quota-display-menu"
DOMAIN="gui/$(id -u)"
MENU_APP="$APP_DIR/Quota Display Menu.app"

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" \
  "$MENU_APP/Contents/MacOS" "$MENU_APP/Contents/Resources"
install -m 700 "$SCRIPT_DIR/quota_bridge.py" "$APP_DIR/quota_bridge.py"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -swift-version 5 -O \
  -framework AppKit -framework Foundation -framework LocalAuthentication \
  -framework Security -lsqlite3 \
  "$SCRIPT_DIR/quota_menu.swift" -o "$MENU_APP/Contents/MacOS/QuotaDisplayMenu"
install -m 600 "$SCRIPT_DIR/QuotaDisplayMenu-Info.plist" \
  "$MENU_APP/Contents/Info.plist"
install -m 644 "$SCRIPT_DIR/Assets/CodexIcon.png" \
  "$MENU_APP/Contents/Resources/CodexIcon.png"
install -m 644 "$SCRIPT_DIR/../THIRD_PARTY_NOTICES.md" \
  "$MENU_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$MENU_APP" >/dev/null
"$MENU_APP/Contents/MacOS/QuotaDisplayMenu" --self-test
sed \
  -e "s|__APP_DIR__|$APP_DIR|g" \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__PYTHON__|$PYTHON|g" \
  -e "s|__BRIDGE_SCRIPT__|$APP_DIR/quota_bridge.py|g" \
  "$SCRIPT_DIR/com.pducharme.quota-display.plist.template" > "$PLIST"
chmod 600 "$PLIST"
sed \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__MENU_EXECUTABLE__|$MENU_APP/Contents/MacOS/QuotaDisplayMenu|g" \
  "$SCRIPT_DIR/com.pducharme.quota-display-menu.plist.template" > "$MENU_PLIST"
chmod 600 "$MENU_PLIST"

"$PYTHON" "$APP_DIR/quota_bridge.py" \
  --token-file "$APP_DIR/token" --show-token >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"
launchctl bootout "$DOMAIN/$MENU_LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "$DOMAIN" "$MENU_PLIST"
launchctl kickstart -k "$DOMAIN/$MENU_LABEL"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:8788/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

TOKEN=$("$PYTHON" "$APP_DIR/quota_bridge.py" \
  --token-file "$APP_DIR/token" --show-token)
LAN_IP=$("$PYTHON" -c 'import socket
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("1.1.1.1",80))
    print(s.getsockname()[0]);s.close()
except OSError:
    print("127.0.0.1")')

echo "Pont installé."
echo "Menu macOS installé."
echo "Serveur: ${LAN_IP}:8788"
echo "Jeton: $TOKEN"
curl -fsS "http://127.0.0.1:8788/health"
echo
