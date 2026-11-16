#!/usr/bin/env bash
# Live over-the-air capture of real WiFi traffic, using THIS machine's
# own USB WiFi dongle (RTL8188EUS, driven by the real Linux rtl8xxxu
# driver -- the exact reference driver this project has been comparing
# the DhruvaOS RTL8188CU driver against all night) switched into
# monitor mode. Exists specifically to get a definitive, real answer to
# "does the DhruvaOS board's Authentication Request actually leave the
# antenna, and does the AP ever reply at all" -- a question pure static
# code comparison against Linux/OpenBSD references could not resolve
# after 2026-11-16's long real-HW WiFi-join investigation (see project
# memory: project_dhruva_rtl8188cu_wifi_bringup_2026_11_09.md).
#
# Needs root (monitor mode + raw capture both require CAP_NET_ADMIN/
# CAP_NET_RAW) -- run via sudo directly, or install wifi-sniff.service
# below and control it with `sudo systemctl start/stop wifi-sniff`.
#
# What this does to the dongle: monitor mode is EXCLUSIVE on this
# driver (no concurrent managed+monitor virtual interfaces) -- starting
# a capture disconnects this machine's own current WiFi connection
# (trex_on_the_prowl2) for the duration. `stop` restores it: hands the
# interface back to NetworkManager and lets it reconnect on its own.
#
# Usage:
#   sudo ./test/wifi_sniff.sh start [channel]   # default channel: 1
#   sudo ./test/wifi_sniff.sh stop
#   ./test/wifi_sniff.sh status                 # no root needed
#
# Capture file: ~/dhruva_wifi_capture.pcap (overwritten on each start --
# copy it elsewhere first if a previous run's capture is still needed).
set -euo pipefail

IFACE="${WIFI_SNIFF_IFACE:-wlx5cf370243a37}"
PCAP_PATH="${WIFI_SNIFF_PCAP:-/home/virgo/dhruva_wifi_capture.pcap}"
PID_PATH="/run/dhruva-wifi-sniff.pid"
IW=/usr/sbin/iw
TCPDUMP=/usr/bin/tcpdump

cmd_status() {
    if [ -f "$PID_PATH" ] && kill -0 "$(cat "$PID_PATH")" 2>/dev/null; then
        echo "running (pid $(cat "$PID_PATH")), capturing to $PCAP_PATH"
        ls -la "$PCAP_PATH" 2>/dev/null || true
    else
        echo "not running"
    fi
}

cmd_start() {
    local channel="${1:-1}"
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: start needs root (monitor mode + raw capture both require it)." >&2
        exit 1
    fi
    if [ -f "$PID_PATH" ] && kill -0 "$(cat "$PID_PATH")" 2>/dev/null; then
        echo "ERROR: already running (pid $(cat "$PID_PATH")) -- stop it first." >&2
        exit 1
    fi

    echo "=== releasing $IFACE from NetworkManager ==="
    nmcli device set "$IFACE" managed no || true
    sleep 1

    echo "=== switching $IFACE to monitor mode, channel $channel ==="
    ip link set "$IFACE" down
    "$IW" dev "$IFACE" set type monitor
    ip link set "$IFACE" up
    "$IW" dev "$IFACE" set channel "$channel"
    "$IW" dev "$IFACE" info

    echo "=== starting tcpdump -> $PCAP_PATH ==="
    "$TCPDUMP" -i "$IFACE" -y IEEE802_11_RADIO -e -s0 -w "$PCAP_PATH" \
        > /tmp/dhruva-wifi-sniff.log 2>&1 &
    echo $! > "$PID_PATH"
    disown
    sleep 1
    if ! kill -0 "$(cat "$PID_PATH")" 2>/dev/null; then
        echo "ERROR: tcpdump exited immediately -- see /tmp/dhruva-wifi-sniff.log" >&2
        cat /tmp/dhruva-wifi-sniff.log >&2 || true
        exit 1
    fi
    echo "capturing (pid $(cat "$PID_PATH")). Trigger 'wifi join' on the board now, then run: sudo $0 stop"
}

cmd_stop() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: stop needs root (to restore managed mode)." >&2
        exit 1
    fi
    if [ -f "$PID_PATH" ]; then
        local pid
        pid="$(cat "$PID_PATH")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "=== stopping tcpdump (pid $pid) ==="
            kill "$pid"
            sleep 1
        fi
        rm -f "$PID_PATH"
    else
        echo "(no pid file -- tcpdump may not have been running)"
    fi

    echo "=== restoring $IFACE to managed mode ==="
    ip link set "$IFACE" down || true
    "$IW" dev "$IFACE" set type managed || true
    nmcli device set "$IFACE" managed yes || true
    sleep 1
    nmcli device connect "$IFACE" || true
    echo "=== done. Capture saved at $PCAP_PATH ==="
    ls -la "$PCAP_PATH" 2>/dev/null || true
}

case "${1:-}" in
    start) shift; cmd_start "${1:-1}" ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 {start [channel]|stop|status}" >&2
        exit 1
        ;;
esac
