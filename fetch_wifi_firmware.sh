#!/usr/bin/env bash
# Fetches the real RTL8188CU/RTL8192CU WiFi firmware blob if it isn't
# already cached locally -- see docs/HARDWARE_IN_LOOP.md §6.1 for the
# full story (proprietary Realtek binary, same "fetch fresh, never
# commit to this repo" posture as every other third-party firmware
# this project touches).
#
# Usage:
#   ./fetch_wifi_firmware.sh [cache-dir]
#
# Prints the resolved firmware file path on stdout's last line on
# success (so callers like flash_sd_card.sh/update_kernel.sh can
# capture it) -- everything else goes to stderr.
set -euo pipefail

CACHE_DIR="${1:-$HOME/wifi-firmware}"
FW_NAME="rtl8192cufw_TMSC.bin"
FW_PATH="$CACHE_DIR/$FW_NAME"
FW_URL="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/rtlwifi/rtl8192cufw_TMSC.bin"
EXPECT_SIZE=16126

mkdir -p "$CACHE_DIR"

if [ -f "$FW_PATH" ]; then
    ACTUAL_SIZE=$(stat -c%s "$FW_PATH")
    if [ "$ACTUAL_SIZE" -eq "$EXPECT_SIZE" ]; then
        echo "WiFi firmware already cached at $FW_PATH ($ACTUAL_SIZE bytes)." >&2
        echo "$FW_PATH"
        exit 0
    fi
    echo "WiFi firmware at $FW_PATH is $ACTUAL_SIZE bytes, expected $EXPECT_SIZE -- re-fetching." >&2
    rm -f "$FW_PATH"
fi

echo "WiFi firmware not found locally -- fetching from linux-firmware (proprietary Realtek blob, never committed to this repo):" >&2
echo "  $FW_URL" >&2
curl -sL -o "$FW_PATH" "$FW_URL"

ACTUAL_SIZE=$(stat -c%s "$FW_PATH")
if [ "$ACTUAL_SIZE" -ne "$EXPECT_SIZE" ]; then
    echo "ERROR: fetched file is $ACTUAL_SIZE bytes, expected exactly $EXPECT_SIZE -- the URL may" >&2
    echo "have changed or returned an error page. See docs/HARDWARE_IN_LOOP.md §6.1 for the" >&2
    echo "documented source and how to verify a different one by hand." >&2
    rm -f "$FW_PATH"
    exit 1
fi

# Round 58's own live-verified signature bytes (docs/HARDWARE_IN_LOOP.md
# §6.1): little-endian u16 at offset 0 is 0x88C1.
SIG=$(od -An -tx1 -N2 "$FW_PATH" | tr -d ' ')
if [ "$SIG" != "c188" ]; then
    echo "ERROR: fetched file's signature bytes are 0x$SIG, expected 0xc188 (little-endian" >&2
    echo "0x88C1) -- this doesn't match the file round 58 verified. Refusing to trust it." >&2
    rm -f "$FW_PATH"
    exit 1
fi

echo "Fetched and verified: $FW_PATH ($ACTUAL_SIZE bytes, signature 0x88C1)." >&2
echo "$FW_PATH"
