"""tlsd interop: provision a QEMU guest, run `tlsd serve`, connect with
Python ssl (OpenSSL 3.5) using a throwaway CA + client cert."""
import os, re, select, shutil, socket, ssl, subprocess, sys, time
SCR = os.environ.get("DHRUVA_TEST_TMP", "/tmp/dhruva_qemu_test"); os.makedirs(SCR, exist_ok=True)
REPO = "/home/virgo/source/dhruvaos"
sys.path.insert(0, f"{REPO}/test")
import phase4_milestone as p4

elf = sys.argv[1]
pki = os.path.join(SCR, "tlsd_pki")
shutil.rmtree(pki, ignore_errors=True)
subprocess.run([sys.executable, "-I", f"{REPO}/test/tls_pki.py", "init", "--dir", pki], check=True, capture_output=True)
client_pub = subprocess.run([sys.executable, "-I", f"{REPO}/test/tls_pki.py", "client-pubkey", "--dir", pki],
                            check=True, capture_output=True, text=True).stdout.strip()
img = os.path.join(SCR, "qtls.img")
with open(img, "wb") as f:
    f.truncate(64 * 1024 * 1024)
port = 4433
q = subprocess.Popen([p4.QEMU_BIN, "-M", p4.MACHINE, "-nographic", "-kernel", elf,
                      "-drive", f"file={img},if=sd,format=raw,cache=writethrough",
                      "-device", "usb-net,netdev=n0",
                      "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:{port}"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
buf = p4._wait_for_boot_ready(q, p4.BOOT_READY_TIMEOUT_S)
buf = p4._wait_for_recovery_complete(q, buf, p4.BOOT_READY_TIMEOUT_S)
mark = [len(buf)]

def pump(sec, until=None):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([q.stdout], [], [], 0.3)
        if r:
            ch = q.stdout.read1(4096)
            if not ch:
                break
            buf += ch
            if until and until in buf[mark[0]:]:
                return True
    return False

def cmd(line, until, sec=30):
    mark[0] = len(buf)
    q.stdin.write((line + "\r").encode()); q.stdin.flush()
    ok = pump(sec, until)
    if not ok:
        print("TIMEOUT waiting for", until, "after", line)
    return buf[mark[0]:].decode(errors="replace")

pump(120, b"background device0 probe complete")
for _ in range(10):
    if "BOUND" in cmd("ifconfig", b"BOUND", 15):
        break
out = cmd("tlsd keygen", b"tlsd pubkey ", 60)
pump(3)
out = buf[mark[0]:].decode(errors="replace")
m = re.search(r"tlsd pubkey ([0-9A-Fa-f]{64})", out)
if not m:
    print("keygen failed:", out[-500:]); q.kill(); sys.exit(1)
board_pub = m.group(1).lower()
prov = subprocess.run([sys.executable, "-I", f"{REPO}/test/tls_pki.py", "board", board_pub, "--dir", pki],
                      check=True, capture_output=True, text=True).stdout.splitlines()
for line in prov:
    if line.startswith("tlsd "):
        cmd(line, b"ok, " if not line.endswith("certend") else b"certificate", 30)
print(cmd(f"tlsd client {client_pub}", b"ok, authorized", 30).strip().splitlines()[-1])
print(cmd("tlsd status", b"authorized client", 30).strip().splitlines()[-1])
mark[0] = len(buf)
q.stdin.write(b"tlsd serve 4433\r"); q.stdin.flush()
pump(5, b"tlsd: listening")

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.check_hostname = False
ctx.load_verify_locations(os.path.join(pki, "ca_cert.pem"))
ctx.load_cert_chain(os.path.join(pki, "client_cert.pem"), os.path.join(pki, "client_key.pem"))
result = "FAIL"
try:
    raw = socket.create_connection(("127.0.0.1", port), timeout=120)
    t0 = time.time()
    s = ctx.wrap_socket(raw)
    print("handshake OK in %.1fs:" % (time.time() - t0), s.version(), s.cipher())
    payload = os.urandom(3000)
    s.sendall(payload)
    got = b""
    while len(got) < len(payload):
        chunk = s.recv(65536)
        if not chunk:
            break
        got += chunk
    print("echo", "matches" if got == payload else f"MISMATCH ({len(got)} bytes)")
    if got == payload and s.version() == "TLSv1.3" and "CHACHA20" in s.cipher()[0]:
        result = "PASS"
    s.close()
except Exception as e:
    print("client error:", type(e).__name__, e)
pump(10, b"tlsd: echoed")

# ---- negative cases: each must be REFUSED by the board ----
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from cryptography import x509
import importlib.util
spec = importlib.util.spec_from_file_location("tls_pki", f"{REPO}/test/tls_pki.py"); tp = importlib.util.module_from_spec(spec); spec.loader.exec_module(tp)
ca_key = tp.load_private(os.path.join(pki, "ca_key.pem"))
ca_cert = x509.load_pem_x509_certificate(open(os.path.join(pki, "ca_cert.pem"), "rb").read())
rogue = Ed25519PrivateKey.generate()
rc = tp.issue("rogue", rogue.public_key(), ca_key, ca_cert)
tp.write_private(os.path.join(pki, "rogue_key.pem"), rogue)
open(os.path.join(pki, "rogue_cert.pem"), "wb").write(rc.public_bytes(serialization.Encoding.PEM))

def serve_and(fn, expect_board):
    mark[0] = len(buf)
    q.stdin.write(b"tlsd serve 4433\r"); q.stdin.flush()
    pump(5, b"tlsd: listening")
    client_ok = fn()
    pump(25, expect_board.encode())
    board = buf[mark[0]:].decode(errors="replace")
    return client_ok, (expect_board in board), board

def py_client(cert, key):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3
    c.check_hostname = False; c.load_verify_locations(os.path.join(pki, "ca_cert.pem"))
    if cert: c.load_cert_chain(cert, key)
    try:
        s = c.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=60))
        s.sendall(b"x"); r = s.recv(10); s.close()
        return r == b"x"
    except Exception as e:
        return False

