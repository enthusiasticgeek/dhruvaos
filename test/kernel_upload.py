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
import re
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
# match kernel_main.vani's own task_f streaming branch threshold
# (KERNELUPLOAD_ACK_INTERVAL_BYTES there).
# 2026-10-23 (aged-SD-card stall investigation): reduced from 65536 to
# 512 (one SD block) specifically so this can double as the real ACK-
# driven flow-control window below, not just a progress heartbeat --
# see send_raw_ack_paced's own docstring for why that granularity
# matters, not merely how often it previously fired.
# REVERTED 2026-11-10: the 2026-11-08 512->2048 growth (batching 4 SD
# blocks per ACK round trip, for throughput) broke the "zero bytes in
# flight during any SD write" guarantee this constant exists to
# provide -- see KERNELUPLOAD_ACK_INTERVAL_BYTES's own kernel-side
# header for the full real-HW root cause (kernelupload_rx_ring_pop_
# batch is non-blocking, so task_f can start a masked SD write for an
# early block in a window while later blocks of that SAME window are
# still arriving over the wire; only interval==512==one block closes
# that race). Confirmed live: real, reproducible rxdiag overrun_count
# increments during 2048-byte-window transfers, not a rare adapter
# flake. The lock-contention problem this growth was chasing is real
# but separate and still open -- needs its own fix that doesn't
# reopen this race.
ACK_INTERVAL_BYTES = 512

