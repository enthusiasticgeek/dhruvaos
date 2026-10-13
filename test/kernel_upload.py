#!/usr/bin/env python3
"""Host-side driver for `kernelupload chunk`/`commit`: hex-encodes a
kernel build (build/kernel.img) and streams it into the currently-
INACTIVE A/B kernel slot over a live serial connection to an
already-booted board -- see shell_dispatch_kernelupload's own header
comment (kernel/kernel_main.vani) and the plan this came from.

Mirrors test/wifikey_upload.py's structure exactly (same no-pyserial
raw os.open+termios approach, same reader-thread + read_until()-with-
retry pacing -- chunks sent faster than the shell can process them
silently drop bytes, the same real bug wifikey_upload.py's own header
comment documents). Differences: this script computes the sha256 once
over the whole local file (no streaming constraint host-side -- the
kernel itself streams because a multi-MB image doesn't fit in its own
768KB heap) and sends it in the final `commit <len> <sha256>` line;
expect thousands of chunks for a multi-MB image (vs. wifikey's ~337),
so this adds a progress printout.

This does NOT reboot the board or activate the new slot -- that's a
deliberate, separate decision (`kernelslot activate <a|b>`, run by
hand once you're ready to actually try the new build).

Usage:
  python3 test/kernel_upload.py /dev/ttyUSB0 build/kernel.img
  python3 test/kernel_upload.py /dev/pts/5 build/kernel.img --baud 115200
"""
import argparse
import hashlib
import os
import sys
import termios
import threading
import time

# Must match shell_dispatch_kernelupload's own enforced cap (kernel/
# kernel_main.vani) -- same 48-byte/96-hex-char shell-line-buffer
# ceiling wifikey's own chunk size is bounded by.
# TASK #352/#164 (2026-10-12): reduced from 48 after a real-HW finding
# the same night -- even with UART_RX_IRQ_BUDGET_PER_TICK raised 4->8
# (kernel_main.vani, commit e94e798), a 48-byte chunk's own ~115-byte
# line still exceeds the real per-tick RX margin (confirmed live: a
# 32-byte/~84-byte-line chunk got its own hex echoed fully but its
# "ok, N bytes accumulated" RESPONSE truncated to just "ok" -- right at
# the edge, not reliably safe). 24 bytes (~68-byte line) confirmed
# clean on real hardware, response included, with real margin to
# spare. Doubles the chunk count for a given upload vs. the original
# 48 -- a real cost, not a one-line tweak to shrug off -- but a
# further RX-budget increase (or line-length-aware pacing) that lets
# this go back up belongs in a FUTURE round validated live, not
# guessed here without a board to test against.
CHUNK_BYTES = 24

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
    cflag &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
    cflag |= termios.CS8 | termios.CLOCAL | termios.CREAD
    lflag = 0
    iflag = 0
    oflag = 0
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, baud_const, baud_const, cc])
    return fd


class ShellSession:
    """Same reader-thread + consumed-cursor read_until() shape as
    test/wifikey_upload.py -- proven reliable there."""

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

    def wait_until_ready(self, overall_timeout: float = 30, poll_interval: float = 1.0) -> bool:
        """Same attach-at-any-time handshake as wifikey_upload.py's own
        -- this tool targets an ALREADY-booted board, not a fresh
        reset, so there's no 'PASS' marker to wait for at all."""
        deadline = time.time() + overall_timeout
        while time.time() < deadline:
            self.send("ready")
            if self.read_until("READY", timeout=poll_interval):
                return True
        return False

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
    ap.add_argument("kernel_img", help="path to the flat kernel binary to upload (e.g. build/kernel.img)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--chunk-timeout", type=float, default=10, help="seconds to wait for each chunk's 'bytes accumulated' response")
    ap.add_argument("--chunk-attempts", type=int, default=3, help="retries per chunk before giving up")
    ap.add_argument("--commit-timeout", type=float, default=60, help="commit does a full SD readback+re-hash, give it real time")
    ap.add_argument("--ready-timeout", type=float, default=30, help="seconds to wait for the board to answer 'ready' at all")
    ap.add_argument("--log", default="/tmp/kernel_upload_full.log", help="path to write the raw captured serial log")
    args = ap.parse_args()

    data = open(args.kernel_img, "rb").read()
    real_len = len(data)
    real_sha256 = hashlib.sha256(data).hexdigest()
    chunks = [data[i:i + CHUNK_BYTES] for i in range(0, len(data), CHUNK_BYTES)]
    print(f"kernel image: {real_len} bytes, sha256={real_sha256}")
    print(f"{len(chunks)} chunks of up to {CHUNK_BYTES} bytes each")

    fd = open_serial(args.device, args.baud)
    session = ShellSession(fd, args.log)

    try:
        print("checking the board is up and answering ('ready')...")
        if not session.wait_until_ready(overall_timeout=args.ready_timeout):
            print("[FAIL] board never answered 'ready' -- is it powered on and already booted?")
            return 1
        print("[board ready]")

        for idx, c in enumerate(chunks):
            ok = session.step(f"kernelupload chunk {c.hex()}", "bytes accumulated",
                               timeout=args.chunk_timeout, attempts=args.chunk_attempts)
            if not ok:
                print(f"[FAIL] chunk {idx + 1}/{len(chunks)} never confirmed after {args.chunk_attempts} attempts")
                return 1
            if idx % 200 == 0 or idx == len(chunks) - 1:
                print(f"  ...chunk {idx + 1}/{len(chunks)} ok", flush=True)

        print("committing (board re-reads every written block from SD and re-verifies -- may take a while)...")
        commit_needle = "verified and marked ready"
        if not session.step(f"kernelupload commit {real_len} {real_sha256}", commit_needle,
                             timeout=args.commit_timeout, attempts=1):
            print(f"[FAIL] commit did not report success ({commit_needle!r}) -- check {args.log} for the real error")
            return 1

        print(f"[PASS] uploaded and verified {real_len} bytes (sha256={real_sha256})")
        print("Not activated yet -- run 'kernelslot activate a' or 'kernelslot activate b' by hand when ready to try it.")
        return 0
    finally:
        session.close()
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
