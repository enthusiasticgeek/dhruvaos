#!/usr/bin/env python3
"""Host-side PKI for the board's TLS 1.3 server (tlsd, kernel/kernel_main.vani).

Trust model:
  * A small Ed25519 CA lives on this machine (--dir, default
    ~/.config/dhruva/tls, mode 0700; keys 0600; never in the repo).
  * The board generates its own identity key (`tlsd keygen` prints the
    public key); this tool issues the board's certificate for that public
    key -- the board's private key never leaves the board.
  * The uploader (this machine) gets a client certificate from the same CA.
    The board pins the client's Ed25519 key (`tlsd client <hex>`), so a
    certificate from this CA alone is not enough to connect.

Usage:
  python3 test/tls_pki.py init                       # CA + client key/cert (once)
  python3 test/tls_pki.py board <64-hex board pubkey> # issue board cert, print provisioning lines
  python3 test/tls_pki.py client-pubkey              # hex for `tlsd client`
"""
import argparse
import datetime
import os
import stat
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.x509.oid import NameOID

DEFAULT_DIR = os.path.expanduser("~/.config/dhruva/tls")
NOT_BEFORE = datetime.datetime(2025, 1, 1, tzinfo=datetime.timezone.utc)
NOT_AFTER = datetime.datetime(2049, 12, 31, tzinfo=datetime.timezone.utc)


def p(d, name):
    return os.path.join(d, name)


def write_private(path, key):
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(pem)


def load_private(path):
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit(f"refusing {path}: permissions {oct(st.st_mode & 0o777)} (must be 0600)")
    return serialization.load_pem_private_key(open(path, "rb").read(), password=None)


def raw_pub(k):
    return k.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def issue(subject_cn, pub, ca_key, ca_cert, is_ca=False):
    b = (x509.CertificateBuilder()
         .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)]))
         .issuer_name(ca_cert.subject if ca_cert else x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)]))
         .public_key(pub)
         .serial_number(x509.random_serial_number())
         .not_valid_before(NOT_BEFORE)
         .not_valid_after(NOT_AFTER)
         .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
         .add_extension(x509.KeyUsage(digital_signature=not is_ca, content_commitment=False, key_encipherment=False,
                                      data_encipherment=False, key_agreement=False, key_cert_sign=is_ca,
                                      crl_sign=is_ca, encipher_only=False, decipher_only=False), critical=True))
    return b.sign(ca_key, None)   # Ed25519: algorithm must be None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["init", "board", "client-pubkey"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--dir", default=DEFAULT_DIR)
    a = ap.parse_args()
    d = a.dir
    if a.cmd == "init":
        if os.path.exists(p(d, "ca_key.pem")):
            sys.exit(f"{d} already initialized")
        os.makedirs(d, mode=0o700, exist_ok=True)
        ca_key = Ed25519PrivateKey.generate()
        ca_cert = issue("dhruva-ca", ca_key.public_key(), ca_key, None, is_ca=True)
        write_private(p(d, "ca_key.pem"), ca_key)
        open(p(d, "ca_cert.pem"), "wb").write(ca_cert.public_bytes(serialization.Encoding.PEM))
        cl_key = Ed25519PrivateKey.generate()
        cl_cert = issue("dhruva-uploader", cl_key.public_key(), ca_key, ca_cert)
        write_private(p(d, "client_key.pem"), cl_key)
        open(p(d, "client_cert.pem"), "wb").write(cl_cert.public_bytes(serialization.Encoding.PEM))
        print(f"initialized {d}")
        print(f"authorize this uploader on the board (UART shell, root):\n  tlsd client {raw_pub(cl_key.public_key()).hex()}")
        return 0
    if a.cmd == "client-pubkey":
        print(raw_pub(load_private(p(d, "client_key.pem")).public_key()).hex())
        return 0
    # board
    if not a.arg or len(a.arg) != 64:
        sys.exit("give the board's 64-hex-char public key (from `tlsd keygen` / `tlsd pubkey`)")
    ca_key = load_private(p(d, "ca_key.pem"))
    ca_cert = x509.load_pem_x509_certificate(open(p(d, "ca_cert.pem"), "rb").read())
    pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(a.arg))
    cert = issue("dhruva-board", pub, ca_key, ca_cert)
    der = cert.public_bytes(serialization.Encoding.DER)
    open(p(d, "board_cert.der"), "wb").write(der)
    print(f"# board certificate: {len(der)} bytes -> {p(d, 'board_cert.der')}")
    print("tlsd certbegin")
    for i in range(0, len(der), 48):
        print(f"tlsd certchunk {der[i:i+48].hex()}")
    print("tlsd certend")
    return 0


if __name__ == "__main__":
    sys.exit(main())
