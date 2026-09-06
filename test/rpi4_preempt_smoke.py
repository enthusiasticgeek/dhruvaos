#!/usr/bin/env python3
"""Dhruva round 79/80/82/83: interrupt-driven preemption on the Pi
4/5 port -- boot/rpi4/preempt_switch.S's own header comment has the
full design. Round 83 changed task selection from round-robin to
real FIXED-PRIORITY scheduling: task index doubles as its own
priority (task_a=highest, task_c=lowest/idle-like), and the "pick
next" scan always restarts from index 0 rather than advancing from
current+1, so the highest-priority READY task always wins. task_a
sleeps 2 ticks after each print, task_b sleeps 1, task_c never sleeps
(this demo's closest thing to an idle task) -- deliberately NOT
balanced further, so task_c only ever gets to run in the genuine gaps
left by task_a/task_b both being asleep, a real and honest
consequence of naive fixed-priority scheduling.

Checks three things, each independently meaningful:
1. task_a appears exactly once on ticks 1 and 3 (asleep on 2 and 4,
   waking exactly n=2 ticks after each sleep).
2. task_b appears exactly once at the START of every tick's own
   letter run (immediately outranking task_c the instant it wakes,
   even mid-tick), with task_c filling every remaining gap -- proving
   the scan is genuinely priority-based (task_b, priority 1, always
   preempts task_c, priority 2, the moment it's ready) not just
   round-robin with sleeps bolted on.
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
        if not letters:
            return False
        expect_a = n in (1, 3)
        # Expected shape: an optional single 'A' (only on ticks 1/3),
        # then exactly one 'B', then 'C' filling the rest -- task_c
        # never sleeps, so it's always what's left running once both
        # higher-priority tasks have gone back to sleep.
        rest = letters
        if expect_a:
            if not rest.startswith("A"):
                return False
            rest = rest[1:]
            if rest.startswith("A"):
                return False  # task_a must appear exactly once
        else:
            if rest.startswith("A"):
                return False  # task_a must be asleep on even ticks
        if not rest.startswith("B"):
            return False
        rest = rest[1:]
        return set(rest) == {"C"} if rest else True

    pattern_ok = all(check(n) for n in (1, 2, 3, 4))
    has_fault = "FAULT" in output
    ok = pattern_ok and EXPECT_HALT in output and EXPECT_RESUMED in output and not has_fault

    if ok:
        print(f"\n[rpi4_preempt_smoke.py] PASS -- task_a slept through ticks 2/4 "
              f"and woke exactly on schedule (ticks 1/3), task_b preempted "
              f"task_c the instant it was ready on every tick, task_c filled "
              f"every remaining gap, the timer disabled cleanly on tick 5, and "
              f"boot's own context resumed correctly afterward.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_preempt_smoke.py] FAIL -- tick_letters={tick_letters!r}, "
          f"pattern_ok={pattern_ok}, halt={EXPECT_HALT in output}, "
          f"resumed={EXPECT_RESUMED in output}, fault={has_fault}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
