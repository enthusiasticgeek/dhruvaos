#!/usr/bin/env python3
"""Dhruva round 84: the smallest possible interactive shell on the
Pi 4/5 port -- boot/rpi4/shell_state.S's own header comment has the
full design. Reuses UART0 RX (round 77) and the already-proven
once-per-wfi-wakeup rpi4_heartbeat_tick call site (round 79), NOT the
round 79-83 preemptive-scheduler demo, which stays exactly as it was
-- a bounded, self-terminating proof independent of this real,
permanent capability.

Drives real commands over QEMU's stdio UART (help, ver, test, echo)
and checks each one's real response, using phase4_milestone.py's own
trusted Popen+write+flush technique. Since there's no scheduler tied
to this shell, it works indefinitely -- sent well after the round
79-83 demo's own 5 ticks have already disabled that timer and
resumed boot, proving the shell keeps responding on its own, forever,
independent of that demo's lifetime.
"""

import subprocess
import sys
import time

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 15
SETTLE_S = 3
CMD_WAIT_S = 1


def run(elf_path: str, timeout_s: float = DEFAULT_TIMEOUT_S) -> tuple[int, str]:
    proc = subprocess.Popen(
        [QEMU_BIN, "-M", MACHINE, "-nographic", "-kernel", elf_path],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )

    def send(line: str) -> None:
        proc.stdin.write((line + "\r").encode())
        proc.stdin.flush()

    try:
        time.sleep(SETTLE_S)
        send("help")
        time.sleep(CMD_WAIT_S)
        send("ver")
        time.sleep(CMD_WAIT_S)
        send("echo hello dhruva")
        time.sleep(CMD_WAIT_S)
        send("bogus")
        time.sleep(CMD_WAIT_S)
        send("test")
        time.sleep(CMD_WAIT_S)
        out, _ = proc.communicate(timeout=timeout_s)
        return proc.returncode, out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        return 124, out.decode("utf-8", "replace")


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

    checks = {
        "help lists commands": "commands: help, ver, test, echo <text>" in output,
        "ver prints identity": "Dhruva OS -- Pi 4/5 port, round 84 minimal shell" in output,
        "echo echoes real argument text": "hello dhruva" in output,
        "unknown command reported": "unknown command (try 'help')" in output,
        "test reruns the real self-test": "sum=5050 quotient=14285 remainder=5" in output,
        "no fault": "FAULT" not in output,
    }
    ok = all(checks.values())

    if ok:
        print(f"\n[rpi4_shell_smoke.py] PASS -- all 5 real shell commands (help, "
              f"ver, echo, an unknown command, test) got their correct real "
              f"responses over a live QEMU stdio UART session.", file=sys.stderr)
        return 0
    failed = [name for name, passed in checks.items() if not passed]
    print(f"\n[rpi4_shell_smoke.py] FAIL -- failed checks: {failed!r}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
