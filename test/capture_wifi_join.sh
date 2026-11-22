#!/usr/bin/env bash
# One-shot WiFi-join capture. Earlier versions tried to pin the capture to
# a single channel (1, 6, or 11) based on a discovery pass -- but the
# board's own scan has now landed on a DIFFERENT channel on consecutive,
# back-to-back runs (11 then 1, seconds apart). A capture_sanity_check.sh
# run confirmed why: the AP BSSID (b0:19:21:e1:69:e1) is forwarding data
# for multiple distinct client MACs and there's a SECOND AP-like MAC
# (b0:19:21:e1:69:e2, one byte different) visible in ordinary traffic --
# a mesh/multi-node network broadcasting the same SSID on different
# channels, not random flakiness. Only channels 1 and 11 have ever been
# observed in this whole investigation (never 6), so this hops only
# those two, with a 2s dwell -- fast enough to likely be on the right
# channel at some point during a ~30-45s join attempt, slow enough not to
# repeat the earlier finding that a 300ms hop destabilized this adapter's
# monitor-mode driver entirely (that capture contained zero valid 802.11
# frames; a static capture at the same channel captured hundreds).
#
# Run as the normal user (NOT via sudo) -- it calls sudo itself for the
# wifi_sniff.sh start/stop steps and the per-hop channel-set calls, which
# will prompt interactively (sudo's own timestamp cache should cover the
# whole run after the first prompt).
#
# Usage: ./test/capture_wifi_join.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

IFACE="${WIFI_SNIFF_IFACE:-wlx5cf370243a37}"
HOP_PID=""

cleanup_hopper() {
    if [ -n "$HOP_PID" ] && kill -0 "$HOP_PID" 2>/dev/null; then
        kill "$HOP_PID" 2>/dev/null || true
        wait "$HOP_PID" 2>/dev/null || true
    fi
}
trap cleanup_hopper EXIT

run_join() {
    local timeout="$1"
    python3 - "$timeout" <<'PYEOF'
import sys, os, time
sys.path.insert(0, "test")
from wifikey_upload import open_serial

timeout = float(sys.argv[1])
fd = open_serial("/dev/ttyUSB0", 115200)
time.sleep(0.3)

os.write(fd, b"wifi join\r")
data = b""
end = time.time() + timeout
while time.time() < end:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        chunk = b""
    if chunk:
        data += chunk
        sys.stdout.write(chunk.decode(errors="replace"))
        sys.stdout.flush()
    if (b"association never completed" in data
            or b"gave up in state=" in data
            or b"wifi join: joined" in data):
        break
    time.sleep(0.1)
PYEOF
}

echo "=== starting monitor-mode capture (initial channel 1, will hop) ==="
sudo ./test/wifi_sniff.sh start 1
sleep 1

echo "=== starting channel hopper (1/11 only, 2s dwell) in the background ==="
(
    while true; do
        sudo /usr/sbin/iw dev "$IFACE" set channel 1 >/dev/null 2>&1
        sleep 2
        sudo /usr/sbin/iw dev "$IFACE" set channel 11 >/dev/null 2>&1
        sleep 2
    done
) &
HOP_PID=$!
echo "hopper pid=$HOP_PID"

echo "=== stopping dhruva-uart-logger (dual-reader-safe serial access) ==="
systemctl --user stop dhruva-uart-logger
sleep 0.5

echo "=== sending 'wifi join' to the board (capture is hopping channels throughout) ==="
run_join 45
echo
echo "=== wifi join attempt finished (or timed out) ==="

echo "=== restarting dhruva-uart-logger ==="
systemctl --user start dhruva-uart-logger

# Settle time so any trailing retry is definitely inside the window.
sleep 2

echo "=== stopping channel hopper ==="
cleanup_hopper
HOP_PID=""

echo "=== stopping capture, restoring this machine's own WiFi ==="
sudo ./test/wifi_sniff.sh stop

echo "=== done. Capture saved at /home/virgo/dhruva_wifi_capture.pcap ==="
ls -la /home/virgo/dhruva_wifi_capture.pcap
