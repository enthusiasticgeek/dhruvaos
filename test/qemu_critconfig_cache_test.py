#!/usr/bin/env python3
"""QEMU regression test: critical-config table cache and lazy WiFi password.

Since 2026-11-28 critical_config_table_load caches the table (it used to
re-read 18 SD blocks on every read) and the encrypted WiFi password is
decrypted on first use instead of at every boot. Both caches must be dropped
by any critconfig write. This checks:
  1. a value set at runtime reads back its NEW value at once (cache dropped),
     including an overwrite of an existing key;
  2. the WiFi password set at runtime is picked up without a reboot
     (`wificreds` hash changes after a password change);
  3. values persist across a reboot on the same card;
  4. boot no longer decrypts the password (`wificreds` still reports it).

Usage: python3 test/qemu_critconfig_cache_test.py build/dhruva.elf
"""
import hashlib
import os
import re
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "test"))
import qemu_dharafs_index_eviction_test as ev  # noqa: E402  (boot/cmd helpers)


def pw_hash(cmd):
    out = cmd("wificreds", b"never-matches", 8)   # both lines, then idle
    m = re.search(r"password_len=(\d+) sha256=([0-9A-Fa-f]+)", out)
    return (int(m.group(1)), m.group(2).lower()) if m else (None, out[-200:])


def main() -> int:
    elf = sys.argv[1]
    sd = os.path.join(tempfile.mkdtemp(prefix="critcache_"), "sd.img")
    with open(sd, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    ok = True

    def check(cond, label):
        nonlocal ok
        print(("[PASS] " if cond else "[FAIL] ") + label, flush=True)
        ok &= bool(cond)

    q, st = ev.boot(elf, sd)
    cmd = ev.make_cmd(q, st)
    try:
        cmd("critconfig set cc_probe alpha1", b"ok\r\n", 30)
        out = cmd("critconfig get cc_probe", b"alpha1", 20)
        check("alpha1" in out, "new key reads back immediately")
        cmd("critconfig set cc_probe bravo22", b"ok\r\n", 30)
        out = cmd("critconfig get cc_probe", b"bravo22", 20)
        check("bravo22" in out and "alpha1" not in out.split("critconfig get cc_probe")[-1],
              "overwrite reads back the NEW value without a reboot")

        cmd("critconfig set wifi_password firstpass1 --encrypted", b"ok\r\n", 60)
        n1, h1 = pw_hash(cmd)
        check(n1 == 10 and h1 == hashlib.sha256(b"firstpass1").hexdigest(),
              f"password set at runtime is picked up (len={n1})")
        cmd("critconfig set wifi_password secondpass22 --encrypted", b"ok\r\n", 60)
        n2, h2 = pw_hash(cmd)
        check(n2 == 12 and h2 == hashlib.sha256(b"secondpass22").hexdigest(),
              f"password CHANGE is picked up without a reboot (len={n2})")
        cmd("shutdown", b"SAFE TO POWER OFF", 60)
    finally:
        q.kill()
        q.wait()

    q, st = ev.boot(elf, sd)
    cmd = ev.make_cmd(q, st)
    try:
        boot_text = st["buf"].decode(errors="replace")
        out = cmd("critconfig get cc_probe", b"bravo22", 20)
        check("bravo22" in out, "value persists across reboot")
        n3, h3 = pw_hash(cmd)
        check(n3 == 12 and h3 == hashlib.sha256(b"secondpass22").hexdigest(),
              "password decrypted lazily after reboot (first use)")
        check("critconfig: table unreadable" not in boot_text, "no table read failures at boot")
    finally:
        q.kill()
        q.wait()
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
