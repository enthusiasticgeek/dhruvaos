#!/usr/bin/env python3
# Persistent UART logger for real-HW DhruvaOS testing -- replaces the
# need to keep a manual picocom session open. Runs forever, appending
# everything it reads to a fixed logfile, and transparently reopens the
# serial device if it goes away and comes back (handles a Pi power-
# cycle, which can make the USB-serial adapter itself briefly
# disconnect/re-enumerate depending on how it's powered -- a one-shot
# os.open() + read loop does NOT survive that, which is why earlier
# capture attempts this session got 0 bytes across power-cycles despite
# the exact same open_serial() helper working fine against an already-
# running board).
#
# Usage:
#   python3 test/uart_logger.py [/dev/ttyUSB0] [115200] [logfile]
#
# Leave this running in the background (nohup/tmux/run_in_background);
# tail -f the logfile, or just read its tail, any time -- no need to
# coordinate timing with a power-cycle.
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wifikey_upload import open_serial  # noqa: E402

DEVICE = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
LOGFILE = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/dhruva_uart.log")

print(f"uart_logger: {DEVICE} @ {BAUD} -> {LOGFILE} (Ctrl-C to stop)", flush=True)

while True:
    fd = None
    try:
        fd = open_serial(DEVICE, BAUD)
    except OSError as e:
        # Device node missing (adapter mid-reconnect) -- wait and retry
        # rather than crash; this is the exact gap a one-shot script
        # doesn't handle.
        time.sleep(0.5)
        continue

    with open(LOGFILE, "ab", buffering=0) as logf:
        consecutive_errors = 0
        while True:
            try:
                chunk = os.read(fd, 4096)
                consecutive_errors = 0
            except OSError:
                # Read failing repeatedly usually means the underlying
                # device vanished (power-cycle, adapter re-enumeration).
                # Close and fall through to reopen rather than spin
                # forever on a dead fd.
                consecutive_errors += 1
                if consecutive_errors > 10:
                    break
                time.sleep(0.2)
                continue
            if chunk:
                logf.write(chunk)
            else:
                time.sleep(0.05)
            # Device node disappearing is the other failure mode (e.g.
            # adapter fully re-enumerates as a fresh ttyUSB node) --
            # check periodically, not just on read error.
            if not os.path.exists(DEVICE):
                break
    try:
        os.close(fd)
    except OSError:
        pass
    time.sleep(0.5)
