#!/usr/bin/env bash
# setup-swap.sh - create and enable a swap file on Debian/Ubuntu
# Usage: ./setup-swap.sh [SIZE]      e.g. ./setup-swap.sh 4G   or   ./setup-swap.sh 512M
# Default size: 4G. Run as root.

set -u
set -o pipefail

SWAPFILE="/swapfile"
SIZE_ARG="${1:-4G}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

# 1. Must be root
[ "$(id -u)" -eq 0 ] || die "Run as root (try: su -  or  sudo $0 $SIZE_ARG)"

# 2. Fix PATH (swapon/mkswap live in /usr/sbin, missing after plain 'su')
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

# 3. Validate size argument (digits followed by M or G)
if ! [[ "$SIZE_ARG" =~ ^([0-9]+)([MmGg])$ ]]; then
    die "Invalid size '$SIZE_ARG'. Use a number plus M or G, e.g. 512M or 4G."
fi
NUM="${BASH_REMATCH[1]}"
UNIT="${BASH_REMATCH[2]^^}"
[ "$NUM" -gt 0 ] || die "Size must be greater than zero."
if [ "$UNIT" = "G" ]; then SIZE_MB=$((NUM * 1024)); else SIZE_MB=$NUM; fi

# 4. Make sure required tools exist; try to install util-linux if not
for cmd in mkswap swapon swapoff dd chmod df grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [ "$cmd" = "mkswap" ] || [ "$cmd" = "swapon" ] || [ "$cmd" = "swapoff" ]; then
            warn "'$cmd' not found. Trying to install util-linux..."
            if command -v apt-get >/dev/null 2>&1 && apt-get install -y util-linux; then
                hash -r
            else
                die "'$cmd' is missing and could not be installed. Check your internet connection, then run: apt install util-linux"
            fi
        else
            die "Required command '$cmd' not found."
        fi
    fi
done
for cmd in mkswap swapon swapoff; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' still not available after install attempt."
done

# 5. Already active? Nothing to do.
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    info "$SWAPFILE is already active:"
    swapon --show
    exit 0
fi

# 6. Existing inactive swap file: try to activate it, otherwise remove it
if [ -e "$SWAPFILE" ]; then
    warn "$SWAPFILE exists but is not active."
    if [ -f "$SWAPFILE" ]; then
        chmod 600 "$SWAPFILE"
        if swapon "$SWAPFILE" 2>/dev/null; then
            info "Existing $SWAPFILE was valid and is now active."
            EXISTING_OK=1
        else
            warn "Existing file is not a valid swap file. Removing it and recreating."
            rm -f "$SWAPFILE" || die "Could not remove $SWAPFILE."
            EXISTING_OK=0
        fi
    else
        die "$SWAPFILE exists but is not a regular file. Remove it manually first."
    fi
else
    EXISTING_OK=0
fi

# 7. Create the swap file if needed
create_swapfile() {
    local method="$1"
    rm -f "$SWAPFILE"
    info "Creating ${SIZE_MB}MB swap file using $method..."
    if [ "$method" = "fallocate" ]; then
        command -v fallocate >/dev/null 2>&1 || return 1
        fallocate -l "${SIZE_MB}M" "$SWAPFILE" || return 1
    else
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=progress || return 1
    fi
    chmod 600 "$SWAPFILE" || return 1
    mkswap "$SWAPFILE" >/dev/null || return 1
    swapon "$SWAPFILE" || return 1
    return 0
}

if [ "$EXISTING_OK" -ne 1 ]; then
    # Disk space check (need size + 100MB spare)
    ROOT_DIR="$(dirname "$SWAPFILE")"
    AVAIL_MB="$(df -Pm "$ROOT_DIR" | awk 'NR==2 {print $4}')"
    [[ "$AVAIL_MB" =~ ^[0-9]+$ ]] || die "Could not read free disk space."
    NEED_MB=$((SIZE_MB + 100))
    if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
        die "Not enough disk space: need ${NEED_MB}MB, only ${AVAIL_MB}MB free on $ROOT_DIR."
    fi

    # Try fast method first; fall back to dd (needed on some filesystems)
    if ! create_swapfile fallocate; then
        warn "fallocate method failed. Retrying with dd (slower)..."
        if ! create_swapfile dd; then
            rm -f "$SWAPFILE"
            die "Could not create or enable swap file. Check disk space, permissions, and that the filesystem supports swap files."
        fi
    fi
fi

# 8. Make it permanent across reboots (with backup)
if grep -qE "^[[:space:]]*$SWAPFILE[[:space:]]" /etc/fstab 2>/dev/null; then
    info "/etc/fstab already has an entry for $SWAPFILE."
else
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)" || warn "Could not back up /etc/fstab."
    if echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab; then
        info "Added $SWAPFILE to /etc/fstab."
    else
        warn "Could not write to /etc/fstab. Swap is active now but will not survive a reboot."
    fi
fi

# 9. Verify
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    info "Done. Swap is active:"
    swapon --show
    free -h
else
    die "Swap file was created but does not show as active. Check: swapon --show"
fi
