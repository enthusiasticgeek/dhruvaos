#!/usr/bin/env python3
"""Dhruva Phase 3 milestone: prove the filesystem never returns a torn
record after a write is interrupted, swept across every possible byte
offset a "power loss" could land on -- more exhaustive than any single
physical yank test could ever be, since a real yank only ever gives you
whatever offset the hardware happened to be at.

Methodology (deliberately post-hoc, not a live race against QEMU):
racing a real-time process kill against a specific byte offset inside
a guest's write is nondeterministic and not reproducible run to run.
Instead:

  1. Boot dhruva once against a fresh image and let it run to
     completion, producing a "good" reference image where /config/mode
     has been written three times (auto -> dhruva's own name write in
     between -> manual) -- block 3 (byte offset 1536) holds the
     overwriting "manual" record.
  2. For each swept offset K, take a fresh copy of that reference
     image and zero out block 3's bytes from K to the end of the
     block. This models "the write reached exactly K bytes before
     power was lost" -- for an append-only log, every torn write is
     necessarily against a block that was blank immediately before
     (nothing else could have been there), so zeroing the untouched
     tail is the actually-correct model here, not a simplification.
  3. Boot dhruva against each doctored copy and check what it reports
     for /config/mode: recovery must reject the torn record (it will
     fail buf_checksum's validation, or fail the seq_num != 0 check
     for a fully-zeroed block) and fall back to the last genuinely
     complete record for that path -- "auto", from block 1. Seeing
     "manual" (the torn value making it through anyway) or anything
     else entirely (a corrupted mix) is a failure; only "auto" passes.

Requires `-drive ...,cache=writethrough` (or another synchronous
mode): QEMU's default disk-image caching buffers writes in host RAM
and does not reliably flush them to the backing file on a SIGTERM-
based kill, found the hard way while first building the filesystem
itself -- without this, every "did it persist" check here would be
studying QEMU's RAM cache, not the actual backing file a real power
loss would leave behind.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

QEMU_BIN = "qemu-system-arm"
MACHINE = "raspi1ap"
BOOT_TIMEOUT_S = 8
BLOCK_SIZE = 512
# Block 3 (0-indexed from the device start) is where the current
# kernel_main.vani's third dharafs_append call (/config/mode, "manual",
# overwriting the first record at block 1) lands: block 0 is reserved,
# blocks 1/2/3 hold the auto/dhruva/manual records in that order.
TORN_BLOCK = 3
TORN_BLOCK_OFFSET = TORN_BLOCK * BLOCK_SIZE


def run_qemu(elf_path: str, image_path: str, timeout_s: float = BOOT_TIMEOUT_S) -> str:
    # dhruva never exits on its own -- start_multitasking's scheduler
    # loop runs forever by design, so EVERY invocation here is expected
    # to be killed by the timeout, not to exit cleanly. Wrapping with
    # the shell `timeout` command (rather than relying solely on
    # subprocess.run's own `timeout=` kwarg) is deliberate: found in
    # this same session that Python's internal timeout handling didn't
    # reliably terminate QEMU in this environment -- a run sat alive
    # for 10+ minutes past its supposed 8-second budget despite
    # subprocess.run's documented behavior, while the exact same
    # command wrapped in the shell's own `timeout` reliably killed it
    # right on schedule. `--kill-after=5` is a second line of defense
    # (escalates to SIGKILL if the initial SIGTERM is somehow ignored)
    # -- cheap insurance for a sweep meant to run unattended for
    # however many offsets a full run needs.
    cmd = [
        "timeout", "--kill-after=5", str(timeout_s),
        QEMU_BIN,
        "-M", MACHINE,
        "-nographic",
        "-kernel", elf_path,
        "-drive", f"file={image_path},if=sd,format=raw,cache=writethrough",
    ]
    # The outer Python-level timeout is a backstop well past the
    # shell timeout's own budget, not the primary enforcement -- if
    # even `timeout --kill-after` somehow fails, this is what actually
    # keeps the sweep from hanging forever on one offset.
    proc = subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout_s + 15,
    )
    return proc.stdout + proc.stderr


def extract_marker_value(output: str, marker: str) -> str | None:
    start = output.find(marker)
    if start < 0:
        return None
    start += len(marker)
    end = output.find('"', start)
    if end < 0:
        return None
    return output[start:end]


def extract_final_mode_value(output: str) -> str | None:
    """The value after this same boot's own fresh dharafs_append calls --
    only meaningful for validating the reference image build itself."""
    return extract_marker_value(output, 'DharaFS: /config/mode = "')


def extract_recovery_mode_value(output: str) -> str | None:
    """What dharafs_init's recovery scan alone found, BEFORE this boot's own
    fresh writes -- the actual signal this test cares about. kernel_main
    prints this separately specifically so power_yank.py can check it
    without every boot's own unconditional demo re-appends masking a
    torn record's rejection."""
    return extract_marker_value(output, 'DharaFS: post-recovery /config/mode = "')


