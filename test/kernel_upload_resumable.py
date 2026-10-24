#!/usr/bin/env python3
"""Resumable, chunked kernelupload driver -- see kernel_main.vani's
shell_dispatch_kernelupload `resumebegin`/`resumechunk`/`resumeverify`/
`resumestatus`/`resumeabort` sub-commands for the board-side half of
this protocol (added 2026-10-23, user request: a single-shot
`kernelupload stream` loses ALL progress on any stall -- including one
triggered by this same real-HW SD-card/USB-hub investigation's own
watchdog reboot). Splits the image into a fixed number of chunks, each
independently sha256-verified and persisted to a raw SD block (ping-
ponged, survives a board reboot mid-upload) before moving to the next
-- a watchdog reboot after chunk 4 of 10 resumes from chunk 5, not
chunk 0. The board also enforces a cross-reboot attempt limit
(KERNELUPLOAD_CHUNK_ATTEMPT_LIMIT, kernel_main.vani) -- if a resumed
upload has already been retried that many times, resumebegin reports
LIMIT_EXCEEDED and refuses to continue until an explicit
`kernelupload resumeabort`. The board's own active/preferred slot is
never touched by any of this until the final, unmodified `kernelupload
commit` succeeds -- a stalled, abandoned, or limit-exceeded chunked
upload always leaves the board booting whatever was already active.

This script itself is NOT what survives a reboot -- if THIS PROCESS is
killed or the host reboots mid-upload, just run it again with the same
arguments: it calls `kernelupload resumebegin` first and resumes from
whatever the BOARD'S OWN persisted record says, independent of any
host-side state.

Usage:
  python3 test/kernel_upload_resumable.py /dev/ttyUSB0 build/kernel.img
  python3 test/kernel_upload_resumable.py /dev/ttyUSB0 build/kernel.img --chunks 10
"""
import argparse
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kernel_upload import ShellSession, open_serial, check_device_exclusive


def read_line_response(session: ShellSession, timeout: float):
    """Blocks until the next newline-terminated line arrives, returning
    exactly the text produced since the call started (not tail_text's
    whole-buffer-tail semantics) -- lets the caller treat each `kernelupload
    resume*` reply as one discrete, parseable response instead of having
    to re-scan an ever-growing buffer by hand."""
    start = session.consumed
    if not session.read_until("\n", timeout=timeout):
        return None
    with session.lock:
        text = bytes(session.buf[start:session.consumed]).decode(errors="replace")
    return text.strip()


