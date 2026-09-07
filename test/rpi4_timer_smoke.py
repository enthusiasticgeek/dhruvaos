#!/usr/bin/env python3
"""Dhruva round 70 test harness: boot the Pi 4 (BCM2711) AArch64
GIC + generic-timer bring-up under QEMU's raspi4b machine, and verify
a real, periodic, interrupt-driven heartbeat genuinely happened -- not
just that QEMU didn't crash.

Mirrors test/rpi4_boot_smoke.py's own shape (round 43), checking a
specific, meaningful assertion: boot/rpi4/vectors.S's aarch64_irq_
handler prints "tick=" once per real timer IRQ it acknowledges and
EOIs, counting up to 5 before disabling the timer and printing a
final "halting" line. A broken GIC/timer init (wrong INTID, GICD/GICC
never enabled, IRQ never unmasked at the PSTATE level, a handler that
doesn't EOI and stalls the GIC) would show zero "tick=" lines rather
than five, or would hang without ever reaching the halting line.

Round 98 bumped DEFAULT_TIMEOUT_S from 8 to 20: extracting the SHA-
256/512/curve25519/Ed25519/PKI crypto code into standalone kosh
packages (vendor/crypto_hash, vendor/curve25519, vendor/pki, pulled
in via `use`) shifted real QEMU TCG boot timing enough that the boot
sequence + 5-tick preemption demo no longer reliably finished inside
the old 8s window on this machine -- confirmed via a manual --timeout
20 rerun that the boot sequence itself is unchanged and correct, this
was purely a margin issue, not a regression.
"""

import argparse
import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 20
EXPECT_HALT = "5 real timer IRQs handled, halting"
EXPECT_TICK_COUNT = 5


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
        # Expected: after halting, boot.S's heartbeat_loop sits in wfi
        # forever with no more incoming interrupts (the timer was
        # explicitly disabled) -- a hang after the halt line is
        # success, not failure, same convention every other QEMU test
        # in this project already uses.
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

    tick_count = output.count("real timer IRQ handled, tick=")
    halted = EXPECT_HALT in output

    if tick_count == EXPECT_TICK_COUNT and halted:
        print(f"\n[rpi4_timer_smoke.py] PASS -- exactly {EXPECT_TICK_COUNT} real timer "
              "IRQs handled and EOI'd, then a clean halt.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_timer_smoke.py] FAIL -- saw {tick_count} tick(s) "
          f"(expected {EXPECT_TICK_COUNT}), halted={halted}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
