"""Real-peer TCP receive test: Linux TCP on this host -> QEMU guest tcpsink."""
import hashlib, os, select, socket, subprocess, sys, time
SCR = os.environ.get("DHRUVA_TEST_TMP", "/tmp/dhruva_qemu_test"); os.makedirs(SCR, exist_ok=True)
sys.path.insert(0, "/home/virgo/source/dhruvaos/test")
import phase4_milestone as p4

elf = sys.argv[1]
nbytes = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
img = os.path.join(SCR, "qsink.img")
with open(img, "wb") as f:
    f.truncate(64 * 1024 * 1024)
port = 5555
q = subprocess.Popen([p4.QEMU_BIN, "-M", p4.MACHINE, "-nographic", "-kernel", elf,
                      "-drive", f"file={img},if=sd,format=raw,cache=writethrough",
                      "-device", "usb-net,netdev=n0",
                      "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:{port}"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
buf = p4._wait_for_boot_ready(q, p4.BOOT_READY_TIMEOUT_S)
buf = p4._wait_for_recovery_complete(q, buf, p4.BOOT_READY_TIMEOUT_S)

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
            if until and until in buf:
                return True
    return until is None

def send(line):
    q.stdin.write((line + "\r").encode()); q.stdin.flush()

pump(120, b"background device0 probe complete")
pump(5)
for _ in range(10):
    send("ifconfig")
    if pump(15, b"BOUND"):
        break
print("guest BOUND:", b"BOUND" in buf)
send(f"tcpsink {port}")
pump(3, b"tcpsink: listening")
data = os.urandom(nbytes)
t0 = time.time()
s = socket.create_connection(("127.0.0.1", port), timeout=30)
s.sendall(data)
s.shutdown(socket.SHUT_WR)
try:
    s.recv(1)
except Exception:
    pass
s.close()
host_s = time.time() - t0
ok = pump(120, b"tcpsink: received")
pump(2)
q.kill()
out = buf.decode(errors="replace")
line = [l for l in out.splitlines() if l.startswith("tcpsink: received")]
print("host sent", nbytes, "bytes in %.1fs" % host_s, "sha256", hashlib.sha256(data).hexdigest())
print(line[-1] if line else "NO tcpsink result\n" + out[-1500:])
good = bool(line) and (f"received {nbytes} bytes sha256={hashlib.sha256(data).hexdigest()}".lower() in line[-1].lower())
print("PASS" if good else "FAIL")
sys.exit(0 if good else 1)
