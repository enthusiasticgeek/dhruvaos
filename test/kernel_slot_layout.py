#!/usr/bin/env python3
# Single source of truth for the A/B kernel-slot raw SD block layout
# (see the plan this came from: A/B kernel slots with UART upload and
# automatic rollback). Used both as a library (flash_sd_card.sh's
# seeding step, future kernelupload-side tooling) and as a standalone
# CLI for Phase-1 verification against a throwaway disk image, before
# any boot-path code exists at all.
#
# Block numbers and the 512-byte slot-state record layout MUST match
# kernel_main.vani's own reservation comment next to
# rtl8188cu_fw_raw_sd_base_block, and (once written) boot/stage0's own
# constants -- this file is the one place these numbers are defined;
# everywhere else just cites it.
import argparse
import hashlib
import os
import struct
import sys
import zlib

BLOCK_SIZE = 512

# Existing regions (unchanged, documented here only so the free-space
# math is visible in one place -- not touched by this tool):
#   blocks 1-2047      DharaFS log
#   blocks 4000-4127   crypto metadata
#   blocks 8192-8223   RTL8188CU WiFi firmware raw fallback
SLOT_STATE_BLOCK_A = 9216
SLOT_STATE_BLOCK_B = 9217
SLOT_SIZE_BLOCKS = 12288  # 6 MiB
SLOT_A_BASE_BLOCK = 10240
SLOT_B_BASE_BLOCK = 22528
SLOT_SIZE_BYTES = SLOT_SIZE_BLOCKS * BLOCK_SIZE

MAGIC = 0x44485342  # "DHSB"
DEFAULT_BOOTLIMIT = 3

# offset: field (little-endian throughout -- a new record with no
# existing-codebase endianness precedent to match, so pick one and
# stay consistent rather than inherit this project's mixed be/le
# history elsewhere).
#   0   u32 magic
#   4   u32 generation
#   8   u8  active_slot      (0=A, 1=B)
#   9   u8  preferred_slot
#   10  u16 reserved0
#   12  u32 attempt_count
#   16  u32 bootlimit
#   20  u8  slot_a_ready
#   21  u8  slot_b_ready
#   22  u16 reserved1
#   24  u32 slot_a_len
#   28  u32 slot_b_len
#   32  u8[32] slot_a_sha256
#   64  u8[32] slot_b_sha256
#   96  u32 crc32 (over bytes 0..95)
_STRUCT_FMT = "<IIBBHII BBH II 32s32s I".replace(" ", "")
_STRUCT_SIZE = struct.calcsize(_STRUCT_FMT)
assert _STRUCT_SIZE == 100, _STRUCT_SIZE


def pack_state(generation, active_slot, preferred_slot, attempt_count,
               bootlimit, slot_a_ready, slot_b_ready, slot_a_len,
               slot_b_len, slot_a_sha256, slot_b_sha256):
    assert len(slot_a_sha256) == 32 and len(slot_b_sha256) == 32
    body = struct.pack(
        _STRUCT_FMT[:-1],  # everything except the trailing crc32 'I'
        MAGIC, generation, active_slot, preferred_slot, 0,
        attempt_count, bootlimit, slot_a_ready, slot_b_ready, 0,
        slot_a_len, slot_b_len, slot_a_sha256, slot_b_sha256,
    )
    crc = zlib.crc32(body) & 0xFFFFFFFF
    record = body + struct.pack("<I", crc)
    assert len(record) == _STRUCT_SIZE
    return record + b"\x00" * (BLOCK_SIZE - _STRUCT_SIZE)


def unpack_state(raw_block):
    if len(raw_block) < _STRUCT_SIZE:
        return None
    fields = struct.unpack(_STRUCT_FMT, raw_block[:_STRUCT_SIZE])
    (magic, generation, active_slot, preferred_slot, _r0, attempt_count,
     bootlimit, slot_a_ready, slot_b_ready, _r1, slot_a_len, slot_b_len,
     slot_a_sha256, slot_b_sha256, crc) = fields
    if magic != MAGIC:
        return None
    body = raw_block[:96]
    if (zlib.crc32(body) & 0xFFFFFFFF) != crc:
        return None
    return {
        "generation": generation,
        "active_slot": active_slot,
        "preferred_slot": preferred_slot,
        "attempt_count": attempt_count,
        "bootlimit": bootlimit,
        "slot_a_ready": slot_a_ready,
        "slot_b_ready": slot_b_ready,
        "slot_a_len": slot_a_len,
        "slot_b_len": slot_b_len,
        "slot_a_sha256": slot_a_sha256.hex(),
        "slot_b_sha256": slot_b_sha256.hex(),
    }


def read_block(f, block_num):
    f.seek(block_num * BLOCK_SIZE)
    data = f.read(BLOCK_SIZE)
    if len(data) < BLOCK_SIZE:
        data = data + b"\x00" * (BLOCK_SIZE - len(data))
    return data


def write_block(f, block_num, data):
    assert len(data) == BLOCK_SIZE
    f.seek(block_num * BLOCK_SIZE)
    f.write(data)


