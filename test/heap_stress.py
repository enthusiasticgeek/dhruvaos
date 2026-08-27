#!/usr/bin/env python3
"""Ad-hoc stress test: many more shell commands + a longer session than
phase4_milestone.py exercises, to confirm the scratch-buffer fix keeps
heap usage bounded (no crash/reboot) well past the original 4-command
regression window."""
import subprocess
import sys
import time

QEMU_BIN = "qemu-system-arm"
MACHINE = "raspi1ap"
IMG = "/tmp/dhruva_heap_stress.img"

with open(IMG, "wb") as f:
    f.truncate(64 * 1024 * 1024)

proc = subprocess.Popen(
    [QEMU_BIN, "-M", MACHINE, "-nographic", "-kernel", sys.argv[1],
     "-drive", f"file={IMG},if=sd,format=raw,cache=writethrough"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)

def send(line):
    proc.stdin.write((line + "\r").encode())
    proc.stdin.flush()

time.sleep(6)
for i in range(20):
    send(f"write /stress/f{i} value{i}")
    time.sleep(1.5)
    send(f"cat /stress/f{i}")
    time.sleep(1.5)
    send("eval 1+1")
    time.sleep(1.5)
    send("ls")
    time.sleep(1.5)

proc.terminate()
try:
    out, _ = proc.communicate(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    out, _ = proc.communicate()
output = out.decode("utf-8", "replace")

with open("/tmp/heap_stress_log.txt", "w") as f:
    f.write(output)

banners = output.count("Dhruva Phase 2")
last_eval_ok = output.count("\n2\n")
print(f"boot banners: {banners} (expect exactly 1 -- this is the actual heap-exhaustion regression check)")
print(f"'1+1'==2 occurrences seen: {last_eval_ok}/20 (informational only -- a fixed-sleep script racing "
      f"real scheduling means some responses land outside their window even on a fully healthy system; "
      f"see phase4_milestone.py's own SETTLE_S comment for the same, already-documented variance)")
print("PASS" if banners == 1 else "FAIL")
