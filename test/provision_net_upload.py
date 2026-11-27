#!/usr/bin/env python3
"""One-time real-board provisioning for `kernelupload net`, over the UART
shell (the board must be at a root shell prompt).

Uses only public material from this machine:
  * ~/.config/dhruva/tls (test/tls_pki.py init): issues the board's TLS
    certificate for the public key the board generates itself (its private
    key never leaves the board) and authorizes this uploader's client key;
  * ~/.config/dhruva/kernel_signing_key.pem (test/kernel_sign.py keygen):
    sets the board's trusted kernel-signing public key.

Commands go out via test/realhw_probe.py "<cmd>" 0 (send-only) and replies
are read from the always-on UART logger's file -- never a second reader on
the port (see the project's UART notes).

Usage: python3 test/provision_net_upload.py [--force-kernelsig]
"""
import argparse
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.expanduser("~/dhruva_uart.log")
PKI = os.path.expanduser("~/.config/dhruva/tls")


def send_and_wait(cmd: str, pattern: str, timeout: float = 30.0) -> str:
    start = os.path.getsize(LOG)
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "realhw_probe.py"), cmd, "0"],
                   check=True, capture_output=True)
    end = time.time() + timeout
    rx = re.compile(pattern)
    text = ""
    while time.time() < end:
        with open(LOG, "rb") as f:
            f.seek(start)
            text = f.read().replace(b"\x00", b"").decode(errors="replace")
        if rx.search(text):
            return text
        time.sleep(0.5)
    raise SystemExit(f"timeout waiting for /{pattern}/ after `{cmd}`; got:\n{text[-800:]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force-kernelsig", action="store_true",
                    help="replace an already-provisioned, different kernel-signing key")
    a = ap.parse_args()
    py = [sys.executable, "-I"]
    out = send_and_wait("tlsd keygen", r"tlsd pubkey [0-9A-Fa-f]{64}", 120)
    board_pub = re.search(r"tlsd pubkey ([0-9A-Fa-f]{64})", out).group(1).lower()
    print("board TLS identity:", board_pub[:16] + "...")
    lines = subprocess.run([*py, os.path.join(HERE, "tls_pki.py"), "board", board_pub, "--dir", PKI],
                           check=True, capture_output=True, text=True).stdout.splitlines()
    # The board's UART output can drop bytes of a reply (commands arrive
    # intact -- they are echoed back whole), so per-chunk acks are only a
    # pacing hint; certend (which parses and checks the assembled
    # certificate) and `tlsd status` below are the real verification.
    for line in lines:
        if line.startswith("tlsd ") and not line.endswith("certend"):
            try:
                send_and_wait(line, r"k, ", 5)
            except SystemExit:
                pass
    send_and_wait("tlsd certend", r"certificate", 30)
    print("board certificate installed")
    client = subprocess.run([*py, os.path.join(HERE, "tls_pki.py"), "client-pubkey", "--dir", PKI],
                            check=True, capture_output=True, text=True).stdout.strip()
    send_and_wait(f"tlsd client {client}", r"authorized", 30)
    print("uploader client key authorized")
    ksig = subprocess.run([*py, os.path.join(HERE, "kernel_sign.py"), "pubkey"],
                          check=True, capture_output=True, text=True).stdout
    ksig_pub = re.search(r"([0-9a-f]{64})", ksig).group(1)
    st = send_and_wait("kernelsig status", r"kernelsig", 20)
    if re.search(r"trusted key|fingerprint", st, re.I) and ksig_pub[:16].upper() not in st.upper() and not a.force_kernelsig:
        print("board already trusts a DIFFERENT kernel-signing key:\n" + st.strip()[-300:])
        print("re-run with --force-kernelsig to replace it")
        return 1
    send_and_wait(f"kernelsig setkey {ksig_pub}", r"trusted kernel-signing key set|already", 30)
    print("kernel-signing key provisioned:", ksig_pub[:16] + "...")
    st = send_and_wait("tlsd status", r"tlsd: identity", 20)
    if "MISSING" in st.split("tlsd status")[-1]:
        print("tlsd not fully provisioned:", st.strip().splitlines()[-1])
        return 1
    print("done -- board ready for: kernelupload net")
    return 0


if __name__ == "__main__":
    sys.exit(main())
