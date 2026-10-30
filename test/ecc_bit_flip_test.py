#!/usr/bin/env python3
"""DharaFS NAND-FTL ECC: prove the BCH(GF(2^13), t=8) layer wired into
sdhost_read_block/sdhost_write_block actually detects-and-corrects real
injected bit-flips, and correctly reports (never silently miscorrects)
once the error count exceeds t -- the same file-offset byte-editing-
between-reboots technique test/power_yank.py already uses for torn-
write recovery, adapted here to flip specific bits instead of zeroing a
tail, and reused via importlib rather than duplicated (same convention
already established this project for custom QEMU-driving scripts).

Methodology:

  1. Boot once against a fresh image, write a record with a distinctive
     payload, then send `reboot` (which flushes the ECC cache -- see
     kernel_main.vani's dharafs_ecc_cache_flush() call site inside the
     `reboot` shell command) before the process is killed, so the
     written block's BCH parity is actually durable in the saved image,
     not just sitting in the RAM cache. Locate which physical block the
     payload landed on by searching the raw image bytes directly.
  2. For error counts 1..8 (t): flip that many distinct bits inside the
     target block in a fresh copy of the reference image, boot once
     against the doctored copy, and check the live UART output for
     "DharaFS ECC: corrected N bit(s) in block <blk>" during the normal
     boot-time recovery scan (which reads every block, so no
     interactive command is needed to trigger the check).
  3. For t+1=9 errors: same thing, but expect "DharaFS ECC:
     UNCORRECTABLE error in block <blk>" instead -- detected, never a
     false "corrected" claim.
"""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_THIS_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("phase4_milestone", _THIS_DIR / "phase4_milestone.py")
phase4_milestone = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(phase4_milestone)

QEMU_BIN = phase4_milestone.QEMU_BIN
MACHINE = phase4_milestone.MACHINE
_wait_for_boot_ready = phase4_milestone._wait_for_boot_ready
BOOT_READY_TIMEOUT_S = phase4_milestone.BOOT_READY_TIMEOUT_S

BLOCK_SIZE = 512
BLOCK_BITS = BLOCK_SIZE * 8
WRITE_PATH = "/ecc/target"
WRITE_PAYLOAD = "ecc-bitflip-test-payload"
BOOT_TIMEOUT_S = 25


def run_qemu_capture(elf_path: str, image_path: str, timeout_s: float = BOOT_TIMEOUT_S) -> str:
    cmd = [
        "timeout", "--kill-after=5", str(timeout_s),
        QEMU_BIN, "-M", MACHINE, "-nographic",
        "-kernel", elf_path,
        "-drive", f"file={image_path},if=sd,format=raw,cache=writethrough",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 15)
    return proc.stdout + proc.stderr


def build_reference_image(elf_path: str, size_mb: int, work_dir: Path) -> Path:
    ref_path = work_dir / "reference.img"
    subprocess.run(
        ["dd", "if=/dev/zero", f"of={ref_path}", "bs=1M", f"count={size_mb}"],
        check=True, capture_output=True,
    )
    proc = subprocess.Popen(
        [
            QEMU_BIN, "-M", MACHINE, "-nographic",
            "-kernel", elf_path,
            "-drive", f"file={ref_path},if=sd,format=raw,cache=writethrough",
        ],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )

    def send(line: str) -> None:
        proc.stdin.write((line + "\r").encode())
        proc.stdin.flush()

    try:
        _wait_for_boot_ready(proc, BOOT_READY_TIMEOUT_S)
        send(f"write {WRITE_PATH} {WRITE_PAYLOAD}")
        time.sleep(14)
        # Flushes the ECC cache (dharafs_ecc_cache_flush, called from
        # this exact command) before the reset -- without this, the
        # just-written block's BCH parity never makes it into the
        # saved image, only the RAM cache this about-to-be-killed
        # process is about to lose.
        send("reboot")
        time.sleep(20)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return ref_path


