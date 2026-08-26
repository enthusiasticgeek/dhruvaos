#!/usr/bin/env python3
"""Dhruva Phase 0 test harness: boot an ELF under QEMU's raspi1ap machine,
capture UART output, and check for a PASS/FAIL marker.

No physical hardware, no SD card -- QEMU loads the ELF directly via
-kernel and jumps to its entry point (_start, from boot/rpi1/boot.S).
"""

import argparse
import subprocess
import sys

QEMU_BIN = "qemu-system-arm"
MACHINE = "raspi1ap"
DEFAULT_TIMEOUT_S = 10


def run(elf_path: str, timeout_s: float = DEFAULT_TIMEOUT_S) -> tuple[int, str]:
    cmd = [
        QEMU_BIN,
        "-M", MACHINE,
        # -nographic alone routes UART0 to stdio on raspi machines; an
        # explicit `-serial stdio` on top of that double-claims stdio and
        # QEMU refuses to start ("cannot use stdio by multiple character
        # devices") -- found the hard way on the very first real boot.
        "-nographic",
        "-kernel", elf_path,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        output = proc.stdout + proc.stderr
        return proc.returncode, output
    except subprocess.TimeoutExpired as exc:
        # A hang is expected for a kernel that halts in an infinite loop
        # after printing -- we still want whatever it printed before the
        # timeout, so treat this as "ran, then we killed it," not a hard
        # failure by itself. The PASS/FAIL marker check decides that.
        # Python gives back raw bytes here even with text=True on the
        # original call -- decode defensively rather than assume either way.
        def _to_text(chunk):
            if chunk is None:
                return ""
            return chunk.decode("utf-8", "replace") if isinstance(chunk, bytes) else chunk

        output = _to_text(exc.stdout) + _to_text(exc.stderr)
        return 124, output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", help="path to the ELF to boot under QEMU")
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_S,
        help="seconds to let QEMU run before killing it (default: %(default)s)",
    )
    args = parser.parse_args()

    _, output = run(args.elf, timeout_s=args.timeout)
    print(output, end="")

    if "PASS" in output:
        print("\n[qemu_run.py] PASS marker found.", file=sys.stderr)
        return 0
    if "FAIL" in output:
        print("\n[qemu_run.py] FAIL marker found.", file=sys.stderr)
        return 1
    print("\n[qemu_run.py] No PASS/FAIL marker seen before timeout.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