neg = []
ok_c, ok_b, bd = serve_and(lambda: py_client(None, None), "client sent no certificate")
neg.append(("no client certificate refused", (not ok_c) and ok_b, bd))
ok_c, ok_b, bd = serve_and(lambda: py_client(os.path.join(pki, "rogue_cert.pem"), os.path.join(pki, "rogue_key.pem")), "NOT the authorized one")
neg.append(("same-CA but unauthorized client key refused", (not ok_c) and ok_b, bd))
def classical():
  try:
    r = subprocess.run(["openssl", "s_client", "-connect", f"127.0.0.1:{port}", "-tls1_3", "-groups", "X25519",
                        "-CAfile", os.path.join(pki, "ca_cert.pem"), "-cert", os.path.join(pki, "client_cert.pem"),
                        "-key", os.path.join(pki, "client_key.pem")], input=b"x\n", capture_output=True, timeout=60) if True else None
    return b"Verification: OK" in r.stdout and b"New, TLSv1.3" in r.stdout
  except subprocess.TimeoutExpired:
    return False
ok_c, ok_b, bd = serve_and(classical, "no X25519MLKEM768 key share")
neg.append(("classical-only (X25519) client refused", (not ok_c) and ok_b, bd))
for name, good, bd in neg:
    print(("[PASS] " if good else "[FAIL] ") + name)
    if not good:
        print("   board:", [l for l in bd.splitlines() if l.startswith("tlsd")][-3:])
if not all(g for _, g, _ in neg):
    result = "FAIL"
q.kill()
print("--- board tlsd lines ---")
for l in buf.decode(errors="replace").splitlines():
    if l.startswith("tlsd"):
        print(l[:200])
print(result)
sys.exit(0 if result == "PASS" else 1)
