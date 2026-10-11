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
# dmesg-style rotation (added 2026-10-11, user's own suggestion): this
# logger was manually stopped mid-session (to free the serial device
# for a one-off wifikey upload) and not restarted for several turns --
# the NEXT real-HW boot's own banner was silently lost, confusing a
# later analysis pass into treating a stale boot's tail as live output.
# Rotation alone doesn't fix "someone stopped the process," but
# bounding the file size means the process, once left running
# continuously (the actual fix -- see test/uart_logger_service.sh),
# never needs to be stopped to manage its own size either. Same
# archive-numbered-files shape as traditional Unix logrotate/dmesg:
# current file stays at LOGFILE, rolled files become LOGFILE.1 (newest)
# through LOGFILE.{KEEP} (oldest, deleted once exceeded).
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wifikey_upload import open_serial  # noqa: E402

DEVICE = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
LOGFILE = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/dhruva_uart.log")
ROTATE_BYTES = 50 * 1024 * 1024  # 50MB -- a real session's own full-day
                                   # capture (observed ~2MB per several-
                                   # minute boot) stays well under this
                                   # for a normal day of iteration.
ROTATE_KEEP = 5

print(f"uart_logger: {DEVICE} @ {BAUD} -> {LOGFILE} (rotates past {ROTATE_BYTES} bytes, keeps {ROTATE_KEEP}, Ctrl-C to stop)", flush=True)


def rotate_if_needed():
    try:
        size = os.path.getsize(LOGFILE)
    except OSError:
        return
    if size < ROTATE_BYTES:
        return
    oldest = f"{LOGFILE}.{ROTATE_KEEP}"
    if os.path.exists(oldest):
        os.remove(oldest)
    for i in range(ROTATE_KEEP - 1, 0, -1):
        src = f"{LOGFILE}.{i}"
        if os.path.exists(src):
            os.rename(src, f"{LOGFILE}.{i + 1}")
    os.rename(LOGFILE, f"{LOGFILE}.1")


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

    rotate_if_needed()
    # Plain variable, not a `with` block: this handle gets closed and
    # reopened mid-loop on rotation, and a `with` statement's own
    # cleanup only ever closes the ORIGINAL object it was entered with
    # -- reassigning the local name inside the block doesn't change
    # what `with` closes on exit, silently leaking the reopened handle
    # across every subsequent rotation. Closed explicitly in every
    # exit path below instead.
    logf = open(LOGFILE, "ab", buffering=0)
    consecutive_errors = 0
    last_rotate_check = time.time()
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
        # Rotation inside a single long-lived connection too, not
        # just across reconnects -- a board left running for a long
        # unattended session never needs this file growing
        # unbounded. Checked on a real wall-clock interval (not
        # every loop iteration) since os.path.getsize() is a syscall
        # and this loop's own idle poll already runs every ~50ms.
        now = time.time()
        if now - last_rotate_check > 30:
            last_rotate_check = now
            if logf.tell() >= ROTATE_BYTES:
                logf.close()
                rotate_if_needed()
                logf = open(LOGFILE, "ab", buffering=0)
        # Device node disappearing is the other failure mode (e.g.
        # adapter fully re-enumerates as a fresh ttyUSB node) --
        # check periodically, not just on read error.
        if not os.path.exists(DEVICE):
            break
    logf.close()
    try:
        os.close(fd)
    except OSError:
        pass
    time.sleep(0.5)
