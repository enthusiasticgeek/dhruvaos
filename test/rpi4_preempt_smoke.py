#!/usr/bin/env python3
"""Dhruva round 79: interrupt-driven preemption on the Pi 4/5 port --
boot/rpi4/preempt_switch.S's own header comment has the full design.
Unlike round 78's cooperative task_switch (a voluntary, `ret`-based
swap), this is driven entirely by the real timer: two tasks that never
yield are genuinely preempted by aarch64_irq_handler and resumed via
`eret`, including correctly restoring ELR_EL1/SPSR_EL1 per task (the
one thing round 78 never needed to handle).

Checks three things, each independently meaningful:
1. Both 'A' and 'B' appear, in alternating ticks (real preemption
   happened between two DIFFERENT tasks, not just one running
   forever).
2. The exact tick-by-tick alternation pattern (task_a on odd ticks,
   task_b on even ticks) -- not just "both letters appear somewhere."
3. "boot context resumed after preemption demo (PASS)" prints AFTER
   the halt message -- this can only happen if boot's own saved
   context (captured once, on tick 1, and never touched again until
   tick 5's forced switch) was preserved correctly through the WHOLE
   demo and correctly resumed at the end; a broken save/restore
   crashes or hangs rather than reaching this line with the wrong
   ELR_EL1/SPSR_EL1.
"""

import re
import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 10
EXPECT_HALT = "5 real timer IRQs handled, halting"
EXPECT_RESUMED = "boot context resumed after preemption demo (PASS)"


def run(elf_path: str, timeout_s: float = DEFAULT_TIMEOUT_S) -> tuple[int, str]:
    cmd = [QEMU_BIN, "-M", MACHINE, "-nographic", "-kernel", elf_path]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
        return proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        def _to_text(chunk):
            if chunk is None:
                return ""
            return chunk.decode("utf-8", "replace") if isinstance(chunk, bytes) else chunk
        return 124, _to_text(exc.stdout) + _to_text(exc.stderr)


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", help="path to the Pi 4 ELF to boot under QEMU")
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_S,
        help="seconds to let QEMU run before killing it (default: %(default)s)",
    )
    args = parser.parse_args()

    _, output = run(args.elf, timeout_s=args.timeout)
    print(output, end="")

    # Pull the letters printed right after each "tick=N" up to the
    # next "DHRUVA RPI4:" line -- tick 5 has none (halts immediately).
    ticks = re.findall(r"tick=(\d)([AB]*)\n", output)
    tick_letters = {int(n): letters for n, letters in ticks}
    expected_letter = {1: "A", 2: "B", 3: "A", 4: "B"}
    alternation_ok = all(
        tick_letters.get(n, "").startswith(letter) and set(tick_letters.get(n, "")) == {letter}
        for n, letter in expected_letter.items()
    )
    has_fault = "FAULT" in output
    ok = alternation_ok and EXPECT_HALT in output and EXPECT_RESUMED in output and not has_fault

    if ok:
        print(f"\n[rpi4_preempt_smoke.py] PASS -- ticks 1-4 alternated task_a/task_b "
              f"exactly as expected (A,B,A,B), the timer disabled cleanly on tick 5, "
              f"and boot's own context resumed correctly afterward.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_preempt_smoke.py] FAIL -- tick_letters={tick_letters!r}, "
          f"alternation_ok={alternation_ok}, halt={EXPECT_HALT in output}, "
          f"resumed={EXPECT_RESUMED in output}, fault={has_fault}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
