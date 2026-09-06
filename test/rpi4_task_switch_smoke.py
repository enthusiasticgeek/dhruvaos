#!/usr/bin/env python3
"""Dhruva round 78: the smallest possible proof of an ARMv8-A context
switch on the Pi 4/5 port -- boot/rpi4/task_switch.S's own header
comment has the full design (a cooperative, voluntary-yield swap
between two static stacks, deliberately NOT the real interrupt-driven
scheduler). This checks kernel_main_rpi4.vani's own
task_switch_self_test prints the exact expected "ABABA" sequence
(3 prints from task_a, 2 from task_b, strictly alternating) and then
"(PASS)" -- which can only ever print if boot's own context genuinely
resumed at the correct point after all 6 switches in the A/B/A/B/A/
boot chain landed correctly. A broken switch crashes or hangs rather
than resuming at the wrong place with merely wrong output, so this is
really two independent checks: the exact printed sequence (data) and
reaching "(PASS)" at all (control-flow integrity).
"""

import subprocess
import sys

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 8
EXPECT = "task-switch self-test: ABABA (PASS)"


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
        print(f"\n[rpi4_task_switch_smoke.py] PASS -- task_switch_self_test printed "
              f"the exact expected {EXPECT!r}, proving all 6 cooperative context "
              f"switches (boot->A->B->A->B->A->boot) landed correctly.",
              file=sys.stderr)
        return 0
    print(f"\n[rpi4_task_switch_smoke.py] FAIL -- expected {EXPECT!r} with no "
          f"'FAULT' in the output.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
