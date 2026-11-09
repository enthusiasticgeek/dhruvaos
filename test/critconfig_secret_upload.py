#!/usr/bin/env python3
"""Writes a secret value (default key: wifi_password) into the
Critical Config Store via the live shell's `critconfig set <key>
<value> [--encrypted]` command, over a real serial port.

Deliberately never prints or logs the secret anywhere -- reads it
directly from the given file and sends it straight to the device,
matching this project's own standing policy already established by
test/wifi_creds_upload.py (never put a credential in a transcript,
log, or commit).

Two leak vectors beyond "don't print it yourself" had to be closed
for this to actually be safe, both found while building this script:

1. kernel_main.vani's shell dispatch used to carry a 2026-10-24 TEMP
   DIAGNOSTIC that unconditionally echoed the full raw command line
   -- including this script's own `critconfig set wifi_password
   <pw> --encrypted` argument -- back out over UART on every single
   dispatch. Removed 2026-11-08 (it was already marked "remove once
   root-caused/confirmed fixed" and never was). A board still running
   an OLDER image than that fix will still leak the value through
   this path regardless of anything this script does -- rebuild,
   re-upload, reboot before relying on this script against real HW.
2. Independent of (1): the shell's own interactive character echo
   (shell_get_echo_state/shell_echo_advance) echoes every typed byte
   back over UART as it's received -- by design, for a human typing
   at a terminal. That means the secret gets echoed back out over the
   wire the instant it's sent, regardless of (1). If
   dhruva-uart-logger.service is running, it will write that echo
   straight into ~/dhruva_uart.log in plaintext. This script stops
   that service for the duration of the write and restarts it
   immediately after (same stop/restart-same-turn discipline this
   project already follows for exclusive serial access), rather than
   just not-printing its own copy of the echo.

Config set this way is boot-time-only (read once at boot by
wifi_config_init/ble_config_init, not live-reloaded) -- reboot the
board after this to actually use it.

Usage:
  python3 test/critconfig_secret_upload.py <value_file> [device] [baud]
  python3 test/critconfig_secret_upload.py <value_file> --key ble_target_name --plain [device] [baud]
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kernel_upload import open_serial, check_device_exclusive  # noqa: E402

UART_LOGGER_UNIT = "dhruva-uart-logger.service"


def logger_is_active() -> bool:
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", UART_LOGGER_UNIT],
            capture_output=True, text=True, timeout=5,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return False
    return out.stdout.strip() == "active"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Set a critconfig key from a file's contents without ever printing it.")
    ap.add_argument("value_file", help="path to a file containing the secret value (contents never printed)")
    ap.add_argument("--key", default="wifi_password", help="critconfig key (default: wifi_password)")
    ap.add_argument("--plain", action="store_true", help="store unencrypted (default: encrypted)")
    ap.add_argument("device", nargs="?", default="/dev/ttyUSB0")
    ap.add_argument("baud", nargs="?", type=int, default=115200)
    args = ap.parse_args()

    with open(args.value_file, "r") as f:
        value = f.read().strip()
    if len(value) == 0 or len(value) > 200:
        print("error: value empty or >200 bytes (not printing it)", file=sys.stderr)
        return 1
    if " " in value:
        # critconfig's own line parser splits the rest-of-line value off
        # at the first space after the key (see shell_dispatch_critconfig's
        # "set" branch) -- a value containing one would be silently
        # truncated there rather than rejected.
        print("error: value must not contain a space character (critconfig's line parser splits on spaces)", file=sys.stderr)
        return 1
    if len(args.key) == 0 or len(args.key) > 24:
        print("error: key must be 1-24 characters", file=sys.stderr)
        return 1

    if not check_device_exclusive(args.device):
        return 1

    stopped_logger = False
    if logger_is_active():
        print(f"stopping {UART_LOGGER_UNIT} for the duration of this write (secret echo must not land in ~/dhruva_uart.log)...")
        subprocess.run(["systemctl", "--user", "stop", UART_LOGGER_UNIT], timeout=10)
        stopped_logger = True

    result = 1
    try:
        fd = open_serial(args.device, args.baud)
        try:
            suffix = "" if args.plain else " --encrypted"
            line = f"critconfig set {args.key} {value}{suffix}\r"
            os.write(fd, line.encode("ascii"))

            # Collect the response in memory only -- never written to a
            # file, never printed -- since the shell's own character
            # echo means this buffer necessarily contains the secret
            # we just sent.
            buf = bytearray()
            deadline = time.time() + 5.0
            while time.time() < deadline:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if chunk:
                    buf.extend(chunk)
                    if b"\nok" in buf or b"critconfig:" in buf:
                        break
                else:
                    time.sleep(0.05)

            # Only ever test membership / look at bytes after the last
            # newline (the shell's actual response line, after its own
            # echo of what we sent) -- the matched substrings below are
            # fixed kernel-side response text, never derived from buf
            # itself, so nothing printed here can ever contain the value.
            last_line = buf.rsplit(b"\n", 1)[-1]
            if b"ok" in last_line or b"\nok" in buf:
                print(f"critconfig_secret_upload: key '{args.key}' set (value not shown). "
                      f"Reboot the board for wifi_config_init/ble_config_init to pick it up.")
                result = 0
            elif b"permission denied" in buf:
                print("critconfig_secret_upload: FAILED -- permission denied (not root over this shell)", file=sys.stderr)
            elif b"table full" in buf:
                print("critconfig_secret_upload: FAILED -- critconfig table full (no free slot)", file=sys.stderr)
            elif b"write failed" in buf:
                print("critconfig_secret_upload: FAILED -- critconfig write failed", file=sys.stderr)
            else:
                print("critconfig_secret_upload: FAILED or no recognized response within timeout "
                      "(raw response withheld -- it may contain the value echoed back)", file=sys.stderr)
        finally:
            os.close(fd)
    finally:
        if stopped_logger:
            print(f"restarting {UART_LOGGER_UNIT}...")
            subprocess.run(["systemctl", "--user", "start", UART_LOGGER_UNIT], timeout=10)

    return result


if __name__ == "__main__":
    sys.exit(main())