def build_reference_image(elf_path: str, size_mb: int, work_dir: Path) -> Path:
    ref_path = work_dir / "reference.img"
    subprocess.run(
        ["dd", "if=/dev/zero", f"of={ref_path}", "bs=1M", f"count={size_mb}"],
        check=True, capture_output=True,
    )
    output = run_qemu(elf_path, str(ref_path))
    value = extract_final_mode_value(output)
    if value != "manual":
        print("[power_yank.py] Reference image build failed -- expected "
              f"/config/mode = \"manual\" after a normal run, got {value!r}.",
              file=sys.stderr)
        print(output, file=sys.stderr)
        sys.exit(2)
    return ref_path


def sweep(elf_path: str, ref_path: Path, work_dir: Path, step: int) -> tuple[int, int, list[int]]:
    ref_bytes = ref_path.read_bytes()
    total = 0
    passed = 0
    skipped = 0
    failures: list[int] = []

    for k in range(0, BLOCK_SIZE, step):
        tear_start = TORN_BLOCK_OFFSET + k
        tear_end = TORN_BLOCK_OFFSET + BLOCK_SIZE

        # A record this short doesn't use every byte of its 512-byte
        # block -- unused path/data padding is already zero even in
        # the complete, valid record. Zeroing a tail that's already
        # all zero isn't a tear at all, just the same complete record
        # again, and would correctly (and uninformatively) report
        # "manual" -- skip offsets where doctoring wouldn't actually
        # change anything, rather than asserting a fallback that
        # genuinely shouldn't happen here.
        if ref_bytes[tear_start:tear_end] == b"\x00" * (tear_end - tear_start):
            skipped += 1
            continue

        total += 1
        doctored = bytearray(ref_bytes)
        doctored[tear_start:tear_end] = b"\x00" * (tear_end - tear_start)

        test_img = work_dir / f"tear_{k}.img"
        test_img.write_bytes(bytes(doctored))
        output = run_qemu(elf_path, str(test_img))
        test_img.unlink()

        value = extract_recovery_mode_value(output)
        if value == "auto":
            passed += 1
        else:
            failures.append(k)
            print(f"[power_yank.py] offset {k:3d}: FAIL -- expected \"auto\", got {value!r}",
                  file=sys.stderr)

    if skipped:
        print(f"[power_yank.py] Skipped {skipped} offset(s) where the tear point falls "
              "entirely within bytes that are already zero in the complete record "
              "(unused path/data padding) -- not a genuine tear to test.",
              file=sys.stderr)

    return total, passed, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("elf", help="path to the built dhruva.elf")
    parser.add_argument("--size-mb", type=int, default=8,
                         help="reference image size in MB (default: %(default)s)")
    parser.add_argument("--step", type=int, default=1,
                         help="sweep every Nth byte offset within the 512-byte block "
                              "instead of all 512 -- use a larger step for a quick "
                              "smoke test, 1 (default) for the full exhaustive sweep")
    parser.add_argument("--keep-work-dir", action="store_true",
                         help="don't delete the temporary work directory on exit "
                              "(useful for inspecting a failing doctored image by hand)")
    args = parser.parse_args()

    work_dir = Path(tempfile.mkdtemp(prefix="dhruva_power_yank_"))
    try:
        print(f"[power_yank.py] Building reference image in {work_dir} ...", file=sys.stderr)
        ref_path = build_reference_image(args.elf, args.size_mb, work_dir)
        print(f"[power_yank.py] Reference image OK. Sweeping block {TORN_BLOCK} "
              f"(offset {TORN_BLOCK_OFFSET}) at step {args.step} ...", file=sys.stderr)

        total, passed, failures = sweep(args.elf, ref_path, work_dir, args.step)

        print(f"\n[power_yank.py] {passed}/{total} offsets recovered correctly.",
              file=sys.stderr)
        if failures:
            print(f"[power_yank.py] FAIL -- {len(failures)} offset(s) returned a torn "
                  f"or corrupted value instead of falling back cleanly: {failures}",
                  file=sys.stderr)
            return 1
        print("[power_yank.py] PASS -- every swept offset recovered to the last "
              "fully-committed record, never a torn one.", file=sys.stderr)
        return 0
    finally:
        if args.keep_work_dir:
            print(f"[power_yank.py] Work dir kept at {work_dir}", file=sys.stderr)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
