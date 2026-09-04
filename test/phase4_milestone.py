#!/usr/bin/env python3
"""Phase 4 task #11: script the full Phase 4 milestone end-to-end --
boot, write a file, read it back, list it, and evaluate a trivial
arithmetic expression -- all via the live interactive shell (task_f)
over QEMU's stdio UART, reusing qemu_run.py's own conventions (same
QEMU_BIN/MACHINE constants, same "capture everything, check markers"
style) rather than introducing a second unrelated test pattern.

Feeds commands via subprocess.Popen + timed stdin writes, then a
single communicate(timeout=...) at the end to gather all output --
deliberately NOT select()-based: this project spent a very long
session chasing what turned out to be a false alarm, caused in part by
an unreliable select()-on-Popen read loop earlier in that same session
(see project memory / commit history for task #9). A plain writes-then-
communicate() script was independently verified to capture guest output
correctly for the same duration, with no such issue.

Every check below is anchored to a strictly-increasing cursor into the
captured output (find(needle, cursor)), not a bare "does this substring
appear anywhere" search: kernel_main's own boot-time self-tests and
task_e/GC's periodic background message print several of the same
words/paths this milestone also uses (e.g. GC prints its own
"/config/mode = ..." line, unrelated to anything this script checks,
but a bare, unanchored "/config/mode" substring search elsewhere in
this project's history produced a real false positive from exactly
that message) -- anchoring each check to start searching only after
the previous one matched is what actually rules that out.
"""
import subprocess
import sys
import time

QEMU_BIN = "qemu-system-arm"
MACHINE = "raspi1ap"
SETTLE_S = 8  # inter-command delay; a 6s value missed the final "eval"
              # command once in testing (task_f and task_e/GC share one
              # best-effort priority band, so a GC pass in progress right
              # when a command arrives can push task_f's own turn out a
              # little further than usual -- ordinary scheduling
              # variance, not a functional break)


