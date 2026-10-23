#!/usr/bin/env python3
"""Host-side driver for `kernelupload stream`/`commit`: hex-encodes
nothing -- streams a kernel build (build/kernel.img) as raw binary
into the currently-INACTIVE A/B kernel slot over a live serial
connection to an already-booted board -- see shell_dispatch_
kernelupload's own header comment (kernel/kernel_main.vani) and the
plan this came from.

Mirrors test/wifikey_upload.py's structure for the connection/reader-
thread plumbing (same no-pyserial raw os.open+termios approach), but
NOT its per-chunk hex/ack shape -- see TASK #355's own history for
why: the original `chunk <hex>`-per-line design was found to project
to ~58 REAL HOURS for a 3MB kernel at 115200 baud, root-caused to two
independent bottlenecks that have nothing to do with wire bandwidth:
(1) task_f's own idle-sleep (1 full second whenever no line is ready,
paid on every single chunk's round trip, since the next chunk is
never ready the instant task_f checks) and (2) the UART RX IRQ
sporadic-server budget (a hard ~256 bytes/sec system-wide ceiling,
deliberately scoped for WCET safety on ordinary interactive/typed
traffic). `kernelupload stream <len>` fixes both: the board switches
into a dedicated raw-binary drain mode (irq_dispatch bypasses the RX
budget entirely while it's active, task_f busy-polls a lock-free ring
instead of idle-sleeping) and the host just blasts the whole file in
one write() -- no hex, no per-chunk round trip, no artificial pacing.
Progress is reported via periodic `ACK <total_len> <sha_prefix>`
lines (every 64KB) rather than a response-per-chunk; `DONE <total_len>`
signals the raw phase is over and the EXISTING, unchanged `commit
<len> <sha256>` command (full SD readback-and-rehash verification)
is next.

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
import subprocess
import sys
import termios
import threading
import time

BAUD_MAP = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}

# How often (in received bytes) the board sends an ACK line -- must
# match kernel_main.vani's own 65536 boundary (scheduling_decision_
# prelude has nothing to do with this; it's task_f's new streaming
# branch). Only used here to size the stall-detection timeout
# sensibly, not to validate the board's own cadence.
ACK_INTERVAL_BYTES = 65536


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


# A known, friendly way to stop the one process this project's own tooling
# is expected to leave holding the port day-to-day -- see test/uart_logger.py
# and dhruva-uart-logger.service. Anything else found holding the device is
# reported by PID/cmdline with a generic fallback instead, since this script
# has no way to know it's safe to kill.
KNOWN_HOLDER_HINTS = (
    ("uart_logger.py", "systemctl --user stop dhruva-uart-logger.service"),
)


def check_device_exclusive(device: str) -> bool:
    """Real-HW find (2026-10-23): a second process reading the same serial
    device at once (this project's persistent UART logger, a stale upload
    attempt from a prior run, etc.) races this script for bytes off one tty
    and corrupts the GO/ACK handshake -- see docs/TODO.md's task #352 entry
    for the first time this bit a real upload. Rather than silently risking
    that again, refuse to even open the device if anything else already has
    it open, and tell the user exactly what to stop.

    Returns True if the device looks exclusively available (or the check
    itself couldn't run -- missing fuser/lsof should never block a upload
    that would otherwise have worked), False if another process holds it
    and the caller should abort.
    """
    try:
        out = subprocess.run(["fuser", device], capture_output=True, text=True, timeout=5)
    except (FileNotFoundError, subprocess.SubprocessError):
        return True
    pids = [tok.rstrip("cmfk") for tok in out.stdout.split()]
    pids = [p for p in pids if p.isdigit()]
    if not pids:
        return True
    print(f"[FAIL] refusing to open {device} -- {len(pids)} other process(es) already have it open:")
    for pid in pids:
        cmdline = ""
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read().replace(b"\x00", b" ").decode(errors="replace").strip()
        except OSError:
            cmdline = "(cmdline unavailable -- process may have just exited)"
        print(f"  pid {pid}: {cmdline}")
        matched_hint = False
        for needle, stop_cmd in KNOWN_HOLDER_HINTS:
            if needle in cmdline:
                print(f"    -> stop it with: {stop_cmd}")
                matched_hint = True
        if not matched_hint:
            print(f"    -> stop it with: kill {pid}  (or: fuser -k {device})")
    print("Re-run this upload once the device is free -- two readers on one tty corrupts the stream.")
    return False


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

    def tail_text(self, n: int = 500) -> str:
        with self.lock:
            return bytes(self.buf[-n:]).decode(errors="replace")

    def send(self, line: str):
        os.write(self.fd, (line + "\r").encode())

    def send_raw(self, data: bytes):
        """Write raw bytes with no line framing at all -- used only
        for the stream payload itself, never for shell commands.
        A single os.write() to a tty is explicitly allowed by POSIX
        to do a short write (the line discipline's output buffer is
        bounded) -- a bare os.write() call silently dropped the tail
        of the image on real hardware once the buffer filled, so the
        remainder of the payload simply never reached the board. Must
        loop until every byte is actually accepted."""
        mv = memoryview(data)
        total = 0
        while total < len(mv):
            t_call = time.time()
            n = os.write(self.fd, mv[total:])
            dt = time.time() - t_call
            if dt > 0.5 or os.environ.get("KUPLOAD_DEBUG_WRITES"):
                print(f"    [write debug] os.write call took {dt:.3f}s, returned n={n}, total_so_far={total+max(n,0)}", flush=True)
            if n <= 0:
                raise IOError(f"os.write returned {n} while streaming kernel image "
                               f"({total}/{len(mv)} bytes sent so far)")
            total += n

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
    ap.add_argument("--go-timeout", type=float, default=10, help="seconds to wait for the board's 'GO <len>' response")
    ap.add_argument("--stall-timeout", type=float, default=30,
                     help="abort if no new ACK/DONE arrives for this many seconds once streaming (a stall, not normal per-chunk pacing -- there is no per-chunk pacing anymore)")
    ap.add_argument("--commit-timeout", type=float, default=60, help="commit does a full SD readback+re-hash, give it real time")
    ap.add_argument("--ready-timeout", type=float, default=30, help="seconds to wait for the board to answer 'ready' at all")
    ap.add_argument("--log", default="/tmp/kernel_upload_full.log", help="path to write the raw captured serial log")
    args = ap.parse_args()

    data = open(args.kernel_img, "rb").read()
    real_len = len(data)
    real_sha256 = hashlib.sha256(data).hexdigest()
    print(f"kernel image: {real_len} bytes, sha256={real_sha256}")

    if not check_device_exclusive(args.device):
        return 1

    fd = open_serial(args.device, args.baud)
    session = ShellSession(fd, args.log)

    try:
        print("checking the board is up and answering ('ready')...")
        if not session.wait_until_ready(overall_timeout=args.ready_timeout):
            print("[FAIL] board never answered 'ready' -- is it powered on and already booted?")
            return 1
        print("[board ready]")

        print(f"sending 'kernelupload stream {real_len}'...")
        session.send(f"kernelupload stream {real_len}")
        if not session.read_until("GO ", timeout=args.go_timeout):
            print("[FAIL] board never responded with 'GO <len>' -- is the slot-state record valid "
                  "(card seeded?), or is the requested length too large for the slot?")
            print("---last output---")
            print(session.tail_text())
            return 1
        print("[board is GO] blasting the whole image as one raw write -- no hex, no per-chunk wait...")

        t0 = time.time()
        session.send_raw(data)
        print(f"  ...all {real_len} bytes handed to the OS write() call, waiting for the board to "
              f"drain + ack as it goes")

        last_progress_bytes = 0
        deadline = time.time() + args.stall_timeout
        done = False
        while time.time() < deadline:
            if session.read_until("DONE ", timeout=0.5):
                done = True
                break
            with session.lock:
                buf_copy = bytes(session.buf)
            # Count how many "ACK " lines have appeared so far, purely
            # to decide whether real progress is happening (and reset
            # the stall deadline) -- not parsing the exact byte count
            # out of them, since DONE's own arrival is the real signal
            # this loop is waiting for.
            ack_count = buf_copy.count(b"ACK ")
            if ack_count > last_progress_bytes:
                last_progress_bytes = ack_count
                print(f"  ...progress: {ack_count} ACK(s) seen so far ({(time.time() - t0):.1f}s elapsed)")
                deadline = time.time() + args.stall_timeout
        if not done:
            print(f"[FAIL] stream stalled -- no DONE within {args.stall_timeout}s of the last progress ACK")
            print("---last output---")
            print(session.tail_text())
            return 1

        elapsed = time.time() - t0
        rate = real_len / elapsed if elapsed > 0 else 0
        print(f"[ok] got DONE after {elapsed:.1f}s ({rate:.0f} bytes/sec)")

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
