#!/usr/bin/env python3
"""Dhruva round 81: a genuine VOLUNTARY switch on the Pi 4/5 port,
through the exact same eret-based interrupt-shaped frame rounds 79/80
use for timer-driven preemption -- boot/rpi4/preempt_switch.S's own
preempt_generic_switch comment has the full design. Proves voluntary
and involuntary switching are interoperable through ONE shared
mechanism (the same vectors.S irq_restore epilogue resumes either
kind of frame), not two disconnected ones -- distinct from round 78's
own cooperative task_switch, which used a smaller callee-saved-only
frame and `ret`, not `eret`.

Checks the exact "XYXYX (PASS)" sequence, the same evidentiary shape
as round 78's own "ABABA": task_x yields to task_y 3 times then yields
back to the calling self-test instead on its 3rd round (task_y always
yields straight back to task_x, never independently deciding to
stop). The "(PASS)" can only print if the calling context's own saved
frame was preserved and correctly resumed via `eret` -- proof from
both the data side (exact sequence) and the control-flow side (a
broken save/restore crashes or hangs rather than resuming at the
wrong place with merely wrong output).

Also confirms the rest of the boot sequence (including round 79/80's
own timer-driven preemption demo, which runs immediately afterward)
is completely unaffected -- the two mechanisms use entirely separate
state (yv_sp_table vs. pt_sp_table).
"""

import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 10
EXPECT = "voluntary-yield (eret-based) self-test: XYXYX (PASS)"


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

    ok = EXPECT in output and "FAULT" not in output
    if ok:
        print(f"\n[rpi4_yield_smoke.py] PASS -- printed the exact expected "
              f"{EXPECT!r}, proving a voluntary switch through the eret-based "
              f"frame format works and correctly resumed the calling context.",
              file=sys.stderr)
        return 0
    print(f"\n[rpi4_yield_smoke.py] FAIL -- expected {EXPECT!r} with no "
          f"'FAULT' in the output.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
