#!/usr/bin/env bash
# Isolated diagnostic: does this sniffing adapter capture ANY real 802.11
# frames at all (e.g. the target AP's own beacons) on a single, static
# channel with no hopping and no DhruvaOS join attempt involved? If this
# comes back empty/garbage too, the problem is the capture setup itself,
# not the channel-hopping added for the real join capture.
#
# Run as the normal user (not via sudo) -- prompts for sudo itself.
# Usage: ./test/capture_sanity_check.sh [channel]   (default: 11)
set -euo pipefail

CHANNEL="${1:-11}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

echo "=== starting static-channel capture (channel $CHANNEL), 10s, no hopping, no join ==="
sudo ./test/wifi_sniff.sh start "$CHANNEL"
sleep 10
sudo ./test/wifi_sniff.sh stop

echo "=== raw packet count and first bytes of each (sanity check) ==="
python3 - <<'PYEOF'
import struct
with open('/home/virgo/dhruva_wifi_capture.pcap','rb') as f:
    data = f.read()
off = 24
idx = 0
while off < len(data):
    ts_sec, ts_usec, incl_len, orig_len = struct.unpack_from('<IIII', data, off)
    pkt = data[off+16:off+16+incl_len]
    print(idx, "len=", incl_len, "first16=", pkt[:16].hex())
    off += 16 + incl_len
    idx += 1
print("total packets:", idx)
PYEOF