def run_milestone(elf_path: str, sd_image_path: str) -> tuple[bool, str]:
    with open(sd_image_path, "wb") as f:
        f.truncate(64 * 1024 * 1024)

    proc = subprocess.Popen(
        [
            QEMU_BIN, "-M", MACHINE, "-nographic",
            "-kernel", elf_path,
            "-drive", f"file={sd_image_path},if=sd,format=raw,cache=writethrough",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    def send(line: str) -> None:
        proc.stdin.write((line + "\r").encode())
        proc.stdin.flush()

    time.sleep(SETTLE_S)
    send("write /milestone/note hello-dhruva")
    time.sleep(SETTLE_S)
    send("cat /milestone/note")
    time.sleep(SETTLE_S)
    send("eval 6*7")
    time.sleep(SETTLE_S)
    # Round 28: round 26 shipped a real, interactively-typeable "ping"
    # command and verified it worked live -- but only via a throwaway
    # scratchpad script, never added to this project's own permanent
    # regression suite. Formalized here instead of leaving that
    # verification ephemeral. "ping 0.0.0.0" reliably hits the
    # self-ping path (round 27's own live DHCP kickoff never actually
    # binds under QEMU -- no real server exists on this project's
    # loopback-only netif -- so dhcp_state_get_leased_ip() is
    # guaranteed 0.0.0.0 for the whole life of any QEMU test run,
    # making this the one ping target this suite can reliably expect
    # a real reply from).
    send("ping 0.0.0.0")
    time.sleep(SETTLE_S)
    # Round 28's own new command -- also given permanent coverage
    # immediately, not left for a future round to formalize the way
    # ping's was. The exact state/IP text is deterministic for the
    # same "DHCP never actually binds under QEMU" reason above.
    send("ifconfig")
    time.sleep(SETTLE_S)
    # Round 29: gives the entire TCP connection API (handshake, data
    # transfer, close) a permanent live regression check too, matching
    # round 28's own "don't leave a new command's verification
    # ephemeral" discipline -- this one drives a full, self-contained
    # loopback round trip (127.0.0.1 to itself) through tcp_conn_poll's
    # real netif-queue routing, not tcp_conn_self_test's own hand-fed
    # frames, so it's a genuinely different (live) code path getting
    # covered here, not a duplicate of that self-test.
    send("tcpecho hello-tcp")
    time.sleep(SETTLE_S)
    # Round 30: closes the last major "correct, never used live" gap
    # the feature ledger flagged -- socket_udp_send/socket_udp_recv
    # (Phase 6's socket-style API) had only ever run inside
    # udp_self_test's hand-fed traffic since round 21. Same immediate-
    # formalization discipline as round 28/29's own commands.
    send("udpecho hello-udp")
    time.sleep(SETTLE_S)
    # Round 31: "netstat" is read-only (sends no traffic of its own),
    # so it's placed after tcpecho/udpecho specifically to observe
    # their real, already-live side effects (the ARP cache entry
    # udpecho inserts for loopback self-talk, and both TCP connection
    # slots' post-close state) rather than exercising anything new
    # itself -- same "don't leave a new command's verification
    # ephemeral" discipline as every prior round's own new command.
    send("netstat")
    time.sleep(SETTLE_S)
    # Round 37: proves TCP retransmission recovers a REAL simulated
    # packet loss (not just a hand-fed-frame self-test) -- sends a SYN,
    # deliberately drops it, sleeps out the real ~2-second RTO, then
    # confirms the handshake still completes via a retransmit. Placed
    # AFTER netstat deliberately: it reuses the same two connection
    # slots tcpecho/netstat's own checks above already exercised, and
    # (unlike tcpecho) never closes them -- leaving conn 0/1 in
    # ESTABLISHED would break netstat's own CLOSED_FINAL assertion if
    # this ran first. Needs extra settle time on top of the standard
    # SETTLE_S: the command's own internal sleep (tcp_rtx_timeout_ticks
    # + 1 = 5 ticks = ~2.5s) plus handshake polling has to fit inside
    # the window before the next command is sent.
    send("tcprtx")
    time.sleep(SETTLE_S + 4)
    # Round 67: tlsecho gives the reusable tls_connect/tls_accept/
    # tls_send/tls_recv API (kernel_main.vani, TLS 1.3 handshake +
    # record layer built earlier this round) the same "don't leave a
    # new command's verification ephemeral" treatment as every prior
    # round's own new command. Placed AFTER tcprtx deliberately: it
    # reuses the same connection slots 0/1 tcprtx just left in
    # whatever state its own retransmission recovery left them in
    # (nothing after tcprtx checks that), and tlsecho's own
    # tcp_conn_active_open/passive_open calls reset that state fresh
    # regardless -- same reasoning tcprtx's own comment gives for why
    # IT runs after netstat.
    send("tlsecho hello-tls")
    time.sleep(SETTLE_S)
    # "ls" last, deliberately: every other command in this sequence has
    # a LATER command's own settle time to absorb any scheduling slack,
    # but the last command has only the trailing sleep below to work
    # with -- "ls" was the most consistently reliable of the four
    # across repeated testing, so it gets that spot, and still gets
    # extra margin on top of the standard settle time regardless.
    send("ls")
    time.sleep(SETTLE_S + 4)

    proc.terminate()
    try:
        out, _ = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    output = out.decode("utf-8", "replace")

    steps = [
        ("boot reaches PASS", "PASS"),
        ("write /milestone/note ok", "ok"),
        ("cat /milestone/note == hello-dhruva", "hello-dhruva"),
        ("eval 6*7 == 42", "\n42\n"),
        ("ping 0.0.0.0 replies (self-ping over loopback)", "reply from 0.0.0.0"),
        ("ifconfig shows mac", "mac 02:00:00:00:00:01"),
        ("ifconfig shows dhcp state", "dhcp state=SELECTING ip=0.0.0.0"),
        ("tcpecho completes a live handshake+data+close round trip", 'tcpecho: echoed "hello-tcp"'),
        ("udpecho completes a live socket_udp_send/recv round trip", 'udpecho: echoed "hello-udp"'),
        ("netstat shows the ARP entry udpecho inserted", "127.0.0.1 -> 02:00:00:00:00:01"),
        ("netstat shows tcpecho's client connection closed", "conn 0 state=CLOSED_FINAL local=127.0.0.1:54322 remote=127.0.0.1:7777"),
        ("tcprtx recovers a real simulated SYN loss via retransmission", "recovered from simulated SYN loss via retransmission"),
        ("tlsecho completes a live tls_connect/tls_accept handshake + encrypted echo", 'tlsecho: echoed over real TLS 1.3 "hello-tls"'),
        ("ls shows /milestone/note", "  /milestone/note"),
    ]

    cursor = 0
    all_ok = True
    for name, needle in steps:
        idx = output.find(needle, cursor)
        if idx == -1:
            print(f"[FAIL] {name}")
            all_ok = False
        else:
            print(f"[PASS] {name}")
            cursor = idx + len(needle)

    boot_banners = output.count("Dhruva Phase 2")
    if boot_banners == 1:
        print(f"[PASS] no reboot/crash (1 boot banner)")
    else:
        print(f"[FAIL] no reboot/crash ({boot_banners} boot banners, expected 1)")
        all_ok = False

    return all_ok, output


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-dhruva.elf>", file=sys.stderr)
        return 2

    elf_path = sys.argv[1]
    ok, output = run_milestone(elf_path, "/tmp/dhruva_phase4_milestone.img")

    with open("/tmp/phase4_milestone_full_log.txt", "w") as f:
        f.write(output)
    print("Full log: /tmp/phase4_milestone_full_log.txt", file=sys.stderr)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
