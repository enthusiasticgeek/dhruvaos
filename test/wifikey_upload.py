#!/usr/bin/env python3
"""Host-side driver for `wifikey chunk`/`commit`: hex-encodes a firmware
file and streams it to a live Dhruva shell over a real serial port, one
`wifikey chunk <hex>\r` line at a time.

Task #164's own scoped follow-up (see docs/HARDWARE_IN_LOOP.md and the
kernel's own shell_dispatch_wifikey header comment) -- the real
~16KB RTL8188CU firmware needs ~337 chunk commands at the kernel's
48-byte-per-chunk cap, genuinely tedious to type by hand.

No pyserial dependency -- this project has no Python package-management
infra elsewhere (every other host-side tool here is a bare shell script
or a stdlib-only test/*.py), so this opens the tty device directly via
os.open + the stdlib termios module instead of requiring `pip install
pyserial` before the tool can be used at all.

Same event-driven read_until()-with-retry pattern already proven twice
in this project (test/shell_interactive_check.py, task #9; and this same
session's real-firmware wifikey testing, task #164) -- a fixed sleep
between commands was tried first for the ad-hoc wifikey test scripts and
found live to be unreliable (QEMU/real-UART timing varies run to run;
sending the next line before the shell has actually finished the
previous one silently drops bytes -- see the kernel's own
shell_dispatch header comment on the real bug that surfaced from
exactly this).

Validated against a REAL serial device, not just QEMU's special stdio
chardev shortcut every other test script here uses: `qemu-system-arm
-M raspi1ap -display none -serial pty -kernel ...` redirects the
guest's UART to a real host PTY (`char device redirected to
/dev/pts/N`), which this script can open with the exact same
os.open+termios path a genuine /dev/ttyUSB0 would take -- proves the
serial I/O itself works, not just the upload protocol logic.

Usage:
  python3 test/wifikey_upload.py /dev/ttyUSB0 firmware.bin
  python3 test/wifikey_upload.py /dev/pts/5 firmware.bin --baud 115200
"""
import argparse
import hashlib
import os
import sys
import termios
import threading
import time

# Must match shell_dispatch_wifikey's own enforced cap (kernel/
# kernel_main.vani) -- "wifikey chunk " (14 chars) + 2*CHUNK_BYTES hex
# chars must stay under shell_line_scratch's 128-byte line buffer. The
# kernel rejects anything larger with "chunk too large"; this script
# just never asks for more than the kernel will accept.
CHUNK_BYTES = 48

BAUD_MAP = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}


def open_serial(path: str, baud: int) -> int:
    if baud not in BAUD_MAP:
        raise ValueError(f"unsupported baud rate {baud} (supported: {sorted(BAUD_MAP)})")
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
    baud_const = BAUD_MAP[baud]
    # Clear parity/stop-bit/char-size bits first, THEN set CS8 -- doing
    # both in one `cflag &= ~(...) | CS8` expression (an earlier version
    # of this function) is wrong: Python's `&` binds tighter than `|`,
    # so that evaluates as `cflag & (~(...) | CS8)`, which only ever
    # PRESERVES whatever CS8 bits cflag already happened to have instead
    # of actually forcing them -- two separate statements avoids it.
    cflag &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
    cflag |= termios.CS8 | termios.CLOCAL | termios.CREAD
    lflag = 0  # raw mode: no canonical processing, no local echo
    iflag = 0
    oflag = 0
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1  # 0.1s granularity per read() call
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, baud_const, baud_const, cc])
    # Deliberately NOT flushing pending input here: the real usage
    # pattern is running this immediately after a power-on/reset, where
    # the target can already be mid-boot-output by the time this opens
    # the device -- an unconditional flush found live (via a PTY-backed
    # self-test, see test/wifikey_upload.py's own module docstring) to
    # silently discard exactly the boot output this script then waits
    # for (the "PASS" marker), causing it to time out for no visible
    # reason. read_until()'s own scan-for-marker approach already
    # doesn't care what (if anything) arrived before it connected.
    return fd


