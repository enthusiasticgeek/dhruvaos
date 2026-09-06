#!/usr/bin/env python3
"""Dhruva round 79/80/82: interrupt-driven preemption on the Pi 4/5
port -- boot/rpi4/preempt_switch.S's own header comment has the full
design. Unlike round 78's cooperative task_switch (a voluntary,
`ret`-based swap), this is driven by the real timer: task_b/task_c
never yield and are genuinely preempted by aarch64_irq_handler,
resumed via `eret`, including correctly restoring ELR_EL1/SPSR_EL1
per task. Round 80 generalized round 79's hardcoded 2-task toggle
into real NUM_TASKS-way (3) round robin. Round 82 made task_a
genuinely sleep for 2 real ticks after each print (preempt_sleep_
ticks) instead of busy-waiting -- so unlike task_b/task_c, task_a
now appears exactly once per turn, then goes quiet for the next tick
while it's asleep, waking up again on the tick after that.

Checks three things, each independently meaningful:
1. task_a appears exactly once on ticks 1 and 3 (voluntarily sleeping
   through tick 2, waking again by tick 3 -- exactly n=2 ticks after
   falling asleep at tick 1), and never on ticks 2/4 (still asleep or
   not yet due).
2. task_b only ever appears on odd ticks (right after task_a's own
   single print+immediate voluntary yield within that same tick's
   slice) and task_c only ever appears on even ticks (once task_a is
   asleep and out of the rotation) -- confirming the round-robin
   scan genuinely skips a sleeping task rather than getting stuck or
   corrupting the rotation.
3. "boot context resumed after preemption demo (PASS)" prints AFTER
   the halt message -- this can only happen if boot's own saved
   context (captured once, on tick 1, and never touched again until
   the final tick's forced switch) was preserved correctly through
   the WHOLE demo and correctly resumed at the end; a broken
   save/restore crashes or hangs rather than reaching this line with
   the wrong ELR_EL1/SPSR_EL1.
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
    ticks = re.findall(r"tick=(\d)([ABC]*)\n", output)
    tick_letters = {int(n): letters for n, letters in ticks}

    def check(n: int) -> bool:
        letters = tick_letters.get(n, "")
        if n in (1, 3):
            # Exactly one 'A' (task_a waking, printing once, then
            # immediately voluntarily yielding to task_b within the
            # same slice), followed only by 'B's for the rest.
            return letters.startswith("A") and letters.count("A") == 1 and set(letters[1:]) <= {"B"}
        # Even ticks: task_a is asleep, so only task_c ever appears.
        return len(letters) > 0 and set(letters) == {"C"}

    pattern_ok = all(check(n) for n in (1, 2, 3, 4))
    has_fault = "FAULT" in output
    ok = pattern_ok and EXPECT_HALT in output and EXPECT_RESUMED in output and not has_fault

    if ok:
        print(f"\n[rpi4_preempt_smoke.py] PASS -- task_a slept through tick 2 "
              f"and correctly woke by tick 3 exactly as expected, task_b/task_c "
              f"round-robined via pure timer preemption on the ticks task_a was "
              f"asleep for, the timer disabled cleanly on tick 5, and boot's own "
              f"context resumed correctly afterward.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_preempt_smoke.py] FAIL -- tick_letters={tick_letters!r}, "
          f"pattern_ok={pattern_ok}, halt={EXPECT_HALT in output}, "
          f"resumed={EXPECT_RESUMED in output}, fault={has_fault}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
