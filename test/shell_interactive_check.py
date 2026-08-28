#!/usr/bin/env python3
"""Phase 4 task #9: drive Dhruva's interactive shell over QEMU's stdio
UART, waiting on each expected response line rather than a blind sleep
before sending the next command.

STATUS (2026-08-26, superseded 2026-08-28 -- round 31/32 doc-debt
cleanup): kept for reference, but NOT the trusted verification path --
see test/phase4_milestone.py instead (not shell_interactive_check.sh,
despite what this note originally said; see that file's own updated
header for why). Deep investigation the 2026-08-26 session traced test
failures through three real bugs in THIS script (below) before
concluding stdin delivery itself was broken in that sandbox: a raw
hardware-level poll of both BCM2835 UART peripherals' RX status
registers, added directly to kernel_main.vani as a temporary probe,
showed zero bytes EVER arriving at either UART's FIFO under that
session's QEMU, across every input method tried (a bash coprocess
pipe, a raw-mode PTY, sustained slow character streams, multiple
-serial/-nographic flag combinations) -- while output (TX) worked
flawlessly. That conclusion turned out to be sandbox/session-specific,
not a real Dhruva or QEMU limitation: `phase4_milestone.py`'s
`subprocess.Popen(..., stdin=subprocess.PIPE)` + `write() + flush()`
method has reliably driven the shell every round since round 26
(write/cat/eval, then ping/ifconfig/netstat/tcpecho/udpecho on top,
all confirmed live) -- this file's own three-bugs-deep debugging
effort was real, but the environment it was diagnosing turned out not
to be the one every later session actually ran in. Kept as reference
for the event-driven polling technique below (background reader
thread with a consumed-position cursor), which is still sound in
principle, just unnecessary now that the much simpler Popen+write+
sleep approach is confirmed to work end to end. Treat any past "PASS"
from an earlier version of this file with suspicion regardless, since
two of its three original bugs produced false positives, not just
failures.

Second rewrite. The first version used `proc.stdout.read(1)` with no
per-syscall timeout and could hang forever. The second version switched
to a `select()`-based read loop -- which turned out to have its own
real bug: it reliably produced a truncated transcript (only the first
~50 lines of guest output ever captured, then dead silence for the
rest of the run) even though the guest itself was proven completely
healthy for the same duration via both a bare bash coprocess pipeline
and a dead-simple `time.sleep() + write() + time.sleep() +
communicate()` script with no select() involved at all. Whatever the
exact interaction was (select() on a Popen pipe object rather than a
raw fd, some buffering edge case), it cost a huge amount of this
session's time before being caught -- a reminder that when a "guest"
bug's symptoms don't reproduce under a second, independent
verification method (here: a plain bash pipe), the test harness itself
is a live suspect, not just the code under test.

This version uses a background thread that continuously reads from
the child's stdout and appends to a shared buffer + log file, while
the main thread just polls that buffer for expected substrings. No
select() on the Popen object anywhere.
"""
import subprocess
import sys
import threading
import time

ELF = "/home/virgo/source/dhruvaos/build/dhruva.elf"
IMG = "/tmp/dhruva_sd_interactive.img"
LOG_PATH = "/tmp/shell_interactive_full_log.txt"

with open(IMG, "wb") as f:
    f.truncate(64 * 1024 * 1024)

proc = subprocess.Popen(
    [
        "qemu-system-arm", "-M", "raspi1ap", "-nographic",
        "-kernel", ELF,
        "-drive", f"file={IMG},if=sd,format=raw,cache=writethrough",
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)

log_f = open(LOG_PATH, "wb", buffering=0)
buf_lock = threading.Lock()
buf = bytearray()
consumed = 0  # index into `buf`: everything before this has already been
              # matched against by an earlier read_until() call and must
              # not satisfy a later one. Without this, boot-time text
              # already containing e.g. "not found" or "/config/mode"
              # (both printed during kernel_main's own pre-shell FS
              # self-test) would trivially satisfy a LATER step's check
              # for that same substring, regardless of whether the
              # actual shell command being tested did anything at all --
              # found by noticing "PASS" results for steps whose
              # expected text never appears anywhere near the point in
              # the raw log where that command was actually sent.


def reader():
    while True:
        chunk = proc.stdout.read(1)
        if not chunk:
            return
        log_f.write(chunk)
        with buf_lock:
            buf.extend(chunk)


reader_thread = threading.Thread(target=reader, daemon=True)
reader_thread.start()


def read_until(expected, timeout=30):
    global consumed
    want = expected.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        with buf_lock:
            idx = buf.find(want, consumed)
            if idx != -1:
                consumed = idx + len(want)
                return True
        time.sleep(0.1)
    return False


def send(line):
    proc.stdin.write((line + "\r").encode())
    proc.stdin.flush()


# Retries a command up to `attempts` times before giving up. Not papering
# over a real break: this session found that QEMU's own wall-clock speed
# under this host varies a lot run to run (documented repeatedly
# elsewhere in this project), and shell_rx_push_char's own design
# deliberately drops a byte typed while the previous line is still
# ready-but-unconsumed -- exactly what a slow-scheduled tick or a
# still-in-flight prior dispatch produces. A real user facing an
# unresponsive terminal just retypes the command; a genuinely broken
# shell still fails every attempt, so this doesn't hide a real bug.
def step(name, line, expected, timeout=20, attempts=3):
    for attempt in range(attempts):
        send(line)
        if read_until(expected, timeout=timeout):
            results.append((name, True))
            return
    results.append((name, False))


results = []

try:
    ok = read_until("PASS", timeout=60)
    results.append(("boot reaches PASS", ok))

    step("ls shows /config/mode", "ls", "/config/mode")

    # NOT "final" -- kernel_main's own boot sequence appends two more
    # /config/mode values ("post-compact-1", "post-compact-2") after
    # the manual-compaction demo that produces "final", specifically so
    # task_e (GC) has real work to find on its first wake -- "final" is
    # a stale mid-boot value long since superseded by the time the
    # shell is up. Found by an actual '&'/'!' task_f dispatch trace
    # showing a real second command succeed while this literal's own
    # mismatch made it look like a failure.
    step("cat /config/mode == post-compact-2", "cat /config/mode", "post-compact-2")

    step("write /shell/test ok", "write /shell/test hello-shell", "ok")
    step("cat /shell/test == hello-shell", "cat /shell/test", "hello-shell")
    step("ls shows /shell/test", "ls", "/shell/test")
    step("rm /shell/test ok", "rm /shell/test", "ok")
    step("cat /shell/test after rm == not found", "cat /shell/test", "not found")
    step("bogus == unknown command", "bogus", "unknown command")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    reader_thread.join(timeout=2)
    log_f.close()

all_ok = True
for name, ok in results:
    mark = "PASS" if ok else "FAIL"
    if not ok:
        all_ok = False
    print(f"[{mark}] {name}")

sys.exit(0 if all_ok else 1)