class ShellSession:
    """Same reader-thread + consumed-cursor read_until() shape as
    test/shell_interactive_check.py -- proven reliable across every
    round that's used it, including this session's own real-firmware
    wifikey testing."""

    def __init__(self, fd: int, log_path: str):
        self.fd = fd
        self.log_f = open(log_path, "wb", buffering=0)
        self.buf = bytearray()
        self.consumed = 0
        self.lock = threading.Lock()
        self._stop = False
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()

    def _reader(self):
        while not self._stop:
            try:
                chunk = os.read(self.fd, 4096)
            except OSError:
                return
            if not chunk:
                continue
            self.log_f.write(chunk)
            with self.lock:
                self.buf.extend(chunk)

    def read_until(self, expected: str, timeout: float = 30) -> bool:
        want = expected.encode()
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                idx = self.buf.find(want, self.consumed)
                if idx != -1:
                    self.consumed = idx + len(want)
                    return True
            time.sleep(0.05)
        return False

    def send(self, line: str):
        os.write(self.fd, (line + "\r").encode())

    def step(self, line: str, expected: str, timeout: float, attempts: int) -> bool:
        for _ in range(attempts):
            self.send(line)
            if self.read_until(expected, timeout=timeout):
                return True
        return False

    def close(self):
        self._stop = True
        self.thread.join(timeout=2)
        self.log_f.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", help="serial device, e.g. /dev/ttyUSB0 (real hardware) or /dev/pts/N (QEMU -serial pty)")
    ap.add_argument("firmware", help="path to the firmware file to upload (never committed to the repo -- see docs/HARDWARE_IN_LOOP.md)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--boot-timeout", type=float, default=90, help="seconds to wait for the boot self-test suite's PASS marker")
    ap.add_argument("--chunk-timeout", type=float, default=10, help="seconds to wait for each chunk's 'bytes accumulated' response")
    ap.add_argument("--chunk-attempts", type=int, default=3, help="retries per chunk before giving up")
    ap.add_argument("--commit-timeout", type=float, default=15)
    ap.add_argument("--log", default="/tmp/wifikey_upload_full.log", help="path to write the raw captured serial log")
    args = ap.parse_args()

    data = open(args.firmware, "rb").read()
    real_len = len(data)
    real_sha256 = hashlib.sha256(data).hexdigest()
    chunks = [data[i:i + CHUNK_BYTES] for i in range(0, len(data), CHUNK_BYTES)]
    print(f"firmware: {real_len} bytes, sha256={real_sha256}")
    print(f"{len(chunks)} chunks of up to {CHUNK_BYTES} bytes each")

    fd = open_serial(args.device, args.baud)
    session = ShellSession(fd, args.log)

    try:
        print("waiting for boot to reach the shell (PASS marker)...")
        if not session.read_until("PASS", timeout=args.boot_timeout):
            print("[FAIL] boot never reached PASS -- is the device powered on and freshly reset?")
            return 1
        print("[boot ready]")

        for idx, c in enumerate(chunks):
            ok = session.step(f"wifikey chunk {c.hex()}", "bytes accumulated",
                               timeout=args.chunk_timeout, attempts=args.chunk_attempts)
            if not ok:
                print(f"[FAIL] chunk {idx + 1}/{len(chunks)} never confirmed after {args.chunk_attempts} attempts")
                return 1
            if idx % 20 == 0 or idx == len(chunks) - 1:
                print(f"  ...chunk {idx + 1}/{len(chunks)} ok", flush=True)

        commit_needle = f"ok, {real_len} bytes written to /wifi/fw.bin"
        if not session.step("wifikey commit", commit_needle, timeout=args.commit_timeout, attempts=args.chunk_attempts):
            print(f"[FAIL] commit did not report the expected line: {commit_needle!r}")
            return 1

        print(f"[PASS] uploaded {real_len} bytes to /wifi/fw.bin (sha256={real_sha256})")
        return 0
    finally:
        session.close()
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