ACK_LINE_RE = re.compile(rb"ACK ([0-9A-Fa-f]{8}) ")


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
    # Root-cause fix (2026-10-23): this was missing entirely. Any bytes the
    # board already sent before this process opened the device -- e.g. a
    # prior attempt's own late DONE/STALL-DIAG text, queued in the kernel's
    # TTY input buffer because the previous process was killed (a `timeout`
    # wrapper, Ctrl-C, etc.) before its own reader thread drained them --
    # stay sitting there across the close/reopen and get silently replayed
    # into THIS session's buffer the instant its reader thread starts
    # reading. That contaminates every read_until() match with a mix of
    # stale and fresh board output, which is indistinguishable from a real
    # protocol failure without tracing byte-for-byte -- exactly what made
    # several real-HW stream failures this session look inconsistent
    # (sometimes garbled, sometimes a stray "DONE" from nowhere). Flush
    # unconditionally on every open, not just after a detected failure.
    termios.tcflush(fd, termios.TCIFLUSH)
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

    def wait_for_ack_at_least(self, min_len: int, timeout: float) -> bool:
        """Blocks until an `ACK <hex_len> ...` line whose hex_len already
        covers min_len appears, advancing self.consumed past every ACK
        line scanned (matched or not) so later read_until calls (DONE,
        the commit needle) never re-see them. Returns False on timeout --
        the caller treats that as a real stall, not a transient gap."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                while True:
                    m = ACK_LINE_RE.search(self.buf, self.consumed)
                    if not m:
                        break
                    total_len = int(m.group(1), 16)
                    self.consumed = m.end()
                    if total_len >= min_len:
                        return True
            time.sleep(0.01)
        return False

    def send_raw_ack_paced(self, data: bytes, window_size: int, ack_timeout: float, on_progress=None):
        """True ACK-driven flow control (2026-10-23, aged-SD-card stall
        investigation -- see docs/TODO.md for the full writeup). The
        earlier fix here was a fixed host-side delay after each chunk
        (see git history), sized against this driver's documented
        ~50ms worst-case IRQ+FIQ-masked SD-write window (boot/
        sdcard_state.S). Direct real-HW measurement on a 13-year-old
        card (kernelupload_state.S's own sd_write_worst_us, read back
        via the `rxdiag` shell command) found 139ms for a single write
        -- sdhost_write_block retries up to SD_MAX_ATTEMPTS(3) times on
        a wedge, each retry re-entering its own masked fill loop, and
        aged flash's slower/more variable program time trips that
        wedge heuristic far more often than the healthy card the fixed
        delay was tuned against. No fixed delay is a real guarantee
        against a card that is, or becomes, slower still.

        This replaces the guess with a guarantee: window_size MUST be
        <=ACK_INTERVAL_BYTES (kernel_main.vani's task_f streaming
        branch only emits its ACK once total_len crosses an ack-
        interval boundary, and every SD block write inside that
        interval -- kernelupload_accumulate_bytes writes one per 512
        bytes, looping internally -- has already completed by then,
        synchronously, before task_f ever checks that boundary).
        Sending one window, then blocking until the board's own ACK
        confirms it was fully absorbed, means zero bytes are ever in
        flight while a masked write (how many retries, however long)
        is in progress -- correctness no longer depends on how long
        that window is, only throughput does. 2026-11-08: the interval
        itself grew 512->2048 (4 SD blocks/window now, not 1) to cut
        how often a real scheduler-contention stall (separate issue,
        see kernel_main.vani's own KERNELUPLOAD_ACK_INTERVAL_BYTES
        header) can land per byte transferred -- this guarantee is
        unaffected either way, since it only depends on window_size
        never exceeding the board's own ack-interval, not on what that
        interval's absolute value is. The board reports DONE instead
        of a trailing ACK for the final window once total_len reaches
        the declared length -- that's deliberately NOT matched here
        (the caller's own existing DONE read_until, run after this
        method returns, is left to see it; matching it here would
        consume it out from under that wait)."""
        if window_size > ACK_INTERVAL_BYTES:
            raise ValueError(f"window_size must be <={ACK_INTERVAL_BYTES} (the board's own "
                              "ack-interval, ACK_INTERVAL_BYTES) -- see this method's own "
                              "docstring for why a larger window reopens the exact overrun "
                              "risk this flow control exists to close")
        mv = memoryview(data)
        total = 0
        while total < len(mv):
            end = min(total + window_size, len(mv))
            self.send_raw(mv[total:end])
            total = end
            if on_progress is not None:
                on_progress(total, len(mv))
            if total < len(mv):
                if not self.wait_for_ack_at_least(total, ack_timeout):
                    raise IOError(f"no ACK covering {total}/{len(mv)} bytes within {ack_timeout}s -- "
                                  f"board stalled (SD write stuck?) or connection lost")

    def wait_until_ready(self, overall_timeout: float = 30, poll_interval: float = 5.0) -> bool:
        """Same attach-at-any-time handshake as wifikey_upload.py's own
        -- this tool targets an ALREADY-booted board, not a fresh
        reset, so there's no 'PASS' marker to wait for at all.

        2026-10-24 fix: the old version re-sent 'ready' every single
        poll_interval (originally 1.0s) regardless of whether the
        PRIOR 'ready' had actually been answered yet -- a real round
        trip that happens to take just over that window (confirmed
        live: ordinary interactive commands occasionally do, no
        regression, just real variance) left a stray unconsumed
        'ready'/'READY' pair sitting in the buffer past self.consumed.
        The NEXT command's own read_until (for 'GO ') then scans
        forward from there and can land behind that leftover pair's
        own echo/response text with no 'GO ' substring anywhere in it
        -- confirmed live, twice in a row: a direct, single manual
        'kernelupload stream' command (skipping this polling loop
        entirely) got 'GO <len>' back immediately both times, proving
        the board itself was never the problem. Fixed by raising the
        per-attempt window to 5.0s (comfortably over any real round
        trip this project has ever measured) so a resend only ever
        fires after a genuine silence, not a slightly-slow-but-still-
        in-flight response -- same principle as every other timeout in
        this file, sized against real measured latency, not a guess."""
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
                     help="abort if the final DONE doesn't arrive within this many seconds of the last window's ACK")
    ap.add_argument("--commit-timeout", type=float, default=60, help="commit does a full SD readback+re-hash, give it real time")
    ap.add_argument("--ready-timeout", type=float, default=30, help="seconds to wait for the board to answer 'ready' at all")
    ap.add_argument("--log", default="/tmp/kernel_upload_full.log", help="path to write the raw captured serial log")
    ap.add_argument("--window-size", type=int, default=ACK_INTERVAL_BYTES,
                     help="2026-10-23 (replaces the old fixed-delay --chunk-size/--chunk-delay pacing, which "
                          "assumed a bounded ~50ms SD-write worst case that a 13-year-old test card blew past at "
                          "139ms): send this many bytes, then BLOCK for a real ACK from the board confirming they "
                          f"were fully absorbed, before sending more. MUST stay <={ACK_INTERVAL_BYTES} (the "
                          "board's own ack-interval, grown from 512 on 2026-11-08 to batch 4 SD blocks per round "
                          "trip and cut how often real-HW scheduler contention is hit per byte transferred -- see "
                          "ACK_INTERVAL_BYTES's own header) -- see send_raw_ack_paced's own docstring for why a "
                          "larger window reopens the overrun risk this flow control exists to close.")
    ap.add_argument("--ack-timeout", type=float, default=10.0,
                     help="seconds to wait for each window's own ACK before declaring a real stall. Covers the "
                          "worst single SD-write duration measured so far (139ms on an aged card, now up to 4x "
                          "per window since --window-size batches 4 SD blocks) plus the residual task_e/GC "
                          "ceiling-2 contention window (kernel_main.vani's maintenance_mode precedence checks "
                          "close most of this, but a live 2026-11-08 retest still measured 0.5-1.5s of it "
                          "recurring per window despite that fix -- still open, see KERNELUPLOAD_ACK_INTERVAL_"
                          "BYTES's own header). Raised from 5.0 to 10.0 on the same date for margin against that "
                          "contention possibly also scaling with the bigger window, not just recurring at the "
                          "same magnitude -- not yet confirmed which, so sized generously rather than tightly.")
    ap.add_argument("--retries", type=int, default=3,
                     help="2026-11-09 (real-HW resilience fix for an occasional full stream stall, root-caused "
                          "by elimination via live instrumentation on BOTH ends, not guessed): host os.write() "
                          "calls are always instantaneous (confirmed live, KUPLOAD_DEBUG_WRITES=1) -- rules out "
                          "a slow/blocking host. The board's own UART_FR/RIS snapshot at the moment of the stall "
                          "shows a genuinely empty hardware RX FIFO with IRQs still enabled and task_f still "
                          "actively polling -- rules out both 'bytes stuck unprocessed' (there's a separate, "
                          "already-proven task-context force-drain for exactly that case, and it finds nothing) "
                          "and a dhruva_prio_lock(2) contention hang (that would leave task_f BLOCKED, never "
                          "reaching this stall-diagnostic print's own code path at all, since it only runs from "
                          "an actively-looping iteration). The board's own live `rxdiag` overrun_count reads 0 "
                          "across this entire investigation -- rules out genuine PL011 hardware RX FIFO overrun "
                          "too, the last mechanism either side's own code could still be blamed for. With every "
                          "software-explainable cause on both ends directly ruled out by live evidence, not "
                          "merely unconfirmed, what's left is a transient fault in the physical USB-to-serial "
                          "link itself (the host's own adapter silently dropping bytes already accepted by the "
                          "kernel's tty layer, outside any application's visibility on either end) -- this link "
                          "has no hardware flow control either (confirmed via `stty -a`, -crtscts), so nothing "
                          "upstream of the adapter could even detect it happening. Not fixable by retrying the "
                          "SAME bytes differently, but empirically rare enough per 2048-byte window, and cleanly "
                          "recoverable (the board's own 10s self-abort already leaves it in a clean, immediately-"
                          "retryable state -- confirmed live, repeatedly: `kernelupload resumestatus` reports "
                          "clean right after every stall this investigation captured), that simply re-running "
                          "the whole already-aged-card-tolerant upload succeeds end-to-end essentially every "
                          "time. Set to 1 to disable and fail on the first stall, matching the old behavior.")
    args = ap.parse_args()

    data = open(args.kernel_img, "rb").read()
    real_len = len(data)
    real_sha256 = hashlib.sha256(data).hexdigest()
    print(f"kernel image: {real_len} bytes, sha256={real_sha256}")

    if not check_device_exclusive(args.device):
        return 1

    attempt = 1
    while True:
        if attempt > 1:
            print(f"--- retry {attempt}/{args.retries} ---")
        status = _attempt_upload(args, data, real_len, real_sha256)
        if status == 0:
            return 0
        if attempt >= args.retries:
            print(f"[FAIL] giving up after {attempt} attempt(s) -- see --retries to change this")
            return status
        # The board's own 10s stream-inactivity self-abort (kernel_main.vani's
        # task_f drain loop) already clears kernelupload_active/_stream_active
        # by the time send_raw_ack_paced's own IOError reaches here -- no
        # explicit `kernelupload abort` needed before the next attempt's
        # fresh 'kernelupload stream' command, confirmed live (`kernelupload
        # resumestatus` reports clean immediately after every stall this
        # investigation captured). A short settle delay only, same spirit as
        # every other post-hardware-action wait in this project, not a fixed
        # guess at how long recovery takes (there's nothing here TO recover
        # from on the board's side -- it already self-cleaned).
        time.sleep(2)
        attempt += 1


def _attempt_upload(args, data: bytes, real_len: int, real_sha256: str) -> int:
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
        print(f"[board is GO] sending in {args.window_size}-byte windows, blocking for a real ACK after each "
              f"(~{real_len / (args.baud / 10):.0f}s of wire time, plus however long the board's own SD writes "
              f"actually take -- no longer a fixed guess)...")

        t0 = time.time()
        last_print = [0]

        def _progress(sent, total):
            if sent - last_print[0] >= 262144 or sent == total:
                last_print[0] = sent
                print(f"  ...host-side sent {sent}/{total} bytes ({time.time() - t0:.1f}s elapsed)", flush=True)

        try:
            session.send_raw_ack_paced(data, args.window_size, args.ack_timeout, on_progress=_progress)
        except IOError as e:
            print(f"[FAIL] {e}")
            print("---last output---")
            print(session.tail_text())
            return 1
        print(f"  ...all {real_len} bytes sent, each window ACK-confirmed as it went -- "
              f"waiting for the final DONE")

        # Every byte up to real_len was already individually ACK-confirmed
        # above -- the only thing left unconfirmed is the final DONE the
        # board sends instead of a trailing ACK once total_len reaches the
        # declared length (see send_raw_ack_paced's own docstring for why
        # that line is deliberately left for this read_until, not consumed
        # inside the ack-wait loop).
        if not session.read_until("DONE ", timeout=args.stall_timeout):
            print(f"[FAIL] stream finished sending but no DONE within {args.stall_timeout}s")
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
