#!/usr/bin/env python3
"""Dhruva round 74 test harness: boot the Pi 4 (BCM2711) AArch64 image
and verify the first vani-compiled code on this port (kernel/
kernel_main_rpi4.vani) genuinely ran and computed correctly -- not
just that it printed a PASS-looking string. Same style as test/
rpi4_boot_smoke.py: check a specific, meaningful assertion, anchored
to real computed values (sum(1..100)==5050, 100000/7==14285 r5) that
a broken vani-to-AArch64 codegen path would very plausibly get wrong
even while still printing *something*.
"""

import argparse
import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 8
EXPECT_PASS = "vani-compiled code self-test (sum 1..100 + division) (PASS)"
EXPECT_VALUES = "sum=5050 quotient=14285 remainder=5"


def run(elf_path: str, timeout_s: float = DEFAULT_TIMEOUT_S) -> tuple[int, str]:
    cmd = [
        QEMU_BIN,
        "-M", MACHINE,
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
        return proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        def _to_text(chunk):
            if chunk is None:
                return ""
            return chunk.decode("utf-8", "replace") if isinstance(chunk, bytes) else chunk

        return 124, _to_text(exc.stdout) + _to_text(exc.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", help="path to the Pi 4 ELF to boot under QEMU")
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_S,
        help="seconds to let QEMU run before killing it (default: %(default)s)",
    )
    args = parser.parse_args()

    _, output = run(args.elf, timeout_s=args.timeout)
    print(output, end="")

    ok = EXPECT_PASS in output and EXPECT_VALUES in output
    if ok:
        print(f"\n[rpi4_vani_smoke.py] PASS -- vani-compiled self-test PASSed "
              f"and printed the exact correct computed values.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_vani_smoke.py] FAIL -- expected {EXPECT_PASS!r} and "
          f"{EXPECT_VALUES!r}, not both seen.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