def read_slot_state(f):
    """Returns (dict, which) for whichever ping-pong copy is CRC-valid
    and has the higher generation; (None, None) if neither is valid."""
    a = unpack_state(read_block(f, SLOT_STATE_BLOCK_A))
    b = unpack_state(read_block(f, SLOT_STATE_BLOCK_B))
    if a is None and b is None:
        return None, None
    if a is None:
        return b, "B"
    if b is None:
        return a, "A"
    return (a, "A") if a["generation"] >= b["generation"] else (b, "B")


def _ensure_image_size(path, min_bytes):
    size = os.path.getsize(path) if os.path.exists(path) else 0
    if size < min_bytes:
        with open(path, "ab") as f:
            f.truncate(min_bytes)


def cmd_seed(args):
    kernel_path = args.kernel_bin
    kernel_len = os.path.getsize(kernel_path)
    if kernel_len > SLOT_SIZE_BYTES:
        print(f"ERROR: {kernel_path} is {kernel_len} bytes, exceeds "
              f"slot size {SLOT_SIZE_BYTES} bytes ({SLOT_SIZE_BYTES // (1024*1024)} MiB)",
              file=sys.stderr)
        return 1
    with open(kernel_path, "rb") as kf:
        kernel_bytes = kf.read()
    digest = hashlib.sha256(kernel_bytes).digest()

    min_size = (SLOT_B_BASE_BLOCK + SLOT_SIZE_BLOCKS) * BLOCK_SIZE
    if not args.device:
        _ensure_image_size(args.target, min_size)

    with open(args.target, "r+b") as f:
        f.seek(SLOT_A_BASE_BLOCK * BLOCK_SIZE)
        f.write(kernel_bytes)
        record = pack_state(
            generation=1, active_slot=0, preferred_slot=0,
            attempt_count=0, bootlimit=DEFAULT_BOOTLIMIT,
            slot_a_ready=1, slot_b_ready=0,
            slot_a_len=kernel_len, slot_b_len=0,
            slot_a_sha256=digest, slot_b_sha256=b"\x00" * 32,
        )
        write_block(f, SLOT_STATE_BLOCK_A, record)
        write_block(f, SLOT_STATE_BLOCK_B, record)
        f.flush()
        os.fsync(f.fileno())

    print(f"Seeded slot A with {kernel_path} ({kernel_len} bytes, "
          f"sha256={digest.hex()}), wrote slot-state generation 1 to "
          f"blocks {SLOT_STATE_BLOCK_A}/{SLOT_STATE_BLOCK_B}.")
    return 0


def cmd_status(args):
    with open(args.target, "rb") as f:
        state, which = read_slot_state(f)
    if state is None:
        print("No valid slot-state record found (neither ping-pong copy "
              "has a matching magic/CRC) -- fresh/corrupt card.")
        return 1
    print(f"Valid copy: {which}  generation={state['generation']}")
    print(f"active_slot={'A' if state['active_slot'] == 0 else 'B'}  "
          f"preferred_slot={'A' if state['preferred_slot'] == 0 else 'B'}")
    print(f"attempt_count={state['attempt_count']}  bootlimit={state['bootlimit']}")
    print(f"slot A: ready={state['slot_a_ready']} len={state['slot_a_len']} "
          f"sha256={state['slot_a_sha256']}")
    print(f"slot B: ready={state['slot_b_ready']} len={state['slot_b_len']} "
          f"sha256={state['slot_b_sha256']}")
    return 0


def cmd_verify(args):
    with open(args.target, "rb") as f:
        state, which = read_slot_state(f)
        if state is None:
            print("ERROR: no valid slot-state record.", file=sys.stderr)
            return 1
        bad = False
        for slot_name, base, ready, length, expect_hex in (
            ("A", SLOT_A_BASE_BLOCK, state["slot_a_ready"], state["slot_a_len"], state["slot_a_sha256"]),
            ("B", SLOT_B_BASE_BLOCK, state["slot_b_ready"], state["slot_b_len"], state["slot_b_sha256"]),
        ):
            if not ready:
                print(f"slot {slot_name}: not marked ready, skipping verify")
                continue
            f.seek(base * BLOCK_SIZE)
            payload = f.read(length)
            actual_hex = hashlib.sha256(payload).hexdigest()
            ok = actual_hex == expect_hex
            print(f"slot {slot_name}: len={length} expected_sha256={expect_hex} "
                  f"actual_sha256={actual_hex} {'OK' if ok else 'MISMATCH'}")
            bad = bad or not ok
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("target", help="path to a disk image file or block device")
    p.add_argument("--device", action="store_true",
                    help="target is a real block device (skip sparse-file sizing)")
    sub = p.add_subparsers(dest="cmd", required=True)

    seed_p = sub.add_parser("seed", help="write a kernel binary into slot A + a fresh slot-state record")
    seed_p.add_argument("kernel_bin", help="path to the flat kernel binary to seed into slot A")

    sub.add_parser("status", help="print the current slot-state record")
    sub.add_parser("verify", help="recompute sha256 over each ready slot's stored length, compare to the recorded digest")

    args = p.parse_args()
    if args.cmd == "seed":
        return cmd_seed(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "verify":
        return cmd_verify(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
