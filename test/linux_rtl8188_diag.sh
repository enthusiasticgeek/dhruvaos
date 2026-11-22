#!/usr/bin/env bash
# Run this on the FRESH Raspberry Pi OS (Legacy) Lite SD card, over SSH,
# after first boot. Goal: pin the WiFi connection to the SPECIFIC BSSID
# (C8:A7:0A:C6:DD:78 -- the main router DhruvaOS has been failing
# against all session, NOT the extender _EXT AP a real Linux client
# already proved works) and capture a full diagnostic trace of the
# association attempt, so this is a genuine apples-to-apples test
# against the exact AP in question -- not just "some AP with the right
# SSID", which could silently roam to the already-proven-working
# extender and tell us nothing new. See docs/LINUX_RTL8188CU_COMPARISON_
# TEST.md for the full flashing instructions this script is meant to
# follow.
#
# Usage: sudo ./linux_rtl8188_diag.sh <ssid> <password> [bssid]
#   bssid defaults to C8:A7:0A:C6:DD:78 (the main router). Pass the
#   _EXT AP's BSSID (B0:19:21:E1:69:E1) instead if you want to test
#   that one for comparison.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run with sudo." >&2
  exit 1
fi

SSID="${1:?usage: $0 <ssid> <password> [bssid]}"
PASS="${2:?usage: $0 <ssid> <password> [bssid]}"
BSSID="${3:-C8:A7:0A:C6:DD:78}"
LOG="/home/virgo/rtl8188_diag_$(date +%s).log"
IFACE="wlan0"

exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -u) ==="
echo "=== Target: SSID='$SSID' BSSID=$BSSID iface=$IFACE ==="

echo
echo "=== lsusb (confirm the dongle is seen at all) ==="
lsusb -v 2>/dev/null | grep -A5 "0bda:8176" || lsusb | grep -i 0bda

echo
echo "=== dmesg: driver bind / firmware load (last 80 matching lines) ==="
dmesg | grep -iE "rtl|8188|8192|usb.*wifi|wlan0" | tail -80

echo
echo "=== Which driver actually bound ==="
readlink -f /sys/class/net/$IFACE/device/driver 2>/dev/null || echo "(wlan0 not present yet)"

echo
echo "=== iw phy / link capabilities ==="
iw dev 2>/dev/null
iw phy 2>/dev/null | head -40

NM_AVAILABLE=0
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
  NM_AVAILABLE=1
fi
echo
echo "=== Network stack: $([ "$NM_AVAILABLE" -eq 1 ] && echo NetworkManager || echo wpa_supplicant/dhcpcd) ==="

echo
echo "=== Scanning for the target BSSID first (confirm it's visible) ==="
ip link set "$IFACE" up 2>/dev/null
iw dev "$IFACE" scan 2>/dev/null | grep -B2 -A10 -i "$BSSID" || echo "BSSID $BSSID not seen in this scan pass (may need a retry -- scan results can be sparse on a single pass)"

if [ "$NM_AVAILABLE" -eq 1 ]; then
  echo
  echo "=== Using NetworkManager: creating a BSSID-pinned connection profile ==="
  nmcli connection delete "rtl8188-diag" 2>/dev/null || true
  nmcli connection add type wifi con-name "rtl8188-diag" ifname "$IFACE" ssid "$SSID"
  nmcli connection modify "rtl8188-diag" 802-11-wireless.bssid "$BSSID"
  nmcli connection modify "rtl8188-diag" wifi-sec.key-mgmt wpa-psk
  nmcli connection modify "rtl8188-diag" wifi-sec.psk "$PASS"
  nmcli connection modify "rtl8188-diag" connection.autoconnect yes

  echo "=== Bringing it up (this is the actual Auth/Assoc attempt) ==="
  nmcli -t -f GENERAL.STATE,IP4.ADDRESS device show "$IFACE" 2>/dev/null
  timeout 30 nmcli connection up "rtl8188-diag"
  CONNECT_STATUS=$?
  echo "=== nmcli connection up exit status: $CONNECT_STATUS (0 = success) ==="

  echo
  echo "=== Post-attempt state ==="
  nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS device show "$IFACE" 2>/dev/null
  nmcli connection show "rtl8188-diag" 2>/dev/null | grep -iE "state|bssid"
  journalctl -u NetworkManager --no-pager -n 100 2>/dev/null
else
  echo
  echo "=== Using wpa_supplicant: writing a BSSID-pinned config ==="
  WPA_CONF="/tmp/rtl8188_diag_wpa.conf"
  cat > "$WPA_CONF" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid="$SSID"
    bssid=$BSSID
    psk="$PASS"
    key_mgmt=WPA-PSK
}
EOF
  pkill wpa_supplicant 2>/dev/null || true
  sleep 1
  echo "=== Running wpa_supplicant in the foreground with debug output for 20s ==="
  timeout 20 wpa_supplicant -i "$IFACE" -c "$WPA_CONF" -d 2>&1 | tail -200
fi

echo
echo "=== Final link state ==="
iw dev "$IFACE" link 2>/dev/null
ip addr show "$IFACE" 2>/dev/null

echo
echo "=== Full diagnostic saved to: $LOG ==="
echo "    Copy it back with: scp virgo@<this-pi-ip>:$LOG ."
