#!/usr/bin/env python3
"""QEMU end-to-end test for `kernelupload net` + test/kernel_upload_net.py.

Seeds an SD image, boots the guest with usb-net (hostfwd tcp 4433),
provisions throwaway TLS (tls_pki.py) and kernel-signing keys
(kernel_sign.py) in a temp dir, then:
  1. uploads a random image signed by the trusted key, with --activate
     -> board replies OK and `kernelslot status` shows the new slot ready
        and preferred
  2. uploads an image signed by a different key -> board replies FAIL
     (signature) and nothing new is committed
  3. sends a header whose length disagrees with the data -> refused

Usage: python3 test/qemu_kernel_upload_net_test.py build/dhruva.elf
"""
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "test"))
import phase4_milestone as p4  # noqa: E402

PORT = 4433


def main() -> int:
    elf = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="kunet_")
    pki = os.path.join(tmp, "tls")
    key = os.path.join(tmp, "ksig.pem")
    rogue = os.path.join(tmp, "rogue.pem")
    py = [sys.executable, "-I"]
    run = lambda *a: subprocess.run(list(a), check=True, capture_output=True, text=True).stdout
    run(*py, f"{REPO}/test/tls_pki.py", "init", "--dir", pki)
    client_pub = run(*py, f"{REPO}/test/tls_pki.py", "client-pubkey", "--dir", pki).strip()
    ksig_pub = re.search(r"([0-9a-f]{64})", run(*py, f"{REPO}/test/kernel_sign.py", "keygen", "--key", key)).group(1)
    run(*py, f"{REPO}/test/kernel_sign.py", "keygen", "--key", rogue)

    sd = os.path.join(tmp, "sd.img")
    with open(sd, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    seed = os.path.join(tmp, "seed.img")
    open(seed, "wb").write(os.urandom(4096))
    run(*py, f"{REPO}/test/kernel_slot_layout.py", sd, "seed", seed, "--slot", "a")

    q = subprocess.Popen([p4.QEMU_BIN, "-M", p4.MACHINE, "-nographic", "-kernel", elf,
                          "-drive", f"file={sd},if=sd,format=raw,cache=writethrough",
                          "-device", "usb-net,netdev=n0",
                          "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{PORT}-:{PORT}"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = p4._wait_for_boot_ready(q, p4.BOOT_READY_TIMEOUT_S)
    buf = p4._wait_for_recovery_complete(q, buf, p4.BOOT_READY_TIMEOUT_S)
    state = {"buf": buf}

    def pump(sec, until=None, since=0):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([q.stdout], [], [], 0.3)
            if r:
                ch = q.stdout.read1(4096)
                if not ch:
                    return False
                state["buf"] += ch
                if until and until in state["buf"][since:]:
                    return True
        return False

    def cmd(line, until, sec=30):
        mark = len(state["buf"])
        q.stdin.write((line + "\r").encode())
        q.stdin.flush()
        if not pump(sec, until, mark):
            print("TIMEOUT waiting for", until, "after", line)
        return state["buf"][mark:].decode(errors="replace")

    results = []
    try:
        pump(120, b"background device0 probe complete")
        for _ in range(10):
            if "BOUND" in cmd("ifconfig", b"BOUND", 15):
                break
        out = cmd("tlsd keygen", b"tlsd pubkey ", 60)
        pump(3)
        board_pub = re.search(r"tlsd pubkey ([0-9A-Fa-f]{64})", state["buf"].decode(errors="replace")).group(1).lower()
        for line in run(*py, f"{REPO}/test/tls_pki.py", "board", board_pub, "--dir", pki).splitlines():
            if line.startswith("tlsd "):
                cmd(line, b"ok, " if not line.endswith("certend") else b"certificate", 30)
        cmd(f"tlsd client {client_pub}", b"ok, authorized", 30)
        out = cmd(f"kernelsig setkey {ksig_pub}", b"trusted kernel-signing key set", 30)

        def upload(image_path, signing_key, extra=()):
            mark = len(state["buf"])
            q.stdin.write(b"kernelupload net\r")
            q.stdin.flush()
            pump(10, b"waiting for the uploader", mark)
            r = subprocess.run([*py, f"{REPO}/test/kernel_upload_net.py", "127.0.0.1", image_path,
                                "--pki", pki, "--key", signing_key, *extra],
                               capture_output=True, text=True, timeout=600)
            pump(15, b"tlsd:", mark)
            pump(3)
            return r.returncode, r.stdout + r.stderr, state["buf"][mark:].decode(errors="replace")

        img = os.path.join(tmp, "new.img")
        open(img, "wb").write(os.urandom(300 * 1024 + 123))   # not block-aligned on purpose
        rc, host, board = upload(img, key, ("--activate",))
        print(host.strip().splitlines()[-1] if host.strip() else "(no host output)")
        for l in board.splitlines():
            if l.startswith("kernelupload") or l.startswith("kernelsig") or "commit" in l:
                print("  board:", l[:200])
        st = cmd("kernelslot status", b"slot_b", 10)
        ok1 = rc == 0 and "OK slot=b activated" in host and "preferred_slot=B" in st
        results.append(("signed upload committed + activated", ok1, host + st))

        img2 = os.path.join(tmp, "evil.img")
        open(img2, "wb").write(os.urandom(64 * 1024))
        rc, host, board = upload(img2, rogue)
        results.append(("image signed by an untrusted key refused", rc != 0 and "FAIL signature" in host, host + board))

        # header claims more bytes than are sent: the board must not commit
        # (connection ends inside the image)
        trunc = os.path.join(tmp, "trunc.img")
        data = os.urandom(32 * 1024)
        open(trunc, "wb").write(data)
        import hashlib, struct, socket, ssl
        sys.path.insert(0, os.path.join(REPO, "test"))
        import kernel_sign
        mark = len(state["buf"])
        q.stdin.write(b"kernelupload net\r")
        q.stdin.flush()
        pump(10, b"waiting for the uploader", mark)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.check_hostname = False
        ctx.load_verify_locations(os.path.join(pki, "ca_cert.pem"))
        ctx.load_cert_chain(os.path.join(pki, "client_cert.pem"), os.path.join(pki, "client_key.pem"))
        s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", PORT), timeout=120))
        sig = kernel_sign.load_key(key).sign(kernel_sign.signed_message(data + b"x" * 1000))
        s.sendall(b"DKU1" + struct.pack("<II", len(data) + 1000, 0) + hashlib.sha256(data + b"x" * 1000).digest() + sig)
        s.sendall(data)
        s.close()
        pump(45, b"connection ended after", mark)
        board = state["buf"][mark:].decode(errors="replace")
        results.append(("short stream (len mismatch) not committed", "connection ended after" in board and "OK slot" not in board, board))
    finally:
        q.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    for name, good, detail in results:
        print(("[PASS] " if good else "[FAIL] ") + name)
        if not good:
            print("   ", "\n    ".join(detail.strip().splitlines()[-12:]))
    ok = len(results) == 3 and all(g for _, g, _ in results)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
