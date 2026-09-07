#!/usr/bin/env python3
"""Dhruva round 84: the smallest possible interactive shell on the
Pi 4/5 port -- boot/rpi4/shell_state.S's own header comment has the
full design. Reuses UART0 RX (round 77) and the already-proven
once-per-wfi-wakeup rpi4_heartbeat_tick call site (round 79), NOT the
round 79-83 preemptive-scheduler demo, which stays exactly as it was
-- a bounded, self-terminating proof independent of this real,
permanent capability. Round 86 added a `netif` command rerunning the
loopback netif self-test (boot/rpi4/netif_state.S's own header
comment has that design). Round 87 added an `arp` command rerunning
both ARP self-tests (boot/rpi4/arp_state.S's own header comment has
that design). Round 88 added `ip` (IPv4 header build/parse self-test)
and `filter` (packet filter self-tests, boot/rpi4/filter_state.S's
own header comment has that design). Round 89 added `tcp` (the TCP
header layer self-test plus a full connection-lifecycle self-test,
boot/rpi4/tcp_state.S's own header comment has that design). Round 90
added `udp` (the UDP/socket-API self-test -- UDP has no persistent
state, so no new boot/rpi4/*.S file was needed). Round 91 added `dhcp`
(the DHCP client self-test, DISCOVER->OFFER->REQUEST->ACK->BOUND,
boot/rpi4/dhcp_state.S's own header comment has that design). Round
92 added `dhcps` (the DHCP SERVER self-test -- brand-new design, no
kernel_main.vani precedent -- boot/rpi4/dhcp_server_state.S's own
header comment has that design). Round 93 added `netcfg` (static IP
configuration, the DHCP-alternative path -- brand-new design,
boot/rpi4/netconfig_state.S's own header comment has that design).
Round 94 added `sha512` (the first step of the SHA-512 ->
field25519/X25519 -> Ed25519 -> PKI crypto chain). Round 95 added
`x25519` (field25519 field arithmetic + X25519 Diffie-Hellman, step 2
of that chain). Round 96 added `ed25519` (EdDSA sign/verify, step 3
of that chain). Round 97 added `pki` (raw public-key trust, the LAST
link of that chain -- a one-line wrapper around `ed25519_verify_rpi4`).

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
DEFAULT_TIMEOUT_S = 40
# Round 96 added ed25519_self_test_rpi4 to the boot sequence AND as a
# shell command -- Ed25519's own double-and-add point-multiplication
# ladder does far more field arithmetic per bit than X25519's single
# ladder (a full 8-field-mul point_add, called twice per bit, times
# up to 4-5 full 256-bit scalar mults across pubkey/sign/verify), and
# under QEMU TCG emulation this measurably shows up as real wall-clock
# time (~2s per self-test run, confirmed via a direct timestamped
# probe) rather than the near-instant SHA/X25519 self-tests. SETTLE_S
# bumped from 3 to comfortably clear the now-~5.7s boot-to-shell-ready
# window (all boot self-tests + the 5-tick preemption demo); CMD_WAIT_S
# bumped from 1 to comfortably exceed ed25519's own ~2s per-command
# runtime so the next command isn't sent while it's still computing.
#
# Round 100 (Pi1 X25519/Ed25519 migration) added a 130-byte KAT to
# curve25519's own ed25519_self_test (proving the streaming-SHA-512
# redesign that removed the old 64-byte msg cap actually works) --
# confirmed via a direct timestamped probe this pushed the shell's
# own `ed25519` command to ~2.9s, right at the edge of the old 3s
# CMD_WAIT_S margin (and the intermittent `pki` failures this exposed
# traced to exactly that: the next command's keystrokes landing while
# ed25519_self_test was still running, getting lost rather than
# dispatched). Bumped CMD_WAIT_S to 5 for solid headroom.
SETTLE_S = 7
CMD_WAIT_S = 5


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
        send("sha256")
        time.sleep(CMD_WAIT_S)
        send("sha512")
        time.sleep(CMD_WAIT_S)
        send("x25519")
        time.sleep(CMD_WAIT_S)
        send("ed25519")
        time.sleep(CMD_WAIT_S)
        send("pki")
        time.sleep(CMD_WAIT_S)
        send("netif")
        time.sleep(CMD_WAIT_S)
        send("arp")
        time.sleep(CMD_WAIT_S)
        send("ip")
        time.sleep(CMD_WAIT_S)
        send("filter")
        time.sleep(CMD_WAIT_S)
        send("tcp")
        time.sleep(CMD_WAIT_S)
        send("udp")
        time.sleep(CMD_WAIT_S)
        send("dhcp")
        time.sleep(CMD_WAIT_S)
        send("dhcps")
        time.sleep(CMD_WAIT_S)
        send("netcfg")
        time.sleep(CMD_WAIT_S)
        send("mqtt")
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
        "help lists commands": "commands: help, ver, test, sha256, sha512, x25519, ed25519, pki, netif, arp, ip, filter, tcp, udp, dhcp, dhcps, netcfg, mqtt, echo <text>" in output,
        "ver prints identity": "Dhruva OS -- Pi 4/5 port, round 109 minimal shell + crypto + netif + arp + ip + filter + tcp + udp + dhcp + dhcps + netcfg + mqtt" in output,
        "echo echoes real argument text": "hello dhruva" in output,
        "unknown command reported": "unknown command (try 'help')" in output,
        "test reruns the real self-test": "sum=5050 quotient=14285 remainder=5" in output,
        "sha256 reruns the crypto self-test": output.count(
            'CRYPTO: SHA-256 vs 3 NIST/FIPS-180-4 KATs (empty, "abc", 2-block) (PASS)'
        ) >= 2,
        "sha512 reruns the crypto self-test": output.count(
            'CRYPTO: SHA-512 vs 4 FIPS-180-4 KATs (empty, "abc", 111-byte, 112-byte 2-block) (PASS)'
        ) >= 2,
        "x25519 reruns the crypto self-test": output.count(
            "CRYPTO: X25519 vs kernel_main.vani's own verified reference (base-point + DH agreement) (PASS)"
        ) >= 2,
        "ed25519 reruns the crypto self-test": output.count(
            "CRYPTO: Ed25519 vs kernel_main.vani's own verified reference (pubkey+sign+verify+tamper) (PASS)"
        ) >= 2,
        "pki reruns the crypto self-test": output.count(
            "CRYPTO: PKI raw public-key trust vs kernel_main.vani's own verified reference (genuine sig + tamper reject) (PASS)"
        ) >= 2,
        "netif reruns the loopback self-test": output.count(
            "NET: loopback netif send/recv + empty/full queue edge cases (PASS)"
        ) >= 2,
        "arp reruns both ARP self-tests": (
            output.count("ARP: build/parse round trip + cache insert/lookup/update (PASS)") >= 2
            and output.count("ARP: arp_resolve_start/poll live round trip (PASS)") >= 2
        ),
        "ip reruns the IPv4 self-test": output.count(
            "IPV4: build/send/recv + checksum verify (PASS)"
        ) >= 2,
        "filter reruns both packet-filter self-tests": (
            output.count("FW: packet filter rule matching (default/specific/proto/order/port/non-ip) (PASS)") >= 2
            and output.count("FW: outgoing packet filtering (netif_send_frame egress hook, directional src/dst semantics) (PASS)") >= 2
        ),
        "tcp reruns both TCP self-tests": (
            output.count("TCP: header build/send/recv + checksum verify (SYN) (PASS)") >= 2
            and output.count("TCP: connection lifecycle (handshake + data + close) (PASS)") >= 2
        ),
        "udp reruns the UDP self-test": output.count(
            "UDP: socket send/recv over loopback + checksum (PASS)"
        ) >= 2,
        "dhcp reruns the DHCP client self-test": output.count(
            "DHCP: client DISCOVER->OFFER->REQUEST->ACK->BOUND (PASS)"
        ) >= 2,
        "dhcps reruns the DHCP server self-test": output.count(
            "DHCPS: server DISCOVER->OFFER, REQUEST->ACK, unknown-MAC REQUEST->NAK (PASS)"
        ) >= 2,
        "netcfg reruns the static IP config self-test": output.count(
            "NETCFG: static IP config + unconfigured/invalid rejection + DHCP-path setter (PASS)"
        ) >= 2,
        "mqtt reruns the MQTT-over-plain-TCP self-test": output.count(
            "MQTT over plain TCP: CONNECT->CONNACK, SUBSCRIBE(QoS1)->SUBACK, PUBLISH(QoS1)->PUBACK, PINGREQ->PINGRESP, DISCONNECT (PASS)"
        ) >= 2,
        "no fault": "FAULT" not in output,
    }
    ok = all(checks.values())

    if ok:
        print(f"\n[rpi4_shell_smoke.py] PASS -- all 20 real shell commands (help, "
              f"ver, echo, an unknown command, test, sha256, sha512, x25519, "
              f"ed25519, pki, netif, arp, ip, filter, tcp, udp, dhcp, dhcps, netcfg, "
              f"mqtt) got their correct real responses over a live QEMU stdio UART "
              f"session.", file=sys.stderr)
        return 0
    failed = [name for name, passed in checks.items() if not passed]
    print(f"\n[rpi4_shell_smoke.py] FAIL -- failed checks: {failed!r}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