def find_target_block(ref_path: Path) -> int:
    data = ref_path.read_bytes()
    idx = data.find(WRITE_PAYLOAD.encode())
    if idx < 0:
        print(f"[ecc_bit_flip_test.py] Could not find payload {WRITE_PAYLOAD!r} in "
              "reference image -- the write+reboot sequence didn't land as expected.",
              file=sys.stderr)
        sys.exit(2)
    return idx // BLOCK_SIZE


def distinct_bit_positions(n: int, spread_offset: int) -> list[int]:
    step = BLOCK_BITS // n
    return [(i * step + spread_offset) % BLOCK_BITS for i in range(n)]


def flip_bits(data: bytearray, block_num: int, bit_positions: list[int]) -> None:
    base = block_num * BLOCK_SIZE
    for bitpos in bit_positions:
        byte_idx = base + (bitpos // 8)
        bit_in_byte = bitpos % 8
        data[byte_idx] ^= (1 << bit_in_byte)


def run_one_case(elf_path: str, ref_bytes: bytes, block_num: int, n: int, work_dir: Path) -> str:
    doctored = bytearray(ref_bytes)
    flip_bits(doctored, block_num, distinct_bit_positions(n, spread_offset=17))
    img_path = work_dir / f"ecc_{n}errs.img"
    img_path.write_bytes(bytes(doctored))
    try:
        return run_qemu_capture(elf_path, str(img_path))
    finally:
        img_path.unlink()


def hex32(n: int) -> str:
    return f"{n:08X}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: test/ecc_bit_flip_test.py <path-to-dhruva.elf>", file=sys.stderr)
        return 1
    elf_path = sys.argv[1]

    work_dir = Path(tempfile.mkdtemp(prefix="dhruva_ecc_bitflip_"))
    try:
        print(f"[ecc_bit_flip_test.py] Building reference image in {work_dir} ...", file=sys.stderr)
        ref_path = build_reference_image(elf_path, size_mb=8, work_dir=work_dir)
        block_num = find_target_block(ref_path)
        print(f"[ecc_bit_flip_test.py] Target payload landed on block {block_num} "
              f"(0x{block_num:X}). Sweeping 1..8 simultaneous bit errors, then 9.",
              file=sys.stderr)
        ref_bytes = ref_path.read_bytes()

        failures = []
        for n in range(1, 9):
            output = run_one_case(elf_path, ref_bytes, block_num, n, work_dir)
            want = f"DharaFS ECC: corrected {hex32(n)} bit(s) in block {hex32(block_num)}"
            ok = want in output
            status = "PASS" if ok else "FAIL"
            print(f"[ecc_bit_flip_test.py] {n} bit error(s): {status}"
                  + ("" if ok else f" -- expected {want!r} in output, not found"),
                  file=sys.stderr)
            if not ok:
                failures.append(n)

        output9 = run_one_case(elf_path, ref_bytes, block_num, 9, work_dir)
        want9 = f"DharaFS ECC: UNCORRECTABLE error in block {hex32(block_num)}"
        false_correction = f"DharaFS ECC: corrected" in output9
        ok9 = (want9 in output9) and not false_correction
        print(f"[ecc_bit_flip_test.py] 9 bit error(s) (t+1, should be detected-"
              f"uncorrectable): {'PASS' if ok9 else 'FAIL'}"
              + ("" if ok9 else f" -- expected {want9!r} and no false correction claim"),
              file=sys.stderr)
        if not ok9:
            failures.append(9)

        if failures:
            print(f"\n[ecc_bit_flip_test.py] FAIL -- case(s) {failures} did not behave as expected.",
                  file=sys.stderr)
            return 1
        print("\n[ecc_bit_flip_test.py] PASS -- 1..8 simultaneous bit errors all corrected "
              "exactly, 9 correctly detected as uncorrectable with no miscorrection.",
              file=sys.stderr)
        return 0
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
