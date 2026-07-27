#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$HOME/Library/Application Support/Quota Display"
PLIST="$HOME/Library/LaunchAgents/com.pducharme.quota-display.plist"
LABEL="com.pducharme.quota-display"
DOMAIN="gui/$(id -u)"

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 700 "$SCRIPT_DIR/quota_bridge.py" "$APP_DIR/quota_bridge.py"
sed \
  -e "s|__APP_DIR__|$APP_DIR|g" \
  -e "s|__HOME__|$HOME|g" \
  "$SCRIPT_DIR/com.pducharme.quota-display.plist.template" > "$PLIST"
chmod 600 "$PLIST"

/usr/bin/python3 "$APP_DIR/quota_bridge.py" \
  --token-file "$APP_DIR/token" --show-token >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:8788/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

TOKEN=$(/usr/bin/python3 "$APP_DIR/quota_bridge.py" \
  --token-file "$APP_DIR/token" --show-token)
LAN_IP=$(/usr/bin/python3 -c 'import socket
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("1.1.1.1",80))
    print(s.getsockname()[0]);s.close()
except OSError:
    print("127.0.0.1")')

echo "Pont installé."
echo "Serveur: ${LAN_IP}:8788"
echo "Jeton: $TOKEN"
curl -fsS "http://127.0.0.1:8788/health"
echo
