bash
#!/usr/bin/env bash

set -euo pipefail

NETPLAN_FILE="/etc/netplan/99-wifi.yaml"
WATCHDOG_SCRIPT="/usr/local/sbin/wifi-watchdog.sh"
SERVICE_FILE="/etc/systemd/system/wifi-watchdog.service"

echo "======================================"
echo " Ubuntu Server Wi-Fi Setup"
echo "======================================"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script with sudo:"
    echo "  sudo ./setup-wifi.sh"
    exit 1
fi

# --------------------------------------
# Detect Wi-Fi interface
# --------------------------------------

if ! command -v iw >/dev/null 2>&1; then
    echo "ERROR: 'iw' is not installed."
    echo "Install it with:"
    echo "  sudo apt install iw"
    exit 1
fi

WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')

if [[ -z "$WIFI_INTERFACE" ]]; then
    echo "ERROR: No Wi-Fi interface detected."
    echo "Check with: iw dev"
    exit 1
fi

echo
echo "Detected Wi-Fi interface: $WIFI_INTERFACE"
echo

# --------------------------------------
# Ask for Wi-Fi credentials ONCE
# --------------------------------------

read -rp "Wi-Fi name (SSID): " WIFI_SSID

if [[ -z "$WIFI_SSID" ]]; then
    echo "ERROR: Wi-Fi name cannot be empty."
    exit 1
fi

read -rsp "Wi-Fi password: " WIFI_PASSWORD
echo

if [[ -z "$WIFI_PASSWORD" ]]; then
    echo "ERROR: Wi-Fi password cannot be empty."
    exit 1
fi

# --------------------------------------
# Escape characters for YAML
# --------------------------------------

WIFI_SSID_ESCAPED="${WIFI_SSID//\\/\\\\}"
WIFI_SSID_ESCAPED="${WIFI_SSID_ESCAPED//\"/\\\"}"

WIFI_PASSWORD_ESCAPED="${WIFI_PASSWORD//\\/\\\\}"
WIFI_PASSWORD_ESCAPED="${WIFI_PASSWORD_ESCAPED//\"/\\\"}"

# --------------------------------------
# Save Wi-Fi configuration
# --------------------------------------

echo
echo "Saving Wi-Fi configuration..."

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd

  wifis:
    ${WIFI_INTERFACE}:
      dhcp4: true
      dhcp6: false

      access-points:
        "${WIFI_SSID_ESCAPED}":
          password: "${WIFI_PASSWORD_ESCAPED}"
EOF

# Protect the Wi-Fi password
chmod 600 "$NETPLAN_FILE"

# --------------------------------------
# Create watchdog
# --------------------------------------

echo "Installing Wi-Fi reconnect watchdog..."

cat > "$WATCHDOG_SCRIPT" <<EOF
#!/usr/bin/env bash

set -u

INTERFACE="$WIFI_INTERFACE"
CHECK_INTERVAL=30
MAX_FAILURES=2

failures=0

log() {
    echo "[wifi-watchdog] \$(date '+%Y-%m-%d %H:%M:%S') \$*"
}

while true; do

    # Check interface exists
    if ! ip link show "\$INTERFACE" >/dev/null 2>&1; then
        log "Wi-Fi interface \$INTERFACE not found."
        sleep "\$CHECK_INTERVAL"
        continue
    fi

    # Check physical Wi-Fi connection
    CARRIER=\$(cat "/sys/class/net/\$INTERFACE/carrier" 2>/dev/null || echo 0)

    # Check Internet connectivity
    if [[ "\$CARRIER" == "1" ]] &&
       ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then

        failures=0

    else

        failures=\$((failures + 1))

        log "Connection failed (\$failures/\$MAX_FAILURES)."

        if [[ "\$failures" -ge "\$MAX_FAILURES" ]]; then

            log "Attempting automatic Wi-Fi reconnect..."

            # Ask systemd-networkd to reconfigure Wi-Fi
            networkctl reconfigure "\$INTERFACE" || true

            sleep 10

            if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then

                log "Wi-Fi reconnected successfully."
                failures=0

            else

                log "Reconfigure failed. Restarting Wi-Fi interface..."

                ip link set "\$INTERFACE" down || true
                sleep 3
                ip link set "\$INTERFACE" up || true

                sleep 10

                if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
                    log "Connection restored after interface restart."
                    failures=0
                else
                    log "Connection is still unavailable."
                fi
            fi
        fi
    fi

    sleep "\$CHECK_INTERVAL"
done
EOF

chmod 700 "$WATCHDOG_SCRIPT"

# --------------------------------------
# Create systemd service
# --------------------------------------

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Automatic Wi-Fi Reconnect Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# --------------------------------------
# Configure Netplan
# --------------------------------------

echo
echo "Checking Netplan configuration..."

netplan generate

echo "Applying Wi-Fi configuration..."
netplan apply

# --------------------------------------
# Enable watchdog at boot
# --------------------------------------

systemctl daemon-reload
systemctl enable wifi-watchdog.service
systemctl restart wifi-watchdog.service

echo
echo "Waiting for Wi-Fi..."
sleep 10

# --------------------------------------
# Test connection
# --------------------------------------

if ping -c 3 -W 5 1.1.1.1 >/dev/null 2>&1; then

    echo
    echo "======================================"
    echo " Wi-Fi setup complete!"
    echo "======================================"
    echo
    echo "Wi-Fi interface : $WIFI_INTERFACE"
    echo "Wi-Fi SSID      : $WIFI_SSID"
    echo
    echo "Automatic boot connection : ENABLED"
    echo "Automatic reconnect       : ENABLED"
    echo
    echo "The Wi-Fi credentials were"
    echo "asked for only during setup."
    echo
    echo "The watchdog checks every 30 seconds."

else

    echo
    echo "WARNING:"
    echo "Wi-Fi configuration was saved, but"
    echo "Internet connectivity could not be verified."
    echo
    echo "Check:"
    echo "  systemctl status wifi-watchdog"
    echo "  journalctl -u wifi-watchdog -f"
fi
