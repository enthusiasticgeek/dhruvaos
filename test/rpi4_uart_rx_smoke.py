#!/usr/bin/env python3
"""Dhruva round 77: the first bidirectional-I/O test on the Pi 4/5
port. Everything verified on this target before now (rounds 74-76)
was output-only (boot self-test, timer IRQ, GPIO) -- this drives real
characters IN over QEMU's stdio UART and checks they come back out,
proving kernel_main_rpi4.vani's own rpi4_handle_uart_rx_irq genuinely
receives a live PL011 RX interrupt and echoes correctly, not just that
the code compiles.

Uses phase4_milestone.py's own trusted technique (subprocess.Popen +
timed stdin writes + a final communicate()) rather than the
select()-based approach an earlier Pi 1 test (shell_interactive_check.
py) spent a long session chasing false alarms with -- see that file's
own header for the full story. No shell/line-buffering exists on this
port yet (no task/scheduler infrastructure for one to live in), so
this sends a short, distinctive, un-terminated character sequence and
checks for its exact echo, not a command+response line.

Boot completes, arms the RX interrupt, then the CPU parks in an
infinite `wfi` loop (boot/rpi4/boot.S's own heartbeat_loop) -- stays
IRQ-responsive forever after, even after the unrelated timer self-test
disables itself post-5-ticks, so there's no race to time input
against a closing window.
"""

import subprocess
import sys
import time

QEMU_BIN = "qemu-system-aarch64"
MACHINE = "raspi4b"
DEFAULT_TIMEOUT_S = 15
SETTLE_S = 3  # time to let boot + RX-arm complete before sending input
ECHO_WAIT_S = 2
PROBE = "Q9z"
EXPECT_ARMED = "UART0 RX interrupt armed, echoing input"


def run(elf_path: str, timeout_s: float = DEFAULT_TIMEOUT_S) -> tuple[int, str]:
    proc = subprocess.Popen(
        [
            QEMU_BIN, "-M", MACHINE, "-nographic",
            "-kernel", elf_path,
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        time.sleep(SETTLE_S)
        proc.stdin.write(PROBE.encode())
        proc.stdin.flush()
        time.sleep(ECHO_WAIT_S)
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

    armed_idx = output.find(EXPECT_ARMED)
    echoed = armed_idx != -1 and PROBE in output[armed_idx:]
    ok = EXPECT_ARMED in output and echoed
    if ok:
        print(f"\n[rpi4_uart_rx_smoke.py] PASS -- UART0 RX interrupt armed, "
              f"and the probe string {PROBE!r} sent over stdin was echoed "
              f"back correctly by rpi4_handle_uart_rx_irq.", file=sys.stderr)
        return 0
    print(f"\n[rpi4_uart_rx_smoke.py] FAIL -- expected {EXPECT_ARMED!r} "
          f"followed by an echo of {PROBE!r}, got armed={armed_idx != -1}, "
          f"echoed={echoed}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
