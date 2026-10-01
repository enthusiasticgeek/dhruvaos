#!/usr/bin/env python3
"""Real-hardware DHDL spot-check over a live serial port.

Task #306/#307 follow-up: the first attempt at this (2026-10-01) attached
to an already-running, already-chattering Pi 1B with no synchronization
point and a blind fixed-delay send loop -- some commands' responses got
interleaved with background demo-task chatter and never matched, even
across retries, because nothing in that script ever re-synchronized the
read cursor once it desynced. `ShellSession.wait_until_ready()` (test/
wifikey_upload.py) exists for exactly this: it resends the kernel's own
trivial, idempotent `ready` command until a clean `READY` response is
seen, giving a real synchronization point BEFORE any command whose
response actually matters gets sent -- unlike the boot-time "PASS"
marker every other script here waits for, which is a one-shot broadcast
only useful right after a fresh reset.

Usage:
  python3 test/dhdl_realhw_check.py /dev/ttyUSB0
  python3 test/dhdl_realhw_check.py /dev/pts/5 --baud 115200
"""
import argparse
import os
import sys
import time

from wifikey_upload import open_serial, ShellSession

STEPS = [
    ("dhdl list", "ble"),
    ("dhdl query loglevel", "mask=0x"),
    ("dhdl query sd", "rca="),
    ("dhdl query gpio", "pin 53"),
    ("dhdl query display", "pitch="),
    ("dhdl query dma", "channel5_busy="),
    ("dhdl query ram", "allocations="),
    ("dhdl query usb", "port_enabled="),
    ("dhdl query ethernet", "none enumerated"),
    ("dhdl query wifi", "none enumerated"),
    ("dhdl query ble", "none enumerated"),
    ("dhdl set loglevel 12", "ok"),
    ("dhdl query loglevel", "0x0000000C"),
    ("dhdl set loglevel 0", "ok"),
    ("dhdl set sd 1", "does not support"),
    ("dhdl set bogus 1", "unknown subsystem"),
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", help="serial device, e.g. /dev/ttyUSB0 (real hardware) or /dev/pts/N (QEMU -serial pty)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ready-timeout", type=float, default=30, help="seconds to wait for the ready/READY handshake before giving up")
    ap.add_argument("--step-timeout", type=float, default=8)
    ap.add_argument("--step-attempts", type=int, default=3)
    ap.add_argument("--log", default="/tmp/dhdl_realhw_check.log")
    args = ap.parse_args()

    fd = open_serial(args.device, args.baud)
    session = ShellSession(fd, args.log)

    try:
        print("synchronizing (ready/READY handshake)...")
        if not session.wait_until_ready(overall_timeout=args.ready_timeout):
            print(f"[FAIL] never got a clean READY within {args.ready_timeout}s -- is the device connected and the board running this firmware version?")
            return 1
        print("[synchronized]")

        results = []
        for cmd, expected in STEPS:
            ok = session.step(cmd, expected, timeout=args.step_timeout, attempts=args.step_attempts)
            results.append((cmd, expected, ok))
            print(f"{'OK  ' if ok else 'FAIL'} {cmd!r} -> waited for {expected!r}")

        n_ok = sum(1 for _, _, ok in results if ok)
        print(f"\n{n_ok}/{len(results)} steps confirmed")
        return 0 if n_ok == len(results) else 1
    finally:
        time.sleep(1)
        session.close()
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
