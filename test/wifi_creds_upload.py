#!/usr/bin/env python3
"""Writes the user's real WiFi SSID/password into DharaFS's
/config/wifi_ssid and /config/wifi_password via the live shell's
`write <path> <text>` command, over a real serial port.

Deliberately never prints the SSID or password anywhere -- reads them
directly from the given files and sends them straight to the device,
matching this project's own standing policy (task #310's own
verification notes: "did not read or reference the user's own real
~/home-wifi-ssid.txt/~/home-wifi-pwd.txt contents at any point") of
keeping these values out of any transcript, log, or commit.

Usage:
  python3 test/wifi_creds_upload.py <ssid_file> <pwd_file> [/dev/ttyUSB0] [115200]

Config is boot-time-only (read once at boot, not live-reloaded) --
reboot the board after this to actually join.
"""
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wifikey_upload import open_serial  # noqa: E402


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: wifi_creds_upload.py <ssid_file> <pwd_file> [device] [baud]", file=sys.stderr)
        return 1
    ssid_file = sys.argv[1]
    pwd_file = sys.argv[2]
    device = sys.argv[3] if len(sys.argv) > 3 else "/dev/ttyUSB0"
    baud = int(sys.argv[4]) if len(sys.argv) > 4 else 115200

    with open(ssid_file, "r") as f:
        ssid = f.read().strip()
    with open(pwd_file, "r") as f:
        pwd = f.read().strip()

    if len(ssid) == 0 or len(ssid) > 32:
        print("error: SSID empty or >32 bytes (not printing it)", file=sys.stderr)
        return 1
    if len(pwd) == 0 or len(pwd) > 63:
        print("error: password empty or >63 bytes (not printing it)", file=sys.stderr)
        return 1

    fd = open_serial(device, baud)
    try:
        for cmd, value in ((b"write /config/wifi_ssid ", ssid), (b"write /config/wifi_password ", pwd)):
            line = cmd + value.encode("ascii") + b"\r\n"
            os.write(fd, line)
            time.sleep(0.5)
            # Drain whatever the shell echoes back without printing it
            # (the write command's own argument -- i.e. the credential
            # itself -- would otherwise appear in any captured output).
            try:
                os.read(fd, 4096)
            except OSError:
                pass
    finally:
        os.close(fd)

    print("wifi_creds_upload: both files written (contents not shown). Reboot the board to join.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
