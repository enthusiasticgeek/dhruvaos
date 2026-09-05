#!/usr/bin/env python3
"""Dhruva round 74/75 test harness: boot the Pi 4 (BCM2711) AArch64
image and verify vani-compiled code on this port genuinely ran and
computed correctly -- not just that it printed a PASS-looking string.
Same style as test/rpi4_boot_smoke.py: check a specific, meaningful
assertion, anchored to real computed values (sum(1..100)==5050,
100000/7==14285 r5) that a broken vani-to-AArch64 codegen path would
very plausibly get wrong even while still printing *something*.

Round 75 widened this to also cover the SECOND vani-on-Pi4 call site:
kernel_main_rpi4.vani's rpi4_handle_timer_irq, called from boot/rpi4/
vectors.S's aarch64_irq_handler on every real timer tick (not just
once at boot, the way round 74's own kmain_rpi4_vani proof was) --
checking for 5 distinct tick prints plus the halt message proves vani
code keeps executing correctly across repeated, interrupt-driven
invocations, not just a single one-shot boot-time call.
"""

import argparse
import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 8
EXPECT_PASS = "vani-compiled code self-test (sum 1..100 + division) (PASS)"
EXPECT_VALUES = "sum=5050 quotient=14285 remainder=5"
EXPECT_TICK_COUNT = 5
EXPECT_HALT = "5 real timer IRQs handled, halting"


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

    tick_count = output.count("real timer IRQ handled, tick=")
    ok = (
        EXPECT_PASS in output
        and EXPECT_VALUES in output
        and tick_count == EXPECT_TICK_COUNT
        and EXPECT_HALT in output
    )
    if ok:
        print(f"\n[rpi4_vani_smoke.py] PASS -- boot-time vani self-test PASSed "
              f"with the exact correct computed values, and the interrupt-driven "
              f"vani code (rpi4_handle_timer_irq) ran correctly on all "
              f"{EXPECT_TICK_COUNT} real timer ticks then halted.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_vani_smoke.py] FAIL -- expected {EXPECT_PASS!r}, "
          f"{EXPECT_VALUES!r}, {EXPECT_TICK_COUNT} tick prints (saw "
          f"{tick_count}), and {EXPECT_HALT!r}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
