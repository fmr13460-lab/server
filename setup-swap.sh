#!/usr/bin/env bash
set -euo pipefail

SWAP_SIZE="${1:-4G}"
SWAP_FILE="/swapfile"

echo "Creating ${SWAP_SIZE} swap file at ${SWAP_FILE}..."

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root or with sudo:"
  echo "  sudo $0 ${SWAP_SIZE}"
  exit 1
fi

if swapon --show=NAME --noheadings | grep -qx "$SWAP_FILE"; then
  echo "Swap file is already enabled: $SWAP_FILE"
  free -h
  exit 0
fi

if [[ -e "$SWAP_FILE" ]]; then
  echo "Error: $SWAP_FILE already exists but is not active."
  echo "Remove it manually if you want this script to recreate it:"
  echo "  sudo rm $SWAP_FILE"
  exit 1
fi

if ! command -v fallocate >/dev/null 2>&1; then
  echo "fallocate is required but was not found."
  exit 1
fi

fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
chmod 600 "$SWAP_FILE"
mkswap "$SWAP_FILE" >/dev/null
swapon "$SWAP_FILE"

if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]' /etc/fstab; then
  echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

# A lower swappiness reduces how aggressively Linux moves memory to swap.
cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness=10
EOF

sysctl --system >/dev/null

echo
echo "Swap setup complete."
echo
swapon --show
echo
free -h
