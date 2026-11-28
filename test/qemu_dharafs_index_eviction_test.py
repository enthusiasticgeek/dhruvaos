#!/usr/bin/env python3
"""QEMU regression test: DharaFS directory-index eviction must not hide files.

The directory index has 256 slots. Before 2026-11-27, LRU eviction left the
index flagged "complete", so a file whose entry was evicted was reported
"(not found)" without a log scan -- and compaction treated its records as
dead. This writes more distinct files than the index holds, reads back the
earliest (evicted) ones, then reboots on the same card and reads them again
(exercising the persisted-snapshot boot path).

Usage: python3 test/qemu_dharafs_index_eviction_test.py build/dhruva.elf
"""
import os
import select
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "test"))
import phase4_milestone as p4  # noqa: E402

N_FILES = 300          # > dirindex_max_slots() (256)
CHECK = [0, 1, 2, 3, 50, 150, 299]


def boot(elf, sd):
    q = subprocess.Popen([p4.QEMU_BIN, "-M", p4.MACHINE, "-nographic", "-kernel", elf,
                          "-drive", f"file={sd},if=sd,format=raw,cache=writethrough"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = p4._wait_for_boot_ready(q, p4.BOOT_READY_TIMEOUT_S)
    buf = p4._wait_for_recovery_complete(q, buf, p4.BOOT_READY_TIMEOUT_S)
    return q, {"buf": buf}


def make_cmd(q, st):
    def pump(sec, until, since):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([q.stdout], [], [], 0.2)
            if r:
                ch = q.stdout.read1(4096)
                if not ch:
                    return False
                st["buf"] += ch
                if until in st["buf"][since:]:
                    return True
        return False

    def cmd(line, until, sec=20):
        mark = len(st["buf"])
        q.stdin.write((line + "\r").encode())
        q.stdin.flush()
        pump(sec, until, mark)
        return st["buf"][mark:].decode(errors="replace")
    return cmd


def check_files(cmd, label):
    bad = []
    for i in CHECK:
        out = cmd(f"cat /e{i}", f"val{i}x".encode(), 180)
        if f"val{i}x" not in out:
            bad.append((i, out.strip().splitlines()[-1] if out.strip() else ""))
    print(f"{label}: {len(CHECK) - len(bad)}/{len(CHECK)} sampled files readable", "" if not bad else bad[:3])
    return not bad


def main() -> int:
    elf = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="dxevict_")
    sd = os.path.join(tmp, "sd.img")
    with open(sd, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    q, st = boot(elf, sd)
    cmd = make_cmd(q, st)
    ok = True
    try:
        t0 = time.time()
        for i in range(N_FILES):
            out = cmd(f"write /e{i} val{i}x", b"ok", 180)   # `write` answers "ok"/"error"
            if "ok" not in out:
                print(f"  write /e{i} did not answer ok: {out.strip()[-80:]!r}", flush=True)
            if (i + 1) % 25 == 0:
                print(f"  {i + 1} files, {time.time() - t0:.0f}s", flush=True)
        print(f"wrote {N_FILES} files in {time.time() - t0:.0f}s")
        ok &= check_files(cmd, "same boot (after eviction)")
        cmd("shutdown", b"SAFE TO POWER OFF", 60)
    finally:
        q.kill()
        q.wait()
    q, st = boot(elf, sd)
    cmd = make_cmd(q, st)
    try:
        ok &= check_files(cmd, "after reboot (snapshot path)")
    finally:
        q.kill()
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
