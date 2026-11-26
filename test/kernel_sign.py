#!/usr/bin/env python3
"""Ed25519 signing for DhruvaOS kernel images (see kernelsig_* in
kernel/kernel_main.vani).

The board only marks an uploaded slot ready if it carries a valid
signature, by the provisioned trusted key, over

    M = b"DHRUVA-KSIG-v1\\0\\0" || len(image) as u32 LE || SHA-256(image)

The private key never leaves this machine and never goes in the repo:
it lives at ~/.config/dhruva/kernel_signing_key.pem (mode 0600) unless
--key says otherwise.

Usage:
  python3 test/kernel_sign.py keygen            # once; prints the setkey line
  python3 test/kernel_sign.py pubkey            # print the public key hex again
  python3 test/kernel_sign.py sign build/dhruva_real_hw.img   # -> <img>.sig (64 raw bytes)
  python3 test/kernel_sign.py verify build/dhruva_real_hw.img # local check of <img>.sig

Provision the board once, from its UART shell as root:
  kernelsig setkey <64-hex pubkey printed by keygen/pubkey>
"""
import argparse
import hashlib
import os
import stat
import struct
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

DEFAULT_KEY = os.path.expanduser("~/.config/dhruva/kernel_signing_key.pem")
TAG = b"DHRUVA-KSIG-v1\x00\x00"
assert len(TAG) == 16


def signed_message(image: bytes) -> bytes:
    return TAG + struct.pack("<I", len(image)) + hashlib.sha256(image).digest()


def load_key(path: str) -> Ed25519PrivateKey:
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit(f"refusing to use {path}: permissions {oct(st.st_mode & 0o777)} -- must be 0600")
    with open(path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        sys.exit(f"{path} is not an Ed25519 private key")
    return key


def pub_hex(key: Ed25519PrivateKey) -> str:
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["keygen", "pubkey", "sign", "verify"])
    ap.add_argument("image", nargs="?")
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--force", action="store_true", help="keygen: overwrite an existing key")
    a = ap.parse_args()

    if a.cmd == "keygen":
        if os.path.exists(a.key) and not a.force:
            sys.exit(f"{a.key} already exists (use --force to replace -- the board's trusted key must then be re-set)")
        os.makedirs(os.path.dirname(a.key), mode=0o700, exist_ok=True)
        key = Ed25519PrivateKey.generate()
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        fd = os.open(a.key, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(pem)
        print(f"wrote {a.key} (0600)")
        print(f"provision the board (UART shell, as root):\n  kernelsig setkey {pub_hex(key)}")
        return 0

    key = load_key(a.key)
    if a.cmd == "pubkey":
        print(pub_hex(key))
        return 0

    if not a.image:
        sys.exit("an image path is required")
    image = open(a.image, "rb").read()
    msg = signed_message(image)
    sig_path = a.image + ".sig"
    if a.cmd == "sign":
        sig = key.sign(msg)
        with open(sig_path, "wb") as f:
            f.write(sig)
        print(f"signed {a.image} ({len(image)} bytes, sha256={hashlib.sha256(image).hexdigest()}) -> {sig_path}")
        return 0

    sig = open(sig_path, "rb").read()
    try:
        key.public_key().verify(sig, msg)
    except InvalidSignature:
        print(f"[FAIL] {sig_path} does not verify for {a.image}")
        return 1
    print(f"[ok] {sig_path} verifies for {a.image} under key {pub_hex(key)[:16]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
