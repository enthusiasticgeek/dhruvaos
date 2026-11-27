#!/usr/bin/env python3
"""Upload a signed kernel image to a DhruvaOS board over the network.

The board side is `kernelupload net [port]` (kernel/kernel_main.vani):
it accepts one TLS 1.3 connection on its tlsd server, which offers
X25519MLKEM768 key exchange only, CHACHA20_POLY1305 and mutual Ed25519
authentication against the pinned uploader key. It streams the image
into the INACTIVE A/B slot, requires a valid Ed25519 signature from the
provisioned kernelsig key, then re-reads the slot from SD and re-hashes
it before marking it ready.

Wire format (inside TLS):
    b"DKU1" | len u32 LE | flags u32 LE | sha256(image) | ed25519 sig (64)
    then the image bytes; the board replies with one "OK ..." / "FAIL ..." line.

Prerequisites (one-time, see test/tls_pki.py and test/kernel_sign.py):
    tls_pki.py init / board ...  -> ~/.config/dhruva/tls/{ca_cert,client_cert,client_key}.pem
    kernel_sign.py keygen        -> ~/.config/dhruva/kernel_signing_key.pem
    board: tlsd keygen + certbegin/certchunk/certend, tlsd client <hex>, kernelsig setkey <hex>

Usage:
    # on the board's UART shell (root):   kernelupload net
    python3 test/kernel_upload_net.py 192.168.1.239 build/dhruva_real_hw.img [--activate]
"""
import argparse
import hashlib
import os
import socket
import ssl
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kernel_sign  # noqa: E402  (same signing key + message format as the UART path)

DEFAULT_PKI = os.path.expanduser("~/.config/dhruva/tls")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("image")
    ap.add_argument("--port", type=int, default=4433)
    ap.add_argument("--pki", default=DEFAULT_PKI)
    ap.add_argument("--key", default=kernel_sign.DEFAULT_KEY, help="kernel signing key")
    ap.add_argument("--activate", action="store_true", help="activate the new slot after a verified commit")
    ap.add_argument("--timeout", type=float, default=900.0)
    a = ap.parse_args()

    image = open(a.image, "rb").read()
    digest = hashlib.sha256(image).digest()
    sig = kernel_sign.load_key(a.key).sign(kernel_sign.signed_message(image))
    header = b"DKU1" + struct.pack("<II", len(image), 1 if a.activate else 0) + digest + sig
    assert len(header) == 108

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.check_hostname = False          # the board's identity is its CA-issued certificate
    ctx.load_verify_locations(os.path.join(a.pki, "ca_cert.pem"))
    ctx.load_cert_chain(os.path.join(a.pki, "client_cert.pem"), os.path.join(a.pki, "client_key.pem"))
    try:
        ctx.set_groups(["X25519MLKEM768"])  # Python >= 3.13 / OpenSSL >= 3.5
    except (AttributeError, ssl.SSLError):
        pass                                # the board refuses anything else anyway

    print(f"image {a.image}: {len(image)} bytes sha256={digest.hex()}")
    t0 = time.time()
    raw = socket.create_connection((a.host, a.port), timeout=a.timeout)
    s = ctx.wrap_socket(raw)
    print(f"TLS up in {time.time() - t0:.1f}s: {s.version()} {s.cipher()[0]}")
    t1 = time.time()
    s.sendall(header)
    step = 64 * 1024
    for off in range(0, len(image), step):
        s.sendall(image[off:off + step])
        done = min(off + step, len(image))
        el = time.time() - t1
        print(f"\r  sent {done}/{len(image)} bytes  {done / el / 1024 if el > 0 else 0:.1f} KiB/s", end="", flush=True)
    print()
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = s.recv(256)
        if not chunk:
            break
        reply += chunk
    el = time.time() - t1
    try:
        s.close()
    except OSError:
        pass
    line = reply.decode(errors="replace").strip()
    print(f"board: {line or '(no reply)'}  -- {len(image) / el / 1024:.1f} KiB/s end to end ({el:.1f}s)")
    return 0 if line.startswith("OK") else 1


if __name__ == "__main__":
    sys.exit(main())