def compute_chunk_layout(total_len: int, chunk_count: int):
    """Mirrors kernelupload_chunk_progress's own resumebegin math
    EXACTLY (kernel_main.vani) -- every non-final chunk rounded up to a
    512-byte SD block boundary, so the host's own byte ranges always
    land on the same offsets the board independently computes from
    just (total_len, chunk_count). Returns (chunk_size, last_chunk_len)."""
    raw_chunk_size = (total_len + chunk_count - 1) // chunk_count
    chunk_size = ((raw_chunk_size + 511) // 512) * 512
    last_chunk_len = total_len - (chunk_size * (chunk_count - 1))
    if last_chunk_len <= 0:
        raise ValueError(f"chunk_count={chunk_count} is too large for total_len={total_len} "
                          f"(computed chunk_size={chunk_size}, last_chunk_len={last_chunk_len})")
    return chunk_size, last_chunk_len


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", help="serial device, e.g. /dev/ttyUSB0")
    ap.add_argument("kernel_img", help="path to the flat kernel binary to upload")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--chunks", type=int, default=10,
                     help="how many chunks to split the image into (default 10, matching the user's own "
                          "worked example: 'divide 3MB kernel file into 10 chunks')")
    ap.add_argument("--window-size", type=int, default=512,
                     help="ACK-driven flow-control window within each chunk -- see send_raw_ack_paced's own "
                          "docstring (kernel_upload.py); MUST stay <=512")
    ap.add_argument("--ack-timeout", type=float, default=5.0)
    ap.add_argument("--chunk-retry-limit", type=int, default=20,
                     help="how many times THIS SCRIPT will retry one chunk's own stream+verify round trip "
                          "before giving up on this run -- independent of the board's own cross-reboot "
                          "resumebegin attempt limit (that one survives a reboot, this one doesn't)")
    ap.add_argument("--ready-timeout", type=float, default=30)
    ap.add_argument("--go-timeout", type=float, default=10)
    ap.add_argument("--stall-timeout", type=float, default=30,
                     help="seconds to wait for the final DONE once a chunk's own bytes are all sent")
    ap.add_argument("--commit-timeout", type=float, default=60)
    ap.add_argument("--log", default="/tmp/kernel_upload_resumable.log")
    args = ap.parse_args()

    data = open(args.kernel_img, "rb").read()
    real_len = len(data)
    final_sha256 = hashlib.sha256(data).hexdigest()
    print(f"kernel image: {real_len} bytes, sha256={final_sha256}")

    chunk_size, last_chunk_len = compute_chunk_layout(real_len, args.chunks)
    print(f"chunk layout: {args.chunks} chunks, {chunk_size} bytes each "
          f"(last chunk {last_chunk_len} bytes)")

    if not check_device_exclusive(args.device):
        return 1
    fd = open_serial(args.device, args.baud)
    session = ShellSession(fd, args.log)

    try:
        print("checking the board is up and answering ('ready')...")
        if not session.wait_until_ready(overall_timeout=args.ready_timeout):
            print("[FAIL] board never answered 'ready' -- is it powered on and already booted?")
            return 1
        print("[board ready]")

        session.send(f"kernelupload resumebegin {real_len} {args.chunks} {final_sha256}")
        resp = read_line_response(session, timeout=10)
        if resp is None:
            print("[FAIL] no response to resumebegin")
            print(session.tail_text())
            return 1
        print(f"resumebegin -> {resp!r}")

        start_chunk = 0
        all_done = False
        if resp.startswith("FRESH"):
            start_chunk = 0
        elif resp.startswith("RESUME"):
            parts = resp.split()
            start_chunk = int(parts[1])
            attempt = int(parts[2]) if len(parts) > 2 else None
            print(f"  ...resuming from chunk {start_chunk}/{args.chunks} (attempt {attempt})")
        elif resp.startswith("ALLDONE"):
            print("  ...every chunk was already confirmed by a prior run -- skipping straight to commit")
            all_done = True
        elif resp.startswith("BUSY"):
            print("[FAIL] a different resumable upload is already in progress on the board.")
            print("       Run 'kernelupload resumeabort' on the board first if you mean to discard it.")
            return 1
        elif resp.startswith("LIMIT_EXCEEDED"):
            print(f"[FAIL] {resp}")
            return 1
        else:
            print(f"[FAIL] unrecognized resumebegin response: {resp!r}")
            return 1

        t0 = time.time()
        chunk_index = start_chunk
        if not all_done:
            while chunk_index < args.chunks:
                offset = chunk_index * chunk_size
                this_len = last_chunk_len if (chunk_index == args.chunks - 1) else chunk_size
                chunk_bytes = data[offset:offset + this_len]
                chunk_sha = hashlib.sha256(chunk_bytes).hexdigest()

                chunk_done = False
                resync_to = None
                for attempt_i in range(1, args.chunk_retry_limit + 1):
                    print(f"  chunk {chunk_index}/{args.chunks - 1}: {this_len} bytes, "
                          f"attempt {attempt_i}/{args.chunk_retry_limit} ({time.time() - t0:.1f}s elapsed)")
                    session.send(f"kernelupload resumechunk {chunk_index} {this_len}")
                    go_resp = read_line_response(session, timeout=args.go_timeout)
                    if go_resp is None:
                        print("    [retry] no response to resumechunk")
                        continue
                    if go_resp.startswith("EXPECTED"):
                        # 2026-10-23: the board is the sole source of truth
                        # for progress (same principle Zephyr's own MCUmgr
                        # img_mgmt upload protocol uses: the DEVICE'S own
                        # reported offset is authoritative after a dropped
                        # response, the client resyncs to it rather than
                        # treating the mismatch as fatal). This fires if a
                        # PRIOR resumeverify's own CHUNKOK/ALLDONE reply was
                        # lost on the wire even though the board's write
                        # already landed -- resync forward and recheck
                        # rather than aborting a genuinely-healthy upload.
                        resync_to = int(go_resp.split()[1])
                        print(f"    [resync] board already has chunk {resync_to - 1} confirmed -- "
                              f"advancing from {chunk_index} to {resync_to}")
                        break
                    if not go_resp.startswith("GO"):
                        print(f"    [retry] unexpected resumechunk response: {go_resp!r}")
                        continue

                    try:
                        session.send_raw_ack_paced(chunk_bytes, args.window_size, args.ack_timeout)
                    except IOError as e:
                        print(f"    [retry] {e}")
                        continue
                    if not session.read_until("DONE ", timeout=args.stall_timeout):
                        print(f"    [retry] no DONE within {args.stall_timeout}s of sending all chunk bytes")
                        continue

                    session.send(f"kernelupload resumeverify {chunk_index} {chunk_sha}")
                    verify_resp = read_line_response(session, timeout=args.commit_timeout)
                    if verify_resp is None:
                        print("    [retry] no response to resumeverify")
                        continue
                    if verify_resp.startswith("EXPECTED"):
                        resync_to = int(verify_resp.split()[1])
                        print(f"    [resync] board already has chunk {resync_to - 1} confirmed -- "
                              f"advancing from {chunk_index} to {resync_to}")
                        break
                    if verify_resp.startswith("CHUNKOK"):
                        print(f"    [ok] chunk {chunk_index} verified")
                        chunk_done = True
                        break
                    if verify_resp.startswith("ALLDONE"):
                        print(f"    [ok] chunk {chunk_index} verified -- all chunks done, stitched")
                        chunk_done = True
                        all_done = True
                        break
                    if verify_resp.startswith("CHUNKFAIL"):
                        print(f"    [retry] {verify_resp}")
                        continue
                    print(f"    [retry] unexpected resumeverify response: {verify_resp!r}")

                if resync_to is not None:
                    if resync_to <= chunk_index:
                        print(f"[FAIL] board reported chunk {resync_to} as next-expected, which is not "
                              f"ahead of {chunk_index} -- real progress disagreement, not just a dropped "
                              f"reply. Aborting rather than guessing.")
                        return 1
                    chunk_index = resync_to
                    continue
                if not chunk_done:
                    print(f"[FAIL] chunk {chunk_index} did not verify after "
                          f"{args.chunk_retry_limit} attempts -- run this script again to resume "
                          f"(the board remembers chunks already confirmed)")
                    return 1
                if all_done:
                    break
                chunk_index += 1

        print(f"  ...all chunks verified and stitched ({time.time() - t0:.1f}s elapsed)")
        print("committing (board re-reads every written block from SD and re-verifies -- may take a while)...")
        commit_needle = "verified and marked ready"
        if not session.step(f"kernelupload commit {real_len} {final_sha256}", commit_needle,
                             timeout=args.commit_timeout, attempts=1):
            print(f"[FAIL] commit did not report success ({commit_needle!r}) -- check {args.log} for the real error")
            return 1

        print(f"[PASS] uploaded and verified {real_len} bytes (sha256={final_sha256}) via "
              f"{args.chunks} resumable chunks")
        print("Not activated yet -- run 'kernelslot activate a' or 'kernelslot activate b' by hand when ready to try it.")
        return 0
    finally:
        session.close()
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
