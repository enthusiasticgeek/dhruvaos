#!/usr/bin/env python3
"""Sends one shell command to the already-booted real-HW board over
/dev/ttyUSB0 and prints whatever it replies -- the project's own
"active round-trip probe" convention (see this project's memory:
never trust a passive UART log-tail read alone, since it can return
stale cached content; a live command/response round trip is the only
reliable liveness check). Promoted from several one-off, differently-
named scratchpad scripts used ad hoc during real-HW sessions into one
stable, permanently-reviewable project script specifically so it can
be pre-approved by path (scratchpad scripts live under a session-
specific temp directory that changes every session, so no permission
rule could ever match them reliably).

Does NOT stop dhruva-uart-logger.service (or anything else) to get
exclusive access -- this project's own standing policy is to never
stop that logger. A plain, non-exclusive open alongside the logger
has worked fine for a short command/response round trip in practice;
if the logger's own reads ever visibly stole bytes meant for this
script, run it, see garbled or missing output, and decide from there
-- this script itself takes no action to avoid that.

Usage:
  python3 test/realhw_probe.py "ready" 3
  python3 test/realhw_probe.py "kernelslot status" 5
"""
import os
import sys
import termios
import time

DEV = "/dev/ttyUSB0"


def open_serial(path, baud_const):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
    cflag &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
    cflag |= termios.CS8 | termios.CLOCAL | termios.CREAD
    lflag = 0
    iflag = 0
    oflag = 0
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, baud_const, baud_const, cc])
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def send_verified(fd, data):
    for b in data:
        n = os.write(fd, bytes([b]))
        if n != 1:
            raise RuntimeError("short write")
        time.sleep(0.005)


def drain_quiet(fd, quiet_s, max_total_s):
    buf = b""
    last_data = time.time()
    start = time.time()
    while True:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            buf += chunk
            last_data = time.time()
        now = time.time()
        if now - last_data > quiet_s:
            break
        if now - start > max_total_s:
            break
    return buf


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "kernelslot status"
    wait_s = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
    fd = open_serial(DEV, termios.B115200)
    send_verified(fd, (cmd + "\r").encode())
    out = drain_quiet(fd, wait_s, wait_s + 5)
    os.close(fd)
    sys.stdout.write(out.decode("utf-8", "replace"))
