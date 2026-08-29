#!/usr/bin/env python3
"""Dhruva round 43 test harness: boot the Pi 4 (BCM2711) AArch64 boot
skeleton under QEMU's raspi4b machine, capture PL011 UART output, and
verify the EL3->EL1 privilege drop genuinely happened -- not just that
QEMU didn't crash.

Establishes the first verification convention for this new target,
mirroring test/qemu_run.py's own shape for the Pi 1 (ARM32) side, but
checking a specific, meaningful assertion rather than a generic PASS/
FAIL marker: boot/rpi4/boot.S prints "CurrentEL=" followed by the
value read live AT EL1 after the drop. A CORRECT drop prints "1"; if
the EL3->EL1 transition silently failed and execution kept running at
EL3 (or landed somewhere else, e.g. EL2), this would show the wrong
digit or (more likely) never print anything at all, since a broken
SPSR_EL3/HCR_EL2/SCR_EL3 configuration is far more likely to fault
before ever reaching kmain_rpi4 than to hobble along in the wrong
state.
"""

import argparse
import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 8
EXPECT = "CurrentEL=1"


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
        # Expected: boot.S halts in an infinite `wfe` loop after
        # printing, same "a hang after printing is success, not
        # failure" convention test/qemu_run.py already established for
        # the Pi 1 side.
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

    if EXPECT in output:
        print(f"\n[rpi4_boot_smoke.py] PASS -- {EXPECT!r} seen, EL3->EL1 drop confirmed live.",
              file=sys.stderr)
        return 0
    print(f"\n[rpi4_boot_smoke.py] FAIL -- {EXPECT!r} not seen before timeout.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
