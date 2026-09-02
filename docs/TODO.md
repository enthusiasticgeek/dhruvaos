# Dhruva OS — open backlog

Effort buckets are relative to this project's own established
"round" cadence (see git log / project memory — one round is
typically one focused, fully-verified unit of work: build, full
self-test + `phase4_milestone.py` battery, `heap_stress.py`/
`power_yank.py`, commit). S/M/L/XL below is sized against that unit,
not calendar time.

## Storage & USB portability (Pi 4 / Pi 5 / Compute Module)

The filesystem layer below is named **DharaFS** ("dhara" — धर,
Sanskrit for "bearer/holder") — every `dharafs_*` function in
`kernel/kernel_main.vani` is this component, distinct from Dhruva
itself. Grew well past its original "task #4" scope across rounds
39/42 (multi-block files, journaling hardening, owner/group/other
rwx permissions, real directory hierarchy) into a real enough
component to warrant its own name.

See `docs/PORTING.md` for the full writeup this backlog references.

- **Block-device abstraction for the FS layer** — `[S, ~1 round —
  DONE, round 36]`
  Replaced the FS layer's 8 real direct `sdhost_read_block`/
  `sdhost_write_block` call sites (`dharafs_init`/`dharafs_append_raw`/`dharafs_find_
  latest_block_raw`/`dharafs_compact`/`dharafs_read_raw` — more than the
  original ~5 estimate once actually counted; the SD driver's own
  8-block self-test sweep deliberately still calls SDHOST directly,
  since its whole point is testing that peripheral specifically) with
  calls through `dharafs_block_read`/`dharafs_block_write`. Not a function-
  pointer/vtable interface as originally envisioned here — no evidence
  vani supports storing a callable function value persistently across
  calls the way this project's own `extern "C"` state-accessor pattern
  needs, so a simple `dharafs_state`-backed integer selector (0=SDHOST,
  1=USB mass storage) with an `if`/`else` dispatch was used instead,
  matching this codebase's own established mutually-exclusive-`if`
  state-dispatch style elsewhere (`ifconfig`'s DHCP state print,
  `netstat`'s TCP state names). Same functional outcome, simpler and
  provably within the language's actual capabilities. SDHOST remains
  the permanent default (`.bss` zero-init) — zero behavior change for
  every real FS operation, confirmed by the full existing battery.
  USB mass storage proved as a genuine second backend through this
  same abstraction (see the USB mass storage item below).
  Unblocks: EMMC2 (needs Pi 4 hardware regardless) and NVMe, whenever
  either is actually built — same abstraction, a new backend behind it.

- **EMMC2 block driver (Pi 4 storage)** — `[M, ~2-3 rounds]`
  New low-level driver for BCM2711's EMMC2 controller, implementing
  the block-device interface above. Needs real Pi 4 hardware (or a
  fully accurate emulator, which QEMU does not currently offer at
  this project's needed fidelity) to verify — loses the pure-QEMU
  verification loop the project has used for every round so far.
  Depends on: block-device abstraction (above).

- **XHCI USB host controller driver (Pi 4/5 USB 3.x)** — `[XL,
  several rounds — the largest single item in this backlog]`
  A new driver from scratch for the XHCI class (VL805 on Pi 4, RP1 on
  Pi 5) — ring-based command/event/transfer queues, a materially
  larger enumeration state machine than DWC2's. The existing
  mass-storage/network device-class handling built on top of DWC2's
  enumeration needs re-plumbing on top of this, not just a driver
  swap underneath it. Connector type (Type-A/micro/C) is not a
  software concern — only the host controller silicon matters.
  Real-hardware bring-up required; no QEMU safety net available.

## New capability roadmap (Pi 1, buildable and regression-testable under QEMU now)

Unlike the storage/USB portability section above, these three don't
need new hardware to build OR verify — they deepen subsystems this
project already targets on Pi 1, and QEMU's fidelity is sufficient for
the whole build-and-regress loop this project has used every round so
far. Expect each to span multiple rounds/sessions, same as any
multi-round item elsewhere in this backlog.

- **USB mass storage class driver** — `[L, ~4-6 rounds — DONE (rounds
  33-36); see scope note below on what "done" does and doesn't mean]`
  Today's DWC2 driver does enumeration only (`GET_DESCRIPTOR`,
  `SET_ADDRESS`, `SET_CONFIGURATION`) — "no bulk or interrupt
  transfers, control only" per the driver's own comment. A real
  prerequisite, not optional: bulk transfer support has to land in the
  DWC2 driver first (a materially different endpoint/transfer-type
  path than control transfers), before Bulk-Only Transport (CBW/CSW)
  and a minimal SCSI subset can be built on top. Fully QEMU-testable
  throughout — `-device usb-storage` (already used every round for
  enumeration regression) emulates a real BOT+SCSI device, so
  bring-up and regression don't need to wait for real hardware.
  - Done (round 33): config-descriptor parsing now actually extracts
    (not just counts) bulk endpoint address/max-packet-size for a
    detected Mass Storage/SCSI/BOT interface (class 0x08/subclass
    0x06/protocol 0x50); `dwc2_bulk_out`/`dwc2_bulk_in` primitives with
    correct generic (non-control) PID/data-toggle tracking, persistent
    per endpoint; CBW/CSW framing and a live `TEST UNIT READY` round
    trip, verified against QEMU's real `usb-storage` backend (correctly
    reproduced a genuine SCSI Unit Attention on the first command, GOOD
    status on retry — also exercising toggle tracking across a second
    transfer). `usb-net` enumeration confirmed completely unaffected
    (gated on the BOT interface actually being present).
  - Done (round 34): factored the CBW-out/data-in/CSW-in shape into a
    generic `usb_msd_scsi_command_in` (rule of three, once a third
    near-identical call site appeared); added `INQUIRY` (real 36-byte
    data-in stage, the first this driver exercises) and
    `READ CAPACITY(10)` (8-byte data-in, both fields big-endian —
    SCSI's own wire convention, distinct from and easy to confuse with
    the BOT wrapper's little-endian CBW/CSW fields). Live-verified
    against QEMU's real `usb-storage` backend with independently
    checkable ground truth: `INQUIRY` returned the real "QEMU"/"QEMU
    HARDDISK" vendor/product strings, `READ CAPACITY(10)` returned
    last_lba=0x3FFF/block_len=0x200 — exactly matching a fresh 8MB
    backing image (16384 × 512 = 8388608 bytes). `usb-net` confirmed
    still completely unaffected.
  - Done (round 35): added a new dedicated 512-byte `usb_bulk_data_
    scratch` (not a resize of the shared 64-byte `dwc2_dma_scratch`,
    which still backs control transfers unchanged) and pointed
    `dwc2_bulk_out`/`dwc2_bulk_in` at it, raising their cap from 64 to
    512 bytes. Generalized round 34's `usb_msd_scsi_command_in` into
    `usb_msd_scsi_command` (added an `is_write` direction) once
    `WRITE(10)`'s OUT data stage needed the same shape as `READ(10)`'s
    IN. Added `usb_msd_read10`/`usb_msd_write10` and a live round-trip
    check (write a real pattern to LBA 100, read it back, byte-compare
    via the SAME `test_fill_pattern`/`test_compare_buffers` helpers the
    SD driver's own round-trip sweep uses). Worked first try.
    Verified at the strongest level available: read the QEMU backing
    image file directly from the host at byte offset 100×512 and
    confirmed it holds the real, persisted pattern — not just an
    in-session round trip, a genuinely durable sector write. `usb-net`
    confirmed still completely unaffected.
  - Done (round 36): built the block-device abstraction (see that item
    above) and routed the FS layer's own 8 real `sdhost_read_block`/
    `write_block` call sites (`dharafs_init`/`dharafs_append_raw`/`dharafs_find_
    latest_block_raw`/`dharafs_compact`/`dharafs_read_raw` — more than the
    original ~5 estimate once actually counted) through `dharafs_block_
    read`/`dharafs_block_write` instead. SDHOST stays the permanent default
    (`dharafs_state`'s new `dharafs_block_dev` selector defaults to 0 via `.bss`
    zero-init) — every real FS operation (boot self-tests, shell
    `ls`/`cat`/`write`, `phase4_milestone.py`, `power_yank.py`'s own
    tear-sweep) is unaffected, confirmed by the full existing battery
    staying green unchanged. Then proved USB mass storage genuinely
    works as a second backend THROUGH the same abstraction (not just
    via round 35's own raw primitives): `dharafs_block_dev_self_check`
    temporarily flips the selector, writes a pattern via `dharafs_block_
    write`, reads it back via `dharafs_block_read`, byte-compares, then
    restores SDHOST. Independently verified at the host level again
    (LBA 200 in the backing image holds the real persisted pattern).
    `usb-net` (no BOT interface, selector never touched) confirmed
    unaffected.
    Scope note: this proves the raw block-I/O layer is genuinely
    backend-agnostic, live-verified both ways. It does NOT mean the OS
    can boot/operate its whole filesystem from a USB drive yet — that
    would need selecting the backend before `dharafs_init()` runs (today
    always SDHOST) and validating the full self-test/normal-operation
    battery against a freshly-attached, unformatted USB device, which
    is a separate, larger step nobody has asked for yet.
  This closes the USB mass storage driver feature's originally-scoped
  work (rounds 33-36). Anything past the scope note above (booting
  from USB, multiple LUNs, etc.) would be new scope, not a remaining
  piece of this item.

- **Boot Dhruva itself from a USB drive** — `[not sized, not started —
  feasibility note only, per explicit request to document this for
  later rather than build it now]`
  Two genuinely separate problems hide under this one request, and
  they have very different answers:
  1. *Loading Dhruva's own kernel image from USB instead of SD.* This
     is the SoC's boot ROM's job, not Dhruva's own code at all — on
     real hardware, BCM2835's boot ROM reads `bootcode.bin`/`start.elf`
     from the SD card's FAT boot partition and hands control to the
     kernel image named there, entirely before any of this project's
     own code has run a single instruction. **The original Raspberry
     Pi 1 Model B's boot ROM has no USB mass storage boot path at
     all** — unlike later models (Pi 3B+ via a bootloader EEPROM
     update, Pi 4/400/CM4 with native USB/NVMe boot support), Pi 1's
     boot ROM can only ever load from the SD card slot. This is a hard
     ceiling on the CURRENT hardware target, not a software gap — no
     amount of work inside Dhruva itself can make the Pi 1's own boot
     ROM do something it was never built to do. (This project's QEMU
     testing loads the kernel directly via `-kernel`, bypassing the
     real boot ROM path entirely, so it can't reveal this limitation —
     it only shows up against real Pi 1 hardware, tying back to the
     project's own planned hardware-in-loop phase.)
  2. *Using a USB drive as Dhruva's own filesystem storage once
     already running* (as opposed to loading the kernel from it). This
     is the piece rounds 33-36 above already deliver the low-level
     primitives for (`dharafs_block_read`/`dharafs_block_write` genuinely work
     against USB mass storage) — what's still missing is selecting
     that backend BEFORE `dharafs_init()` runs and validating the full
     self-test/normal-operation battery against a freshly-attached,
     unformatted USB device (the scope note on the USB mass storage
     item above). This part is real, buildable software work, not
     blocked by hardware — it's just not been asked for yet.
  **ROI assessment for right now**: not worth doing. Problem 1 is
  outright infeasible on the current Pi 1 target regardless of effort
  spent, and only becomes possible by targeting different hardware
  (Pi 3B+ or later, or the already-planned Pi 4/5 port in
  `docs/PORTING.md`) or by building a separate small SD-resident
  chain-loader stage that itself fetches the real kernel from USB — a
  distinct bootloader project of its own, not an extension of anything
  in this backlog. Problem 2 is feasible today but low-value in
  isolation: this project's own boot flow always has a working SD
  card path already, so "the OS's whole filesystem can also live on
  USB" doesn't unlock anything new that mass-storage-as-a-second-
  backend (already done) doesn't already demonstrate.
  **Revisit this** if either becomes true: (a) the project's hardware
  target moves to something with real USB boot ROM support (Pi 3B+/4/5
  or a Compute Module), making problem 1 tractable without a
  chain-loader; or (b) there's a concrete reason to want the FS's
  primary storage to be USB rather than SD specifically (problem 2
  alone), at which point it's a small, well-understood extension of
  the existing `dharafs_block_dev` selector — pick it before `dharafs_init()`
  runs instead of only inside `dharafs_block_dev_self_check`, and validate
  the existing self-test battery against it.

- **TCP retransmission + simultaneous open** — `[M-L, ~3-4 rounds —
  DONE in one round (37); simultaneous-CLOSE and the advertised
  window remain genuinely out of scope, see below]`
  Today's TCP was "a real, useful, correctly-sequenced happy-path
  connection lifecycle, not a spec-complete implementation" — no
  retransmission timers, no simultaneous-open/simultaneous-close, and
  the advertised window never consulted.
  - Done (round 37): per-connection retransmission state
    (`tcp_state.S`'s new `rtx_deadline`/`rtx_count`/`rtx_seq`/`rtx_len`
    + a 64-byte-per-connection retransmit buffer) and
    `tcp_conn_check_retransmit`, called from `tcp_conn_poll` on every
    poll for both connection slots regardless of whether a frame was
    even dequeued that call — the only way to ever notice a genuinely
    lost segment, which produces no frame at all. Covers both SYN
    retransmission (`tcp_conn_active_open` arms it, no payload
    buffering needed) and data-segment retransmission
    (`tcp_conn_send_data` buffers the exact bytes sent); cancelled on
    progress (a matching SYN-ACK, or a pure ACK covering the buffered
    data's own sequence range) via `tcp_conn_handle_segment`. RTO
    fixed at 4 ticks (2 real seconds, `timer_ic_init`'s own 500ms
    interval) with 3 retries before giving up. Live-verified with a
    new `tcprtx` shell command — the actual RTO could never be
    observed by a boot-time self-test (those run before
    `timer_ic_init`/`start_multitasking`, so `scheduler_get_tick_
    count()` never advances during one), so this needed to be a live
    shell command like `tcpecho`/`udpecho`, not another self-test:
    sends a real SYN, deliberately drops it (discovered live that
    `task_e`'s own periodic `dhcp_client_poll` can occasionally beat
    the test to the drop via the already-documented shared-queue
    hazard — made the test robust to either path removing the frame,
    since the outcome is identical either way), sleeps out the real
    RTO via `task_sleep_ticks`, then confirms the handshake still
    completes and `tcp_conn_get_rtx_count` shows at least one genuine
    retry. Formalized into `phase4_milestone.py`, verified reliable
    across 2 runs.
  - Done (round 37): simultaneous open (RFC 793) — both sides calling
    `active_open` land in SYN_SENT and each receives the peer's bare
    SYN instead of a SYN-ACK. Handled by one new branch in
    `tcp_conn_handle_segment` (bare SYN while in SYN_SENT → send
    SYN+ACK, move to SYN_RCVD) that reuses the EXISTING SYN_RCVD→
    ESTABLISHED transition unchanged — no other state-machine code
    needed to change. Verified with a new boot-time self-test
    (`tcp_conn_simultaneous_open_self_test`, no timing dependency
    needed since this is purely about segment-ordering logic, not
    timers) using the same hand-fed-frame "traffic cop" technique
    `tcp_conn_self_test` already established.
  - Explicitly NOT done, and not attempted this round: simultaneous
    CLOSE (both sides sending FIN before seeing the peer's), and the
    advertised window being consulted at all (still accepted, never
    enforced). Neither was needed to satisfy "retransmission and
    simultaneous open" as asked; flagged here rather than silently
    left implicit, in case either matters for a future round.

- **FS directory hierarchy + multi-block files + journaling
  hardening** — `[L, ~4-5 rounds]`
  Today's FS is "flat, append-only, checksummed log" — paths are
  opaque strings (`ls` does prefix filtering, not real directory
  listing).

  **Multi-block files + journaling hardening: DONE (round 39).**
  Record format gained a `next_block` field (offset 48) and a
  460-byte-per-block payload cap (`dharafs_block_payload_cap()`); files up
  to 4096 bytes (`dharafs_file_max_len()`) now chain across multiple
  blocks. `path_len == 0` is a reserved continuation-block sentinel
  (real lookups always have `path_len > 0`, so `dharafs_find_latest_block_
  raw`'s matching logic needed zero changes; `dharafs_compact`/`dharafs_list`
  needed an explicit skip-continuation-blocks guard added to their
  full-table scans). Crash safety: multi-block writes happen in
  *reverse* order — every continuation chunk first, the head block
  written *last* — so the head's own single-block atomic write is the
  one commit point that makes the whole chain reachable; a crash
  before it leaves only unreachable orphan blocks and the prior
  version of the file (or no file) intact, exactly like the existing
  single-block torn-write case. `dharafs_read`/`dharafs_read_raw` were
  consolidated (the old duplicated block-reading logic in `dharafs_read` is
  gone). Verified: two new self-tests (a real 1000-byte/3-chunk
  round-trip + overwrite, and a simulated-crash test that raw-writes
  an orphan continuation block without ever calling `dharafs_state_set` —
  the state-accounting + head-write omission a real crash would leave
  — confirming the old version is still returned intact), the full
  existing self-test battery unchanged (0 FAIL), `phase4_milestone.py`
  ×2, USB enumeration both device types with a real `-drive` attached,
  `heap_stress.py` PASS, and `power_yank.py`'s tear-point sweep
  extended automatically by the new format (58/58 offsets recovered,
  454 skipped as genuinely-unchanged zero padding) — no separate
  multi-block-specific sweep needed since the crash-safety design
  itself never lets a torn write reach a discoverable half-written
  chain.

  **Directory hierarchy: DONE (round 42).** `dharafs_list_dir_raw` groups
  live records by the first path segment after a given directory,
  distinguishing a leaf file (nothing follows) from a subdirectory
  (something does, printed once regardless of how many files live
  under it, deduplicated via a fixed 128-slot set). Shell gets
  `ls <dir>` as a new form of the existing `ls`; bare `ls` keeps its
  exact original flat, full-path-per-line behavior unchanged
  (`phase4_milestone.py`'s own check depends on it). Round 42 also
  added owner/group/other rwx permissions on top of this same record
  format (`dharafs_check_permission`, `dharafs_user_set`/`dharafs_stat`/`dharafs_chmod`/
  `dharafs_chown`, permission-checked `dharafs_read_raw_checked`/`dharafs_write_raw_
  checked`/`dharafs_delete_raw_checked` wired into the shell's `cat`/
  `write`/`rm`, new `id`/`su`/`chmod` shell commands) — not originally
  scoped under this TODO item by name, but a natural, real extension
  of the same "flat opaque-path log" limitation this item exists to
  close. Verified: two new self-tests, full existing battery unchanged
  (0 FAIL, 44 PASS), `phase4_milestone.py` ×2, USB enumeration both
  device types, `heap_stress.py`/`power_yank.py` both PASS (the new
  owner/group/mode fields shrank the per-block payload cap from 460 to
  448 bytes; `power_yank.py`'s tear sweep needed zero test changes and
  confirmed the new format's crash-safety holds, 70/70 recovered), plus
  live interactive shell verification (not just self-tests) of `su`/
  permission-denied/`chmod`/hierarchical `ls`.

  This TODO item is now **fully closed** — both halves done.

## General DMA controller (not scoped — recommendation only, round 35)

User asked about a general "DMA interface for faster stuff" while
this round was growing the USB bulk-transfer buffer. Recorded here
rather than only in chat, since it's a real architectural question
worth a documented answer:

BCM2835 has two genuinely separate DMA facilities. DWC2's own HCDMA
(what this project's USB driver already uses, control and bulk alike)
is peripheral-specific — internal to the USB host controller, already
about as fast as this hardware allows, nothing more to add there. The
SoC's *general-purpose* DMA controller (16 independent channels,
`0x20007000`) is a different, currently-untouched peripheral — the one
actual candidate for "faster stuff" in this codebase today is
`sdhost_drain_fifo_to_buffer`/`sdhost_fill_fifo_from_buffer`
(`boot/sdcard_state.S`), which still move every SD FIFO word via a
plain CPU copy loop.

**Recommendation**: don't build a general BCM2835 DMA-controller
driver speculatively now — same reasoning as not building the
block-device abstraction ahead of a second real backend. Build it
targeted at the SD FIFO path specifically once SD throughput actually
matters for something (e.g. once FS integration below makes real file
I/O throughput visible), verified live under QEMU the same way every
other peripheral in this project has been, rather than as
infrastructure nobody's calling yet.

**NEON**: not available on this project's current target. BCM2835's
ARM1176JZF-S is ARMv6 — scalar VFPv2 floating point only, no SIMD unit
of any kind. NEON (Advanced SIMD) was introduced with ARMv7-A and
needs a Cortex-A-class core; it becomes available "for free" (nothing
to build) whenever the Pi 4/5 port (Cortex-A72/A76, both ARMv8-A)
happens — see `docs/PORTING.md`. Nothing to do for it before then.

## Security hardening roadmap (2026 landscape — documentation only, nothing started)

Requested as a forward-looking list, not a commitment to build any of
it soon. Dhruva has **zero cryptographic primitives anywhere in the
codebase today** — no hashing, no symmetric cipher, no asymmetric
crypto, nothing. Every item below except memory-protection hardening
depends on that not being true anymore, so it's listed first as the
real prerequisite everything else blocks on, not because it was asked
for by name.

- **Crypto primitives foundation** — `[L, ~3-5 rounds — the real
  prerequisite for PKI/secure boot/media encryption below]`

  **SHA-256: DONE (round 41).** Full FIPS 180-4 implementation
  (`sha256_hash`/`sha256_compress` + supporting K-table/message-
  schedule/padding logic) in `kernel/kernel_main.vani`. The spike this
  entry itself recommended ("worth a small spike to confirm [vani's
  bit-twiddling support] before committing to the full build") found a
  real, concrete constraint: vani's checker/runtime traps on u32
  addition overflow rather than wrapping (confirmed both as a compile-
  time constant-fold rejection and as a genuine runtime trap), but
  SHA-256's compression function depends completely on mod-2^32
  addition. Not a blocker — every 32-bit add goes through a
  `sha256_wrap_add32` helper that widens to i64 (always safely in
  range for any u32+u32), masks to the low 32 bits, and truncates back
  to u32. Rotate (via shift+or), XOR/AND/OR, and left/right shift all
  behave with standard 32-bit truncating semantics with no similar
  issue. Verified against 3 FIPS 180-4/NIST known-answer vectors
  (empty string, "abc", and a 56-byte message whose padding lands
  exactly on a second block — the case a single-block-only
  implementation would get wrong) via `sha256_self_test`, wired into
  the permanent boot self-test suite; full existing battery unchanged
  (0 FAIL/FATAL, 42 PASS with a real SD card), `phase4_milestone.py`
  ×2, USB enumeration both device types, `heap_stress.py`, and
  `power_yank.py` all still clean with the new module present.

  **ChaCha20: DONE (round 44).** `chacha20_block`/
  `chacha20_quarter_round`/`chacha20_encrypt`, RFC 8439's IETF variant
  (96-bit nonce, 32-bit counter). Uses round 42's `wrapping_add`
  builtin directly for the add-rotate-xor quarter round — the exact
  compiler feature that entry's own commit anticipated this reuse for,
  no local workaround needed the way SHA-256 needed before that
  builtin existed. Key/nonce load with no byte-swapping (ChaCha20's
  wire format is little-endian throughout, unlike SHA-256's big-endian
  boundaries — `buf_read_u32`'s native order already matches).
  Verified against RFC 8439 section 2.3.2's own worked block-function
  example plus a 3-block encrypt/decrypt round trip exercising the
  counter-increment loop the single-block KAT alone can't reach.

  **Bignum arithmetic foundation: DONE (round 44).**
  `bignum_add_raw`/`bignum_sub_raw`/`bignum_mul_raw`/`bignum_cmp_raw`
  — arbitrary-width (parameterized by limb count) unsigned integer
  arithmetic on little-endian u32 limbs. Multiply widens each limb
  pair to u64 before multiplying (a u32×u32 product never actually
  overflows u64, verified by construction — the worst-case
  accumulation of an existing limb + partial product + carry sums to
  exactly 2^64-1, still in range) rather than reusing `wrapping_mul`,
  which stays within u32 and would truncate the high half. Verified
  against ground truth computed independently in Python for a 128-bit
  test case, confirmed byte-correct on the host via a standalone
  `vanic` spike before being ported into the kernel — same fast-
  iteration technique SHA-256 established in round 41.

  Both new self-tests verified against the full existing battery
  unchanged (0 FAIL/FATAL, 46 PASS with a real SD card),
  `phase4_milestone.py` ×2, USB enumeration both device types,
  `heap_stress.py`, and `power_yank.py` all clean (this round doesn't
  touch the FS layer at all, so the crash-safety sweep is unaffected
  by design).

  **This item's core scope is now fully closed.** Still open, and
  explicitly a separate, larger sub-effort per this entry's own
  original framing: real EC point arithmetic and modular reduction —
  needed only once a future round actually requires asymmetric crypto
  (e.g. the PKI/secure-boot roadmap items below, both of which
  currently just note this dependency rather than being blocked
  waiting on it).

  **Gap worth flagging now, found while scoping real authentication
  below**: `chacha20_encrypt` is the raw stream cipher only — there is
  no Poly1305 (or any MAC) wired to it anywhere in this codebase, so
  nothing built on it today has real integrity/authentication, only
  confidentiality. Fine for a throwaway demo; NOT fine for media-at-
  rest encryption or anything else meant to resist real tampering — an
  attacker who can modify ciphertext can flip corresponding plaintext
  bits predictably with no detection. Add Poly1305 before shipping
  ChaCha20 for anything that needs to resist an active adversary, not
  just a passive one.

- **AES** — `[L, genuinely harder than it sounds — SKIPPED FOR NOW,
  2026-08-31, revisit if WPA2/WiFi or FIPS-grade TLS actually starts]`
  Explicitly deferred, not abandoned: this item's own two reasons to
  want AES (below) are both about OTHER, currently-inactive roadmap
  items (WPA2's mandatory CCMP mode, and FIPS-constrained TLS
  deployments) — neither is being worked on right now, so there is no
  live consumer for AES at the moment. The one feature that WAS just
  built and could plausibly have used it (media/at-rest encryption,
  round 62) deliberately did NOT need it: ChaCha20 already covers that
  use case per this project's own original design note (at-rest
  encryption isn't a standardized protocol demanding AES/CCMP the way
  WPA2 is). Building a safe, constant-time AES implementation is real,
  non-trivial work (see the cache-timing discussion below) that would
  sit unused until WPA2 or a compliance-constrained TLS client actually
  gets picked up — better to defer it until one of those is real,
  rather than build a primitive speculatively ahead of any actual
  caller. Two real, independent reasons to want it despite round 44's own
  deliberate ChaCha20-over-AES choice, both already implied elsewhere
  in this roadmap but not spelled out until now: (1) WPA2's CCMP mode
  (the WiFi item above) is AES-based by the standard itself, not a
  free choice — no WPA2 client is possible without a real AES
  implementation, full stop; (2) some TLS deployments and compliance
  regimes (FIPS 140-2/3 in particular) mandate AES-GCM cipher suites
  specifically, so a TLS client meant to interoperate broadly (the TLS
  item below) can't rely on ChaCha20-Poly1305 alone even though TLS
  1.3 itself permits it. **The real difficulty is NOT the algorithm
  itself** (AES's substitution-permutation network is well-documented
  and no harder to port than ChaCha20 was) **— it's doing it safely on
  ARMv6.** This core has no AES-NI hardware acceleration, and a naive
  table-based software AES (the obvious first implementation) leaks
  its key through cache-timing side-channels — a well-documented,
  practical attack class, not a theoretical one (this is exactly
  round 44's own original reason for choosing ChaCha20 instead). A
  safe implementation needs either a bitsliced/constant-time
  formulation or a T-table approach with real cache-timing mitigations
  (constant-time table lookups, or precomputed/cache-resident tables
  with careful access patterns) — genuinely harder to get right than
  the cipher's own math, and getting it wrong produces something worse
  than not having AES at all (a false sense of security). Needs a real
  spike specifically probing vani's own suitability for constant-time
  bit manipulation at this level (same discipline round 41's SHA-256
  entry used) before committing to a full build.

- **TLS** — `[XL, several rounds — SKIPPED FOR NOW, 2026-08-31, same
  reason as AES: genuinely blocked on multiple prerequisites below,
  none of which are being worked on right now]`
  A real TLS 1.3 client needs, at minimum: (1) asymmetric key exchange
  (ECDHE) — blocked on the EC point arithmetic/modular reduction this
  roadmap's own crypto-foundation entry already flags as not yet built
  (needed for PKI too, not a new dependency); (2) an AEAD cipher —
  either ChaCha20-Poly1305 (needs Poly1305 above, smaller lift) or
  AES-GCM (needs the AES item above AND a GCM mode on top of it,
  larger lift) — TLS 1.3 permits either, so this is a real, explicit
  choice to make, not a default to assume; (3) certificate validation
  — full X.509/ASN.1 DER parsing and CA chain-of-trust validation is
  the PKI item below in its own right, a large, historically bug-prone
  undertaking on its own. **A materially smaller, realistic first
  target**: TLS 1.3 with raw public keys (RFC 7250) instead of X.509 —
  pin a known server key directly, skip certificate parsing and CA
  validation entirely. This turns "TLS" from "needs PKI" into "needs
  ECDHE + an AEAD," a meaningfully smaller and more honest first
  increment, matching this roadmap's own established pattern of
  finding the smallest real version of a large ask (see PKI's own
  "raw public-key trust" note below, which this reuses directly) —
  full X.509-validated TLS is a separate, later step after that, not
  a package deal. Even the smaller version needs the handshake state
  machine itself built (comparable in scope to this project's own TCP
  state machine, but for TLS's own record/handshake layer) — this is
  genuinely not close to ready to start; sequence it after the crypto
  prerequisites above exist.

- **Real authentication (password-protected `su` + `passwd`)** —
  `[DONE, round 61, 2026-08-30]`
  `su <uid> <gid>` used to switch identity completely unconditionally
  (its own comment said so outright: built only so self-tests could
  exercise permission enforcement). Now genuinely gated: a `passwd
  <uid> <new_password>` command stores a fresh salt + PBKDF2-HMAC-
  SHA256 output (never the password itself) in a new 8-slot user
  table (`boot/auth_state.S`); `su <uid> <gid> [password]` requires
  and verifies it whenever the target uid has ever had one set.

  **The 3 open design forks, resolved explicitly**:
  1. **Scope: gate `su` only** (not a full boot-time login flow) — the
     smaller change; root itself stays unauthenticated at boot, only
     switching AWAY from wherever a session starts is protected. A uid
     that has NEVER had a password configured keeps the exact original
     unconditional behavior — deliberate backward compatibility, not
     an oversight.
  2. **Salt = a monotonic nonce (`auth_salt_nonce_next`) mixed with
     `tick_count` and the uid itself** — honestly non-cryptographic
     (same class of limitation as the DHCP client's own tick-based
     xid), but salts only need to be unique, not secret, and this
     guarantees uniqueness even across two `passwd` calls landing in
     the same tick.
  3. **Corrected, not just resolved**: the original scoping note's
     premise — "the UART RX IRQ handler echoes every typed character
     back" — was checked against the actual code while implementing
     this and found to be **inaccurate**. `irq_dispatch`'s own UART-RX
     branch only calls `shell_rx_push_char` (buffers the byte) and
     never calls `uart_putc`/`uart_putc_nonblocking` at all; no
     hardware UART loopback is configured either. **This shell does
     not echo anything typed, for any command, today.** A typed
     password is therefore not already leaking into the UART stream —
     the real, still-open gap is the opposite one: normal typing gets
     no visual feedback either. Not fixed here (out of scope for
     authentication specifically); if a real echo feature is ever
     added for usability, it will need its own password-mode
     suppression at that point, not before.

  **Cryptography**: `hmac_sha256`/`pbkdf2_hmac_sha256` (RFC 2104 /
  RFC 8018, specialized to the dkLen==hLen==32 single-block case) are
  new primitives built on round 41's SHA-256, each with on-target
  KATs (`hmac_sha256_self_test`/`pbkdf2_hmac_sha256_self_test`,
  independently verified against Python's `hmac`/`hashlib` before
  writing either test) plus a host-harness ASAN/UBSAN twin
  (`test_hmac_pbkdf2_boundaries`).

  **A real, separate, NOT-YET-ROOT-CAUSED scheduler/context-switch bug
  was found while tuning the iteration count** — see the new "Long-
  running synchronous computation stalls permanently" entry
  immediately below. Its practical consequence here: the PBKDF2
  iteration count (`pbkdf2_auth_iterations`) had to be set to **200**,
  measured directly to reliably complete in ~1s from the live shell —
  far below any real password-hashing guidance (OWASP's current
  minimum is 600,000+) and offering only token resistance to offline
  brute-forcing of a stolen salt+hash. This is an honest, tracked
  security gap, not a considered tradeoff — raise it once the
  underlying bug is fixed.

  **Also resolved along the way, not deferred**: failed-attempt rate
  limiting (3 strikes locks an account for 20 ticks, confirmed live to
  correctly reject even a CORRECT password while locked) and a small
  representative weak-password blocklist (NIST SP 800-63B: length over
  complexity, no forced rotation). `passwd` may only be run by root or
  by the uid itself. Live-verified end to end: weak-password rejection,
  password set, wrong-password rejection, correct-password acceptance,
  an unconfigured uid's unconditional `su` preserved, 3-strike lockout,
  lockout correctly blocking even the right password, and root setting
  a different uid's password — all 14 checks in one live run matched
  exactly.

- **Long-running synchronous computation crashes into a silent runtime
  trap under the real scheduler** — `[found round 61, investigated
  further 2026-08-30, STILL NOT FULLY ROOT-CAUSED — high priority]`
  Found while tuning real authentication's own PBKDF2 iteration count.
  A synchronous, non-yielding loop (no `task_sleep_ticks` calls) run
  from the interactive shell (`task_f`), once it survives enough timer
  ticks under the real post-`start_multitasking` scheduler, reliably
  **stops making progress permanently partway through**. The identical
  loop body completes correctly and quickly when run at boot, before
  `start_multitasking` — single-threaded, no interrupts enabled yet.

  **What "stalls permanently" actually turned out to mean** (found via
  a real fix, not further guessing): `boot/rpi1/runtime_stubs.c`'s
  `dprintf()` — the backing implementation vani's own compiler-inserted
  runtime safety traps (`__intent_trap`: array-bounds check,
  checked-arithmetic overflow, division by zero, shift-range, and
  custom `assert "msg"` failures) call before `exit()` — was a total
  no-op. This meant **every** occurrence of **any** compiler-inserted
  trap anywhere in this codebase looked exactly like an unexplained
  permanent freeze (the CPU silently spins forever in `exit()`'s own
  `while(1){}`, with IRQs still enabled so every *other* task keeps
  running normally the whole time) instead of a diagnosable panic with
  a real message. `dprintf()` is now wired to real raw-MMIO UART output
  (matching `dhruva_oom_puts`'s own "must work even from a
  possibly-corrupted state" reasoning) and supports `%s`/`%d`/`%ld`/
  `%lld` — the only specifier shapes vani's LLVM backend ever emits.
  This is a genuine, permanent, project-wide diagnostics improvement,
  independent of whatever specific bug triggers a trap next.

  With that fix in place, the actual panic text is now visible:
  **`"shift amount out of range"`** fires (with `task_f`'s stock
  16384-byte stack) once the PBKDF2 loop survives roughly 500+
  iterations; at a higher iteration count (10000) a **Data Abort**
  (section permission fault) was observed instead, faulting inside the
  `buf_write_u32` family with an implausibly low target address —
  consistent with a corrupted pointer or shift-amount argument, not a
  logic error in the HMAC/PBKDF2/SHA-256 arithmetic itself (every
  literal shift amount in `sha256_rotr32`'s callers, ChaCha20's
  rotate, etc. is a compile-time constant in the 3–19 range; only
  `sha256_rotr32`'s own `n` *parameter* is a genuine runtime value,
  always passed a safe literal by every caller).

  **Ruled out, not just suspected**: simple priority starvation (a
  `dhruva_prio_lock(0)` ceiling boost made no reliable difference);
  argument corruption (`iterations`/`password_len`/`salt_len` all
  verified correct at entry and stayed correct); a scheduler
  malfunction (GDB-based `tick_count`/`current_task` logging over 30+
  seconds proved the scheduler and timer IRQ keep working perfectly
  normally — `task_f` legitimately keeps being `current_task` the
  whole time, it just stops executing new instructions). **Also now
  ruled out**: plain stack-overflow-with-insufficient-headroom as the
  sole/complete root cause. `task_f`'s real stack was experimentally
  raised from its stock 16384 bytes all the way to 131072 (8x) —
  `passwd` at 5000 iterations then succeeded cleanly with zero crash,
  but the exact same build crashed again (a genuine `FATAL`, confirmed
  by this session's own `dprintf` fix, not just "still running") at
  10000 iterations. A real, complete stack-depth fix would make the
  crash disappear at some finite stack size, not relocate it to a
  higher iteration count — so this is most likely a **probabilistic,
  IRQ-timing-dependent corruption** of some live value (a spilled
  shift-amount argument or scratch pointer), whose odds of occurring
  rise with the number of timer ticks the computation survives, not a
  fixed threshold tied to either iteration count or stack depth alone.
  (Reverted the experimental 131072-byte stack back to the stock 16384
  — it is not a proven fix and would otherwise permanently cost half
  the system's 256KB heap for no confirmed benefit.)

  Empirically bounded, not fully root-caused: 200 iterations reliably
  completes in ~1 real second and is the only value measured safe
  across every attempt so far (this is why `pbkdf2_auth_iterations()`
  still returns 200, not a stronger value).

  **Round 62c (2026-08-31) follow-up investigation — deepened further,
  still not fully root-caused.** Several concrete hypotheses were
  checked directly against evidence (not just reasoned about) and
  RULED OUT this round:
  - **VFP/FPU register corruption** (ARM1176JZF-S has a real VFP unit,
    and `kernel_main.vani` compiles through `llc` with no explicit
    `-float-abi`/`-mattr` override) — checked the actual linked
    `dhruva.elf` disassembly directly: zero VFP instructions anywhere
    in the final binary. The only `f64`-using code is vani's own
    dead statistics/formatting runtime helpers (`intent_f64_normal_
    pdf`, `intent_f64_to_str`, etc., each already correctly `vpush`/
    `vpop`-bracketed even if reachable), and `--gc-sections` strips
    them entirely since nothing in this codebase's real boot path
    calls them. `irq_entry.S` never saving VFP state is therefore
    moot — nothing here ever puts a live value there.
  - **Heap allocator race** — `dhruva_alloc_bytes` (`runtime_stubs.c`)
    already disables IRQs (`cpsid i`/`msr cpsr_c`) around its entire
    bump-pointer critical section (round 45 hardening); re-read
    directly, confirmed correct.
  - **A new AAPCS callee-saved-register violation** in this round's own
    new hand-written asm (`media_crypto_state.S`, `fault_inject_
    state.S`) — both re-read directly: neither touches r4-r11 at all,
    only r0/r1, so round 53's callee-saved-register bug class does not
    apply here.
  - **Per-iteration-growing stack usage in PBKDF2 itself** —
    `pbkdf2_hmac_sha256`'s loop re-uses fixed, persistent scratch
    pointers (`pbkdf2_u_ptr`/`pbkdf2_t_ptr`) every iteration, no
    recursion, no per-iteration `dhruva_alloc_bytes` or stack-growing
    pattern — re-read directly, ruled out.

  **New live evidence gathered this round**: `boot/rpi1/vectors.S`'s
  `fault_data_abort` handler previously only reported DFAR/DFSR/PC/
  `current_task` — by the time it reads those (the `mrc` reads
  themselves clobber r0/r1), the ORIGINAL faulting instruction's own
  operand registers were already gone. Fixed **permanently** (real,
  useful diagnostic improvement, not reverted) by stashing r0-r3 into
  r4-r7 before the `mrc` reads (Abort mode doesn't bank r0-r12, so
  these are genuinely the interrupted instruction's live values), and
  `abort_report_data` (`kernel_main.vani`) now prints all four plus
  `context_switch_count`/`irq_count`. Live-reproduced the crash twice
  with this in place (temporarily raising `pbkdf2_auth_iterations()`
  to 1000 for the reproduction runs only, reverted after):
  - Run 1: `pc=00008928` (`buf_write_u32`: `str r2,[r0,r1]`),
    `addr=00000034`, `r0=00000000 r1=00000034` — base pointer read
    back as EXACTLY NULL, offset (0x34 = a plausible SHA-256
    message-schedule-array index×4) intact.
  - Run 2: `pc=00008934` (`buf_read_u32`: `ldr r0,[r0,r1]`),
    `addr=8AB40387`, `r0=8AB40337 r1=00000050` — base pointer read
    back as **wild, uninitialized-looking garbage** (~2.3GB, nowhere
    near this image's <2MB writable region — not a corrupted-but-
    recognizable heap/stack address), offset (0x50, again a plausible
    small array index×4) again intact. `ctxsw=174 irqs=42` at the
    moment of this fault — plenty of real scheduling activity
    happened first, not an immediate/early failure.

  Both crashes independently land on the SAME accessor family
  (`buf_read_u32`/`buf_write_u32`, `dharafs_buf.S`) with the SAME
  pattern: the **base-pointer argument** specifically is what's
  corrupted (once to exactly 0, once to unrelated garbage), while the
  **offset argument survives intact** both times. `buf_read_u32`/
  `buf_write_u32` themselves are single-instruction leaf functions
  (re-confirmed: `ldr`/`str r_,[r0,r1]` then return, no r4-r11 usage)
  — they cannot corrupt their own incoming r0, so whatever's happening
  corrupts the CALLER's copy of the `w`/`h`/`k` scratch-buffer pointer
  (`sha256_compress`'s own locals) between when it was last known-good
  and this particular call, most likely via a spilled stack slot given
  how many live values `sha256_compress`'s two 64-round loops carry
  simultaneously (LLVM almost certainly can't keep all of `w`, `h`,
  `k`, `a`-through-`hh`, and the round temporaries in registers at
  once). This is genuine forward progress (a real, reproducible,
  register-level signature, not just a symptom description) but still
  NOT a full root cause — pinning the exact corrupting write would
  need instruction-level tracing (a real, actually-stopping GDB
  breakpoint or QEMU single-step/watchpoint on the specific stack
  slot), which this round did not attempt again given the SAME GDB
  breakpoint-acceptance-but-never-fires tooling gap round 61 already
  hit and documented below was never itself resolved.

  **Round 62d (2026-08-31) same-day follow-up — GDB tooling gap
  SOLVED, mechanism narrowed further, one strong but not-yet-proven
  new lead.**

  **The GDB "breakpoint accepted but never fires" gap (round 60/61) is
  now understood and resolved.** Every prior attempt was a *post-hoc
  attach* — connecting to an already-booted, already-running guest.
  By that point round 38's own MMU/W^X hardening has already marked
  `.text` read+execute-ONLY, so GDB's own memory write to plant a
  software breakpoint opcode is silently denied — the command reports
  success, but the byte is never actually patched into memory, so it
  never fires. Fix: launch QEMU already halted (`-S`) and set
  breakpoints (and `continue`) BEFORE the first instruction ever runs
  — `.text` is still writable at that point, and once inserted the
  breakpoint opcode is already baked into the instruction stream
  regardless of what W^X does afterward. Verified directly: a plain
  `break fn_sha256_compress` + `continue` from a `-S`-halted session
  stopped cleanly. **Reusable technique for any future Dhruva GDB
  session on this codebase.**

  A software breakpoint on `buf_read_u32`/`buf_write_u32` themselves
  (even conditional, e.g. `if $r0 == 0`) is USELESS in practice for
  this bug — those functions are called from inside SHA-256's own
  64-round compression loop, hundreds of thousands of times over a
  1000-iteration PBKDF2 run, and each hit costs a full GDB
  stop/evaluate/resume remote round trip. Under that overhead the
  guest never got anywhere near its normal failure point within a
  150s budget. **A much rarer, well-chosen breakpoint location is
  required** — see below.

  Re-derived `sha256_compress`'s own register discipline directly
  from its disassembly (not assumed): `w` lives in **r8** and `k`
  lives in **r11 (fp)** for the function's ENTIRE execution (loaded
  once from the caller's stack-passed args at entry, never reloaded
  or spilled again) — both AAPCS callee-saved, both correctly included
  in `irq_entry.S`'s own `stmdb sp!, {r0-r12, lr}` save. Set a
  **surgical** conditional breakpoint instead, at `irq_entry.S`'s own
  final restore instruction (`ldmia sp!, {r0-r12, lr}`, the ONE place
  every task resume — timer-tick-driven or not — passes through),
  conditioned on `current_task == 5` (SHELL/task_f) AND the about-to-
  be-restored r8/r11 stack slots already looking corrupted (0 or
  implausibly large). This location is hit only ~dozens of times per
  run (once per real timer tick while task_f happens to be current),
  not hundreds of thousands — cheap enough to run at near-native
  speed under GDB.

  **Result: this breakpoint never fired across a full run that still
  crashed with the exact same signature as before** (`buf_read_u32`,
  wild-garbage base pointer, `ctxsw=174 irqs=42` — deterministically
  IDENTICAL counts to an earlier independent, non-GDB session's own
  crash, suggesting this bug is far more deterministic given a fixed
  iteration count than "probabilistic IRQ timing" implied). This is a
  real, meaningful negative result: **the corruption is never present
  in ANY saved/restored IRQ context frame for task_f, at any point
  before the crash** — ruling out "an interrupt's save/restore step
  corrupts r8/r11" as the mechanism. Whatever corrupts these registers
  does so WITHOUT ever going through a context-switch boundary at all,
  which points toward either a genuine compiler-codegen defect in one
  of the hot per-round helper callees, or corruption via a wild
  pointer write from elsewhere entirely.

  **New, suggestive but NOT yet proven lead**: noticed `"GC:
  compaction pass"` (task_e's periodic, REAL-SD-I/O background
  compaction) printed immediately before the FATAL line in every
  crash captured this session, across independent runs. Round 62's
  own separate SD-boot bug already proved real SD I/O has SOME
  genuine memory-safety issue elsewhere in this codebase. Tested
  directly: with `task_e`'s `dharafs_compact`/`dharafs_read` calls
  temporarily disabled (task_e still runs and sleeps on schedule, just
  skips the real I/O), `su` with 1000 PBKDF2 iterations completed
  CLEANLY twice in a row (confirmed via an unambiguous, cursor-
  anchored "ok" match, not a guess) with zero crashes. However, a
  THIRD attempt under the same GC-disabled build also crashed — but
  that attempt was confounded by the test harness itself retrying a
  dropped `passwd` command multiple times in quick succession, which
  may have caused genuine command-dispatch reentrancy on task_f (an
  artifact of the test script, not necessarily the original bug's own
  mechanism) — so this data point doesn't cleanly count against the
  hypothesis, but doesn't confirm it either. **Net: 2 clean, 
  unconfounded no-crash completions with GC's real SD I/O disabled,
  0 clean crashes under that condition, vs. 3 independent crashes
  with GC enabled across this session — suggestive of real SD I/O as
  a shared root cause with round 62's own SD-boot bug, but the sample
  size is too small and one run too confounded to call this proven.**

  **Round 62e (2026-08-31), same-day follow-up — isolated which SD
  operation, with a cleaner (no-retry) harness this time.** Split
  `task_e`'s periodic pass into two independently-tested variants:

  - **Variant A: `dharafs_read` alone** (compact disabled) — 6
    attempts, 3 clean full completions (`su`'s own "ok" confirmed via
    an unambiguous cursor-anchored match), 1 crash (same signature:
    `buf_write_u32`, `current_task=5`), 2 inconclusive (command never
    confirmed delivered, discarded rather than retried). **`dharafs_
    read` alone is a sufficient trigger**, at roughly the same ~20-30%
    rate round 62's own bisection already found for plain
    `sdhost_read_block` calls.
  - **Variant B: `dharafs_compact` alone** (read disabled) — 8
    attempts, 6 clean completions/no-crash, 0 crashes, 2 inconclusive
    (killed by the outer test-runner timeout before a decisive
    signal, not evidence either way). No crash observed in this
    sample, though `dharafs_compact` also does real reads internally
    as part of its own log-scan logic, so "compact is safe" is NOT
    established — only that this small sample didn't hit it.

  This converges cleanly with round 62's own independent finding
  (bisected entirely separately, months of investigation apart):
  **`dharafs_read`'s underlying real SD block reads are a confirmed,
  reproducible trigger for both this bug and round 62's own SD-boot
  corruption bug.** Given the same triggering operation, the same
  general symptom shape (a live pointer/register silently corrupted,
  surfacing much later as a crash somewhere unrelated), and the same
  intermittent ~20-30%-ish rate, **these are very likely the same
  underlying root cause**, not two separate bugs — though the EXACT
  mechanism inside `dharafs_read`/`sdhost_read_block` that causes the
  corruption is still not identified.

  Stopped here deliberately (a bounded, scoped follow-up, not an
  open-ended chase) — this is a solid, decisive narrowing. All
  temporary diagnostic changes reverted; full regression battery
  re-verified green.

  **Round 62f (2026-08-31), same-day, escalated per explicit user
  instruction ("resolving this is imperative") — deepened
  substantially further, several real findings, still NOT fully
  root-caused.**

  Added cheap, always-on, silent-unless-bad checkpoints directly
  inside `sha256_compress`'s own three loops (a new `sha256_compress_
  check` helper called at every loop iteration, immediately adjacent
  to each `buf_read_u32`/`buf_write_u32` call — closing the
  window to nothing), reading `w`/`k`'s CURRENT register content via
  a tiny new `ptr_raw_value` C helper (vani has no cast from `mut ref
  i64` to `i64`, a deliberate no-raw-pointer-escape-hatch design
  choice, so this was needed to inspect a reference's raw address
  from vani code at all). Runs at full native speed, no GDB involved.

  **Ruled out a stack leak/drift directly and conclusively**: added a
  `get_sp_raw()` C helper and printed `sp` every 25 PBKDF2 iterations.
  Across 500+ real iterations in a healthy run, `sp` was **byte-for-
  byte IDENTICAL** every single time — zero drift. This rules out any
  theory involving accumulating/leaking stack depth across PBKDF2
  iterations.

  **Live-caught the corruption again, multiple times, with checkpoints
  immediately adjacent to the crash site** — and found something more
  severe than previously understood: even a checkpoint sitting
  literally one loop iteration's worth of pure-ALU code away from the
  crashing call already sees corrupted values, AND — critically — the
  corruption isn't limited to `w`/`k`. The checkpoint's OWN `tag`
  argument (a compile-time-constant immediate, e.g. `mov r0, #3` —
  something that cannot legitimately vary at all) and `i` (a plain
  loop counter) both came back as wild, nonsensical 64-bit values on
  every capture (e.g. `tag=7685137550204961520 i=4912982830340592507`).
  Every one of these captures was immediately followed by a genuine
  **Prefetch Abort at a wild PC** (e.g. `address 1C5B6A8A`), not
  another Data Abort. **This is much more consistent with genuine
  control-flow / stack-smash corruption (a corrupted return address or
  computed branch target) than with a single mis-set pointer variable**
  — a single-variable-corruption theory doesn't explain a compile-time
  constant reading back wrong.

  **A real, direct test of the ABI-argument-passing hypothesis this
  finding initially suggested**: `sha256_compress_check`'s own
  signature (`i64, ref, ref, i64` — a trailing stack-passed `i64`
  after two single-register `ref` args) matches this project's own
  historical AAPCS-gotcha pattern exactly (see `sdhost_drain_fifo_
  to_buffer`'s own comment). Built a minimal, standalone, host-
  compiled repro of the exact same argument shape (`vanic emit
  --backend=llvm` + `llc -mtriple=armv6-none-eabi -mcpu=arm1176jzf-s`,
  no QEMU/scheduler/timing involved at all) and inspected the raw
  disassembly directly: **the compiler-generated code is correct** —
  `w`/`k` (r2/r3) are properly saved into other registers before the
  stack-passed `i` gets loaded into r2/r3, exactly as AAPCS requires.
  This specific vani-compiler ABI hypothesis is RULED OUT by direct
  evidence, not just re-reasoned about.

  **A genuinely surprising, important negative-turned-nuanced result**:
  reproduced the exact same corruption+Prefetch-Abort signature during
  the **single-threaded, interrupt-free boot-time PBKDF2 self-test**
  (confirmed via the crash's own captured `sp` value matching the boot
  stack's address range, not any task's dedicated stack — and directly
  confirmed by re-reading `kernel_main`'s own boot sequence: `enable_
  irqs()` is **never called** anywhere in this codebase; the code's own
  comment states interrupts stay masked for all of `kernel_main`'s
  setup and only turn on once `start_multitasking` first resumes a
  task). This single capture, on its own, would have completely ruled
  out any IRQ/interrupt-timing-dependent theory. However, a follow-up
  sweep of 30 fresh, otherwise-identical boots (with a real SD drive
  attached, matching the crashing run's own conditions, each capturing
  the FULL boot sequence including the self-test) found **zero**
  further hits. **Net conclusion: the corruption can occur with zero
  interrupts and zero concurrency involved at all, but at a much lower
  rate (roughly 1-in-30-or-rarer) than during live multitasking
  (~20-30%)**. This is a real, evidence-based correction to the
  working hypothesis that has stood since round 61: IRQ/scheduler
  timing is NOT the root mechanism (proven by the interrupt-free
  capture), but it does dramatically amplify whatever the true
  mechanism is — the amplification factor itself is now a real,
  useful clue, not yet explained.

  All temporary diagnostic changes (checkpoints, `ptr_raw_value`,
  `get_sp_raw`, the 1000-iteration bump) reverted; `git diff` confirmed
  clean before rebuilding; full regression battery re-verified green.

  Candidate next steps for a dedicated future round, in priority
  order: (1) given the corruption now looks like genuine stack-
  smashing/control-flow corruption rather than a single bad pointer,
  audit every function in the `sha256`/`hmac`/`pbkdf2` call chain (and
  `dharafs_read`/`sdhost_read_block`, per round 62e's own finding) for
  a genuine buffer-bounds violation — a fixed-size local buffer
  written past its own bound would explain corrupting an adjacent
  saved return address exactly this way, and hasn't been specifically
  audited with THIS theory in mind yet; (2) use the now-working
  `-S`-halted GDB technique with a **hardware watchpoint on the return
  address slot** of whichever stack frame is suspected, rather than
  register content (register watches require slow single-stepping;
  return-address slots are genuine memory addresses QEMU can watch at
  full speed); (3) since pure single-threaded reproduction is possible
  but rare (~1/30), a MUCH larger single-threaded boot sweep (100+
  boots) would help characterize whether ANY residual concurrency-like
  variance still exists in that path (real QEMU/hardware timing
  variance in the SD polling loop is one remaining candidate even with
  interrupts masked) or whether it's genuinely a rare, input-
  independent bug that would eventually be catchable via that route
  alone, given enough attempts. This is a genuine reliability concern
  beyond just authentication: ANY future feature needing a long
  synchronous computation from a task, or any code path sharing memory
  near an active `dharafs_read` call, will hit the same wall.

  **Round 63 (2026-08-31) follow-up — static audit found no smoking
  gun; validated a live watchpoint technique but got blocked on a
  session-local input-delivery tooling gap, not a guest regression.**
  Per round 62f's candidate step (1): audited every function in the
  `sha256`/`hmac`/`pbkdf2` call chain, plus `dharafs_buf.S`,
  `auth_state.S`'s scratch accessors, and `sdcard_state.S`'s FIFO
  transfer helpers, specifically for a fixed-size-buffer bounds
  violation that could smash an adjacent saved return address.
  Re-derived `sha256_compress`'s own freshly-built ARM disassembly
  directly (not from an earlier build): its stack frame allocates 132
  bytes and every local store/load offset used stays at or below 124 —
  no overlap into the `push {r4-r11,lr}` save area above it. Every
  hand-written asm helper in the chain either touches only r0-r3 (no
  save/restore needed) or correctly brackets its one or two scratch
  registers with `push`/`pop` (`sdhost_drain_fifo_to_buffer`/
  `sdhost_fill_fifo_from_buffer`, `test_fill_pattern`,
  `test_compare_buffers`) — no AAPCS callee-saved-register violation
  anywhere in this specific call graph. `dharafs_sd_scratch` is exactly
  512 bytes and the FIFO transfer writes exactly 128 words into it, an
  exact fit. `password_len` (the one path that could reach `sha256_
  hash`'s own 4096-byte-capped `padded` scratch through HMAC's
  `key_len > 64` branch) is bounded by the shell's own line length in
  every real caller, nowhere near that cap. **No buffer-bounds
  violation found by static inspection** — candidate step (1) is now
  believed exhausted without a code-level explanation.

  Built and validated candidate step (2): a GDB hardware watchpoint on
  `sha256_compress`'s own saved-`lr` stack slot (a fixed, deterministic
  address given this project's own already-proven stack-address
  determinism), armed only while a specific invocation is actually
  live (enabled at the function's own prologue breakpoint, disabled at
  its one epilogue) rather than left on permanently. This scoping
  turned out to be necessary, not optional: a first, unscoped dry run
  immediately "caught" a completely legitimate write from `sha256_
  write_be32` to that same address — ordinary stack-slot reuse by a
  later, unrelated function after `sha256_compress` had already
  returned, not a bug. The scoped version is believed sound.

  Ran BOTH of the boot-path's own single-threaded (interrupt-masked)
  PBKDF2 computations through this instrumentation to completion —
  the 4096-iteration self-test KAT and `dharafs_crypto_key_init`'s own
  real 10000-iteration boot-time call (round 62's media-encryption
  feature) — with **zero watchpoint hits across both**. Consistent
  with, not a contradiction of, round 62f's own "rare, ~1/30" single-
  threaded rate finding: two runs at that rate are unsurprising to
  both come back clean.

  **Blocked before reaching the higher-probability concurrent
  condition** (`su`/`passwd` racing task_e's live background `dharafs_
  read`/GC pass, round 62e/f's own ~20-30% trigger): driving the
  interactive shell via `tmux send-keys` into the QEMU pty reliably
  failed to deliver any command to task_f, across many attempts (plain
  send, literal `\r`, char-by-char with per-character delay). **Not a
  guest regression** — confirmed two ways: (1) QEMU's own `-nographic`
  stdio multiplexer DID receive and correctly act on input over the
  exact same channel (`Ctrl-A c` reliably toggled into/out of the QEMU
  monitor, banner and all); (2) `test/phase4_milestone.py`, run
  independently right after, drove the same shell perfectly end-to-end
  (14/14 PASS) using its own proven method (`subprocess.Popen(stdin=
  subprocess.PIPE)` + `write()`+`flush()`), not `tmux send-keys`/a pty.
  **Actionable lesson for next time**: script any future interactive-
  shell-plus-GDB session using `Popen(stdin=PIPE)` for the serial
  side (GDB attaches separately over the `-s` TCP port regardless, so
  the two don't conflict) — a pty-based `tmux send-keys` approach is
  not reliable for this project's own QEMU/nographic setup, for a
  reason not yet root-caused itself (out of scope for the auth-bug
  investigation this round).

  All temporary diagnostic changes reverted (`pbkdf2_auth_iterations`
  back to 200, confirmed via `git diff` before rebuilding); full
  regression battery re-verified green (`qemu_run` PASS, `phase4_
  milestone` 14/14, `host_harness` 315/315 ASAN/UBSAN clean). Bug
  remains NOT root-caused.

  **Round 64 (2026-09-01) follow-up — pursued round 63's own candidate
  next step, blocked entirely by host-level resource contention, not
  by anything in this project.** Redesigned the GDB script to GATE the
  expensive `sha256_compress` entry/exit breakpoints (`disable`d at
  creation, only `enable`d once a `shell_dispatch_passwd`/`shell_
  dispatch_su` entry breakpoint fires), so boot's own self-tests and
  `dharafs_crypto_key_init`'s 10000-iteration call run un-instrumented
  — validated this design actually works (a live run cleared SHA-256/
  HMAC/PBKDF2(4096-iter KAT)/ChaCha20 self-tests inside a 900s window,
  visibly faster than round 63's fully-instrumented equivalent). Built
  a small Python driver using `Popen(stdin=PIPE)` for the serial side
  (per round 63's own actionable lesson), fixed a real bug found along
  the way (the boot-readiness wait loop didn't distinguish "marker
  found" from "timed out," so a premature timeout would blindly send
  `passwd`/`su` into a guest whose shell didn't exist yet — always a
  no-op, never a real attempt).

  **Discovered the actual blocker**: this host runs a persistent,
  intentional background service (`vani-localfuzz`'s own Ollama-served
  local model, `~106%` CPU continuously, unrelated to this session —
  see [[feedback_local_ml_model_sandboxing]]/[[reference_vani_localfuzz_autostart]]),
  and load average on this 4-core box sat at 3-5 for this entire round
  — confirmed NOT a rare spike (checked twice, ~20 minutes apart, both
  times elevated). Two consecutive, fully-patient GDB-attached boot
  attempts (15 minutes, then 40 minutes) each failed to even reach a
  working shell — the second made LESS progress (22 lines) than the
  first (67 lines) despite 2.7x more time budget, confirming genuine,
  worsening host contention rather than a fixed, plannable overhead.
  `qemu-system-arm` under `-s -S` GDB attachment appears to have some
  real baseline slowdown even with breakpoints disabled (a native,
  no-GDB boot with the identical real `-drive` image reaches the same
  point in under 20s, confirmed via a fresh `phase4_milestone.py` run
  scoring 14/14 in 96s total including its own 72s of deliberate
  inter-command sleeps) — this compounds badly with real host
  contention, since QEMU's TCG needs consistent, low-latency scheduling
  to stay fast. **Not something to fix in this project** — it's an
  external, load-dependent constraint on when live-GDB sessions here
  are practical, not a code-level bug.

  **One apparent lead ruled out as a self-inflicted test-harness
  artifact, not a new finding**: the DharaFS permission-model self-test
  (`dharafs_permissions_self_test`, line ~3710) printed `FAIL` instead
  of its normal `PASS` in BOTH of the two attempts above, at the exact
  same line. Investigated seriously since this looked like it could be
  the corruption bug surfacing as a silent wrong-result rather than a
  crash — a much more concerning failure mode. **Traced to a mundane
  cause instead**: unlike `phase4_milestone.py` (which truncates a
  fresh SD image every single run), this round's driver script reused
  ONE `sd.img` path across attempts — so attempt 2 booted against
  filesystem state already left behind by attempt 1's own run (in
  particular, attempt 1's `dharafs_chmod("/perm/rootfile", 438)` step,
  which the self-test itself performs as part of its own sequence,
  permanently loosens that file's mode to world-writable on-disk,
  making the SAME test's own "0o644 denies non-root write" assertion
  fail on any later boot against that same image). Documented here so
  a future round doesn't re-investigate this as a live lead without
  first checking whether its own harness creates a fresh SD image per
  attempt.

  **Same-round follow-up (2026-09-01, later): the host quieted down and
  the fix paid off — a live crash was actually caught, and the
  watchpoint's own SILENCE is itself a real, direct negative result.**
  Fixed the driver to truncate a fresh `sd.img` per attempt (per the
  finding immediately above) and increased the per-command PBKDF2 wait
  budget to 45 minutes (a clean run of 1000 iterations under this
  fine-grained gated instrumentation genuinely costs that much — an
  estimated ~8,000-12,000 GDB stop/evaluate/resume round-trips: entry,
  the watchpoint's own harmless self-trip on `sha256_compress`'s
  legitimate prologue write, and exit, per call). Relaunched during a
  window where `uptime`'s load average had dropped to ~1-2 (down from
  3-5 earlier in the round). Attempt 2's `passwd` command crashed after
  only ~1.5 minutes of computation — the exact same signature every
  prior round has captured: `FATAL: Data Abort at address 80000000
  status=00000005 pc=00008920 current_task=00000005 r0=80000000
  r1=00000000 r2=00000000 r3=00000000 ctxsw=239 irqs=64` (`pc=0x8920`
  is `buf_read_byte`'s own `ldrb r0,[r0,r1]`; `r0`/base-pointer
  corrupted to ~2GB garbage, `r1`/offset intact at 0 — identical shape
  to round 62c's own two independent captures).

  **Critically, the hardware watchpoint on `sha256_compress`'s own
  saved-return-address stack slot never fired at all across this
  entire run, including through the crash.** A hardware watchpoint
  traps on EVERY write to its watched address by construction — there
  is no way for it to silently miss one. Its total silence through a
  run that DID crash is therefore a clean, direct (not inferred)
  negative result: **the corruption is conclusively NOT caused by a
  write to `sha256_compress`'s own return-address slot** — round 62f's
  "stack-smash into a saved return address" hypothesis, at least for
  THIS specific location, is now ruled out by hardware evidence, not
  just by remaining unproven.

  Also did a quick live post-crash inspection (QEMU/GDB were left
  running, spinning harmlessly in `fault_data_abort`'s own halt loop,
  so this cost nothing extra): confirmed `pc=0x8920` disassembles to
  exactly `buf_read_byte`'s single `ldrb` instruction; GDB's own
  backtrace can't unwind past the raw exception-vector entry (no CFI
  there), and by the time of attach `fault_data_abort`'s own code had
  already overwritten r8-r12 for its own purposes, so the ORIGINAL
  crashing frame's `w`/`k`/`h` register contents were no longer
  recoverable live — this needs a breakpoint planted BEFORE the abort
  handler does its own work to be useful, not a look afterward.

  All temporary diagnostic changes reverted (`pbkdf2_auth_iterations`
  back to 200, confirmed via `git diff`); a stray core dump from the
  investigation cleaned up; full regression re-verified (`qemu_run`
  PASS after rebuild). Bug remains NOT root-caused, but the search
  space just got meaningfully smaller.

  **Candidate next steps for a future round, in priority order**:
  (1) since the return-address-slot theory for `sha256_compress`
  itself is now ruled out, the corrupting write must land somewhere
  else — either a DIFFERENT stack slot in the same or a different
  frame in the call chain (`sha256_hash`/`hmac_sha256`/`pbkdf2_
  hmac_sha256`/`shell_dispatch_passwd`), or it isn't a stack-smash at
  all and the earlier "compile-time-constant argument came back wrong"
  evidence (round 62f) needs re-explaining under a different theory;
  (2) a genuinely promising angle for the SAME live-crash-capture
  setup used this round: rather than watching one candidate address,
  add a SECOND gate breakpoint at `fault_data_abort`'s own entry (its
  address is fixed/known) that, when hit, immediately dumps r8-r12
  BEFORE the handler's own code can clobber them — this round's own
  live inspection was too late for exactly that reason; (3) the
  `Popen(stdin=PIPE)` + gated-watchpoint approach itself is proven
  practical now (crash caught in ~1.5 minutes once the host was quiet
  and a real corruption occurred) — future attempts should just spot-
  check `uptime` first, since host load (not the technique) was this
  round's only real time sink.

  **Round 65 (2026-09-01) — FIXED, per the user's explicit "attempt
  other techniques" instruction.** Switched investigative tooling from
  GDB (proven slow/unreliable under this host's own background load in
  every prior round) to QEMU TCG plugins (`qemu-plugin.h`, downloaded
  since no dev package was installed) — near-native-speed in-process
  register/memory tracing, 13-20s per clean attempt vs. GDB's 300s+
  under load. Two defensive fixes already staged from a sub-round
  before this one (`scheduler_pick_next` now saves/restores caller's
  r8-r11; `task_sleep_ticks` now masks interrupts around its own
  critical section, mirroring `dhruva_mutex_lock`'s existing pattern)
  measurably helped but did not fully resolve the bug — a live crash
  still hit on attempt 20 of a verification run.

  That crash's own FATAL diagnostic showed `sha256_h_scratch_get()`
  returning NULL into `sha256_h_init`. Retargeted a memory-write-watch
  plugin at the exact `.bss` scratch-pointer table (`sha256_padded/h/
  k/w_scratch_addr`) and proved nothing writes there at runtime except
  the expected one-time boot init — ruling out a wild memory write
  entirely (a real, hardware-backed negative result, same class of
  evidence as round 64's own watchpoint silence). Bisected the
  `sha256_hash` → `sha256_h_init` call chain with a register trace: r0
  (the `h` pointer) was correct on all 60,060 traced calls right up
  through a *different* crash, ruling out that specific chain too.

  The real pattern: `fn_sha256_compress`'s own disassembly showed it
  loads its `w` message-schedule pointer into **r8 exactly once at
  function entry** and holds it live across its whole ~64-round loop
  body (7 call sites, all via `mov r0,r8`, never reloaded) — confirmed
  via `nm`/`objdump` on the actual built binary, not just source
  reading. Grepped every r8 reference in the function's compiled
  disassembly and found no other write/reuse anywhere in its body,
  ruling out a compiler register-reuse bug internal to the function
  itself. Traced every `buf_read_u32`/`buf_write_u32` call unfiltered
  across a 24-million-call run to an actual crash: the fault was the
  very first anomalous entry in the whole trace, no lead-up, consistent
  with a single rare event (matches that run's own `irqs=8` total) —
  not a periodic/structural bug. Added direct r8 tracing at
  `irq_entry`'s own save point and restore point; manually re-derived
  `irq_entry.S`'s save/relocate/restore byte layout by hand three
  separate times against the actual compiled bytes (matched source
  exactly every time) and found it internally self-consistent on every
  pass — no single corrupting instruction was ever pinned down despite
  this being the most thorough audit of that file across all 65
  rounds.

  **The fix actually applied is defensive, not a pinpointed
  correction**: `sha256_compress` (and `sha256_h_init`, which has the
  identical shape and was itself attempt 20's own crash site) no
  longer take `h`/`w`/`k` as parameters held live in a register across
  the whole function — they now call `sha256_h/w/k_scratch_get()`
  fresh at every single point of use. Whatever the exact register-
  corruption mechanism was, this closes the entire class: no scratch
  pointer this code touches is ever more than a few instructions old
  before its use, matching the reload-immediately-before-use pattern
  the corruption could never be observed defeating in tens of millions
  of traced calls.

  **A first attempt at this fix used `disable_irqs()`/`enable_irqs()`
  bracketing `sha256_compress` instead, and was reverted** — it stalled
  the interactive `passwd`/`su` commands by 10-30x+ (a command that
  normally completes in ~1-2s took 300s+ and still hadn't finished)
  once multitasking was active, for reasons not fully diagnosed (ruled
  out: per-call transition overhead, since widening the mask to cover
  the whole PBKDF2 call instead of each compress call didn't help
  either; the system was confirmed NOT deadlocked — other demo tasks
  kept visibly running throughout). Worth remembering as a cautionary
  data point if interrupt-masking is ever reconsidered as a fix
  strategy here: it has a real, serious performance interaction with
  this scheduler under active multitasking that this round did not get
  to the bottom of.

  **Verification**: 100 consecutive `passwd 0 <pw>` + `su 0 0 <pw>`
  attempts (fresh SD image per attempt, ~1000-iteration diagnostic
  PBKDF2 count), zero crashes — the prior build crashed at attempts 20,
  22, and 23 across three separate runs, so this is decisive (roughly a
  0.6% chance of this outcome if the true crash rate were still what it
  was). Full regression battery re-verified green after the fix:
  `qemu_run.py` PASS, `phase4_milestone.py` 14/14, `host_harness` 315
  PASS/0 FAIL under ASAN/UBSAN, `heap_stress.py` PASS. Diagnostic PBKDF2
  iteration count was already at its production value of 200 by this
  point (confirmed via `git diff` before considering this closed).
  Local-only commit, per this project's own push policy.

- **Packet filtering / iptables-equivalent** — `[DONE, round 60]`
  Single hook point in `netif_recv_frame` (all three backends: CDC-ECM,
  LAN9512, loopback), an 8-rule fixed array (`proto`/`src_ip`+valid/
  `dst_port`+valid/`action`, first-match-wins, `default_policy`
  fallback — `boot/fw_state.S`), `fw add/list/flush/default` shell
  commands (factored into `shell_dispatch_fw` after a real, compiler-
  enforced `#[bounded_stack]` budget failure on `task_f` — the original
  inline version's local bindings pushed a pre-existing unrelated
  worst-case call chain over budget). `filter_self_test()` gives
  exhaustive synthetic coverage (default-alone, specific-rule-vs-
  different-src_ip, proto specificity, first-match-wins ordering,
  port-specific-rule-never-matches-ICMP, non-IPv4 passthrough) plus a
  host-harness ASAN/UBSAN twin (`test_packet_filter` in `host_main.c`).

  **Live-verified over the real CDC-ECM link**, with two honest
  caveats found along the way, neither a packet-filtering bug:
  1. The real USB bulk-OUT transmit occasionally fails transiently
     under this build's now-heavy background scheduling load (rounds
     54/55's mutex/task-creation demos) — a pre-existing category of
     flakiness already noted above under round 56, not something this
     round introduced or needs to fix; the live-verification script
     sends each critical ping twice to not mistake one transient TX
     failure for a filtering bug.
  2. **Found a genuine, separate, unrelated crash** while running the
     live test for long enough — see the new "Long-running crash"
     entry immediately below.

  Across two live runs: the deny rule never once let an ICMP reply
  through (3 attempts total, zero leaks) and a real `reply from
  10.0.2.2 seq=1` was observed after `fw flush` — real confirmation a
  security control governs real off-box traffic, not just synthetic
  self-talk. Outgoing filtering (`netif_send_frame`) remains a natural,
  smaller follow-up, not in this round's scope.

- **Long-running crash: Data Abort at a near-null/wild address after a
  few minutes of pure background activity** — `[ROOT-CAUSED AND FIXED,
  round 60 follow-up, 2026-08-30]`
  Found while live-verifying packet filtering (QEMU runs longer than
  this project's existing regression battery ever holds one continuous
  session, long enough to surface a previously-undiscovered crash).
  **Confirmed unrelated to packet filtering or networking** via an
  isolation run with zero shell commands and, later, zero `usb-net`
  device at all — reproduced identically either way, pointing squarely
  at round 54/55's own `task_create`-based demo tasks (`task_custom_
  demo`, `task_mutex_demo_low/high`).

  **Root cause, confirmed empirically, not just by inspection**: these
  three dynamically-created tasks were each allocated exactly 512
  bytes of stack — matching their own `#[bounded_stack(bytes=512)]`
  compiler-VERIFIED budget with **zero headroom**, unlike every other
  task in this project (`task_a`-`d`: 4096 bytes; `task_e`/`f`: 16384
  bytes — always a generous multiple of the real worst case, never the
  bare verified minimum). A genuine stack overflow into adjacent
  bump-allocated memory explains the observed symptoms exactly: small,
  inconsistent fault addresses across runs (`0x0`, `0x5`, `0x28`,
  `0x40`) consistent with corrupted small values, not one fixed bad
  constant, and (once diagnostic instrumentation was added to print the
  real faulting PC + `current_task`) one crash that clearly involved a
  wild jump into unrelated valid code with a garbage register — exactly
  what corrupted adjacent memory produces, not a single clean bad
  pointer dereference.

  **Proven, not assumed**: deliberately shrinking these same stacks
  further (128 bytes) reproduced the identical crash class in ~60
  seconds instead of 150-550 — a controlled experiment showing "smaller
  stack, faster failure," the clearest possible signature of a real
  margin-dependent stack overflow, independent of what the static
  checker itself reports.

  **Fixed**: raised all three allocations to 4096 bytes (matching every
  other task's own established, long-proven convention) rather than
  trusting the bare statically-verified minimum. Confirmed clean over
  a 550-second continuous soak (the same duration the original 512-byte
  version had failed within, more than once) with the fix in place;
  full regression battery (`phase4_milestone` 14/14, `heap_stress`,
  `host_harness` 289/0, `power_yank` 70/70) all green afterward.

  **A genuine vani-compiler soundness gap found along the way, filed
  and fixed upstream (BUG-233)**: the `#[bounded_stack]` static checker
  silently charged **0 bytes** for any `extern "C"` (hand-written
  assembly) callee — meaning `dhruva_mutex_lock`/`task_sleep_ticks`'s
  own real ~64-byte context-switch-frame cost was completely invisible
  to their callers' own "verified" budgets. Confirmed this was NOT the
  dominant cause of this specific crash (the checker's own honest
  `uart_puts`/`uart_put_i64` chain already exceeded the extern-call
  contribution regardless), but is a real, independent soundness gap
  worth closing — fixed to charge the same conservative
  `FRAME_OVERHEAD_BYTES` (32) every ordinary function's frame already
  uses, strictly more conservative than before (can only raise an
  estimate, never lower one), verified against the full vani-compiler
  test suite with no regressions. Pushed to vani-compiler's `main`.

- **PKI (Public Key Infrastructure)** — `[XL, several rounds beyond
  the crypto foundation above — SKIPPED FOR NOW, 2026-08-31, same
  EC-arithmetic blocker as TLS above]`
  Real PKI means X.509 certificate parsing (a nontrivial ASN.1/DER
  parser, a genuinely large and historically bug-prone piece of code
  in any language) plus chain-of-trust validation against root CAs.
  Depends entirely on the crypto primitives item above (signature
  verification needs working asymmetric crypto first). A realistic
  FIRST increment, if ever started, is raw public-key trust (pin a
  known key, verify a signature against it directly) with no X.509/CA
  chain at all — full X.509 is a separate, much larger step after
  that, not a package deal.

- **Media (at-rest) encryption** — `[DONE, round 62, 2026-08-31]`
  DharaFS block encryption layered on round 44's existing ChaCha20
  stream cipher (no new cipher primitive needed — matches this entry's
  own original scoping note exactly: unlike WPA2/WiFi, at-rest
  encryption isn't a standardized protocol demanding AES/CCMP
  specifically). Key derived once at boot via PBKDF2-HMAC-SHA256 from
  a fixed passphrase (a real, security-appropriate 10000 iterations —
  safe here specifically because this runs single-threaded before
  `start_multitasking`, outside the still-open task_f runtime-trap
  bug's own observed conditions). Nonce = 12 bytes, all zero except
  the low 4 holding `block_num` big-endian — unique per block under a
  fixed key. Hooked in transparently at `dharafs_block_read`/
  `dharafs_block_write` (renamed to `_raw` + a thin wrapper), the
  single backend-agnostic choke point round 36's block-device
  abstraction created — every higher FS layer (checksums, headers,
  journaling, compaction, permissions) keeps operating on plaintext.
  Off by default (`dharafs_crypto_enabled` starts at 0) — every
  existing test keeps running against plaintext blocks unchanged,
  matching round 36's own `dharafs_block_dev` toggle precedent.

  **Honest, deliberate limitation, not an oversight**: because the
  nonce is a pure function of `block_num`, overwriting the SAME block
  twice under the SAME key reuses the SAME keystream — an attacker
  holding two on-disk snapshots of that block can recover
  `plaintext_old XOR plaintext_new` (the classic stream-cipher
  "two-time pad" problem). This is exactly why real full-disk
  encryption normally uses a wide-block tweakable mode (AES-XTS)
  instead of a raw stream cipher. Still real, meaningful protection
  against the simplest and most common threat model (a single
  stolen/lost SD card, one point-in-time snapshot); the gap only
  matters against an attacker who can compare multiple snapshots of
  the same rewritten block over time. **Also still needs Poly1305**
  for integrity (raw ChaCha20 alone gives confidentiality with no
  tamper detection) — not attempted here, tracked as a natural
  follow-up.

  Verified three ways: an on-target self-test (pure in-memory
  transform round trip — deliberately does NOT touch real SD I/O, see
  the SD-timing bug entry directly below for why); a host-harness
  ASAN/UBSAN twin (`test_media_crypto` in `host_main.c`, 8 checks,
  including a real `dharafs_block_write`/`dharafs_block_read`
  round trip against the host's in-memory virtual disk, and confirming
  two different block numbers produce different ciphertext for the
  same plaintext); and a one-time manual live QEMU verification with a
  real attached SD image (write succeeds, on-disk bytes provably
  differ from plaintext, decrypted readback exactly matches — not
  committed as a permanent boot self-test, per the entry below).

- **A real, serious, pre-existing, timing-dependent SD/boot-sequencing
  bug** — `[found round 62, 2026-08-31; FIXED round 65/66,
  2026-09-01 — see round-66 update below]`
  Found live while building media encryption's own self-check: doing
  even ONE extra real SD block read or write during boot — something
  nothing in this codebase had ever done before this feature, since
  every other boot-time SD self-test already existed before it —
  intermittently (~20-30% across repeated live QEMU runs, both for an
  extra read and for an extra write, tested separately) leaves some
  later, unrelated state corrupted. Symptom: a genuine Data Abort
  (NULL buffer, `str r3, [r0], #4` inside `sdhost_drain_fifo_to_buffer`
  with `r0`=0) minutes later, deep inside `task_e`'s own background
  DharaFS compaction (`current_task=4`) — not the extra I/O call
  itself, which always completes and reports success. Confirmed via
  bisection (10+ repeated live runs at each step) that this is
  independent of media encryption's own crypto logic entirely: a
  version of the self-check doing ZERO extra real SD I/O (pure
  in-memory transform only) is 100% reliable across every run (16/16);
  restoring even a single extra `sdhost_read_block` call reintroduces
  the same ~20-30% failure rate. This is most likely the same broad
  "IRQ lands at an unlucky moment corrupts live state" bug class as
  the still-open task_f runtime-trap investigation above, not a
  coincidence — both are real, serious, and NOT YET root-caused.
  **Round 62d/62e update**: this stopped being pure speculation.
  Round 62d found disabling task_e's real SD I/O entirely made the
  task_f bug stop reproducing in 2/2 clean runs; round 62e isolated
  it further — `dharafs_read` alone (independent of `dharafs_compact`)
  is a confirmed, reproducible trigger for the task_f bug, at roughly
  the same intermittent rate this entry's own bisection already found
  for plain `sdhost_read_block` calls. **These two bugs are very
  likely the SAME root cause** (same triggering operation, same
  symptom shape, same rough failure rate) — see that entry's own
  round-62e writeup above for the full evidence. The exact mechanism
  inside `dharafs_read`/`sdhost_read_block` is still not identified.

  Because of this, media encryption's own on-target self-test
  deliberately verifies only the in-memory transform (safe, 100%
  reliable) rather than the real SD-integrated path, on every boot —
  baking a ~20-30%-per-boot destabilization risk into a permanent
  self-test would make the whole system less reliable for every user,
  not just those who enable encryption. The real end-to-end
  integration was instead verified via the host-harness ASAN/UBSAN
  twin (a real host process, no IRQs, no hazard) and a one-time manual
  live QEMU run with a real SD image attached (both confirmed correct
  — see the media encryption entry above).

  Candidate next steps: since this doesn't require the still-elusive
  live GDB breakpoint the task_f investigation got stuck on (the
  crash's own manifestation — a Data Abort with a real faulting PC, not
  a silent `exit()` spin — should symbolize directly), start there;
  bisect whether the trigger is specifically the extra SD *command*
  itself (interrupt landing mid-transaction) versus merely the extra
  wall-clock time it adds during boot's own IRQ-enabled window;
  check whether this is the SAME root cause as the task_f trap bug or
  a genuinely separate one once either gets a real backtrace.

  **Round 66 (2026-09-01) update — FIXED, confirmed as a side effect
  of round 65's task_f fix, exactly as this entry's own round-62d/62e
  speculation predicted.** Re-added the original trigger as a temporary
  diagnostic (one extra `sdhost_read_block` call inside
  `dharafs_encryption_self_check`, matching round 62's own bisection)
  and ran 20 consecutive full boots, watching up to 6 minutes each for
  the delayed Data Abort inside `task_e`'s compaction — the same
  reproduction shape round 62 originally used. **Zero crashes across
  all 20 attempts.** Against the documented ~20-30% per-boot rate, 20
  consecutive clean boots has roughly a 0.1-1% chance of happening by
  luck if the bug were still present at its old rate — decisive.
  Confirmed the repro setup itself was live and correct throughout (the
  extra read always completed and reported success, matching this
  entry's own original description, and `task_e`'s compaction was
  visibly running in every serial log). None of round 65's fixes
  targeted this code path directly (`scheduler_pick_next`'s r8-r11
  save/restore and `task_sleep_ticks`'s interrupt masking are both
  general scheduler hardening, not SD/DharaFS-specific, and the actual
  SHA-256 fix — reloading scratch pointers fresh instead of holding
  them live in a register — never touches `sdhost_read_block`/
  `dharafs_compact` at all) — so this is strong indirect confirmation
  that round 65's *scheduler*-level hardening (not the SHA-256-specific
  fix) was the part that mattered for this second bug, consistent with
  this entry's own long-standing "same root cause" theory. The
  temporary diagnostic trigger was reverted after confirming the fix;
  `dharafs_encryption_self_check` is back to its permanent, safe,
  pure-in-memory-only form. Full regression battery re-verified green
  after reverting: `qemu_run.py` PASS, `phase4_milestone.py` 14/14,
  `host_harness` 315/315 under ASAN/UBSAN, `heap_stress.py` PASS.

  **Follow-up done, round 66 (2026-09-01, same day)**:
  `dharafs_encryption_self_check` now also exercises the real SD-
  integrated path — writes plaintext through `dharafs_block_write`
  with encryption temporarily forced on, confirms the RAW on-disk
  bytes (`dharafs_block_read_raw`) are genuinely different from
  plaintext (not a silent no-op), then reads back through
  `dharafs_block_read` (auto-decrypts) and confirms it reproduces the
  original plaintext — the actual encrypt-on-write/decrypt-on-read
  path a real file write exercises, not just the bare transform
  function in isolation. Crypto-enabled state is saved/restored around
  the check so a normal boot's own encryption setting (off, by
  default) is unaffected afterward. The original pure in-memory
  transform check is kept alongside it, not replaced.

  Verified via `phase4_milestone.py` (which, unlike `qemu_run.py`,
  attaches a real SD `-drive` — `qemu_run.py` has none at all, which
  is also why this project's OWN pre-existing "SD: 8-block round-trip
  sweep any_fail=1"/DharaFS FAILs only ever show up under that
  specific harness, not a real regression) plus a dedicated 10-attempt
  repeated-boot stability sweep (3-minute watch each, fresh SD image
  per attempt) specifically because this now does real SD I/O on every
  single boot — the exact trigger class round 65/66's fix addressed.
  Zero crashes across all 10. Full regression battery green:
  `phase4_milestone.py` 14/14, `host_harness` 315/315 ASAN/UBSAN,
  `heap_stress.py`.

- **Secure boot** — `[not sized — SKIPPED FOR NOW, 2026-08-31; the
  hardware-rooted version hits a hard, permanent hardware ceiling
  (below); the smaller runtime-signature-verification substitute hits
  the SAME EC-arithmetic blocker as TLS/PKI above]`
  Real secure boot means a hardware-anchored, cryptographically
  verified chain from an immutable root of trust through every stage
  that runs before the OS itself does. **The original Raspberry Pi 1
  Model B's boot ROM has no signature-verification capability at
  all** — same hard ceiling as USB boot, and for the same underlying
  reason (this SoC generation's boot ROM predates that class of
  feature; later models added OTP-based signing in their own
  bootloader/EEPROM updates). No amount of work inside Dhruva's own
  code changes what the boot ROM itself is capable of verifying before
  Dhruva ever gets to run. A real, achievable, SMALLER substitute that
  doesn't need boot ROM cooperation: Dhruva verifying a signature over
  something IT loads at runtime (a config file, an update payload)
  before trusting it — genuinely useful, buildable on the crypto
  foundation above, but a different and much smaller claim than
  "secure boot" in the hardware-root-of-trust sense. Revisit the
  hardware-rooted version only if the target ever moves to hardware
  that actually supports it (Pi 4/5, which do have OTP-based secure
  boot — see `docs/PORTING.md`).

- **PQC (Post-Quantum Cryptography)** — `[XL+, genuinely disproportionate
  to this project's current scope — recorded because asked for, not
  recommended]`
  NIST-standardized PQC (ML-KEM/Kyber, ML-DSA/Dilithium, SPHINCS+)
  needs either lattice arithmetic (polynomial rings, number-theoretic
  transforms) or hash-based signature trees — genuinely advanced
  cryptographic engineering, a multi-month undertaking even in
  well-resourced projects with existing reference implementations to
  port from, let alone building it from scratch in vani on bare-metal
  ARMv6. Worth being honest about the actual motivating threat model
  too: PQC defends against "harvest now, decrypt later" attacks on
  long-lived confidential traffic crossing real networks — this
  project's networking is no longer purely loopback (round 56 added a
  live-verified CDC-ECM path with real off-box traffic — real `ping`
  round trips, real DHCP exchanges over an actual USB link), but it
  still carries no confidential/encrypted traffic of any kind (no TLS,
  no WPA2 — see the WiFi item's own AES gap), so the threat PQC exists
  to counter STILL doesn't apply to anything Dhruva actually does. Not
  recommended before the classical crypto foundation above exists AND
  real confidential off-box traffic is a going concern — at that
  point, this is worth
  revisiting as its own dedicated, multi-round research-heavy effort,
  not a normal backlog item.

- **Hardening against sophisticated/AI-accelerated attacks** — `[ongoing
  discipline, not a discrete buildable item]`
  "AI-sophistication" mostly means the SAME bug classes this project
  already fights (buffer overreads, integer overflow, use of untrusted
  lengths — the "reject, don't guess" pattern audited into nearly
  every parse site so far) get found faster and more thoroughly by
  automated fuzzing/exploit-generation, not that a qualitatively new
  defense category is needed. Two concrete, honestly-scoped responses:
  1. **Continue the existing audit discipline** (this backlog's own
     established practice) rather than treating "AI attacks" as a
     separate initiative — it's the same threat model at higher
     volume, not a different one.
  2. **Enable real memory protection** — `[L — DONE (round 38) for the
     write-protection half; execute-protection is a tracked known
     limitation, see below]`
     The MMU is now on (`boot/mmu_init.S`), identity-mapped, with the
     code section (vectors/.text.boot/.text/.rodata) marked read+
     execute but genuinely never writable, and data/heap/stack/
     peripherals marked read+write. `link.ld` now pads `.data` to the
     next 1MB boundary so ARMv6's 1MB section granularity can express
     a clean code/data split at all.
     - **Live-verified, not just present in the table**: a deliberate
       write to the code section was proven to fault with a genuine
       section-permission status. Getting there took two real,
       non-obvious fixes found only by testing the actual enforcement
       rather than trusting the encoding: (1) `AP=11` combined with
       `APX=1` for "read-only" did not actually enforce it on this
       core/QEMU model; switched to `AP=01` (privileged read-only,
       which is all this kernel needs since it never runs unprivileged
       code); (2) that alone still didn't work — the real missing
       piece was `SCTLR.XP` (bit 23), which disables ARMv5's legacy
       "subpage AP" compatibility scheme in favor of the whole-section
       AP interpretation this table actually uses. Once both were in
       place, the deliberate write correctly faulted.
     - **Known limitation, NOT fixed this round**: the parallel
       deliberate test for execute-protection (`XN=1` on the data
       section, jumping into it and expecting a Prefetch Abort) never
       faulted — execution ran straight through hundreds of KB of
       zero-filled data as harmless no-ops. A bit-position mix-up
       between `APX`/`XN` was ruled out (the code section's `APX=1`
       demonstrably didn't block its own execution, which a misplaced
       `XN` there would have).
       Found *after* this live test: a local Yocto build tree happened
       to have QEMU 4.2.0's own ARM emulation source checked out
       (`target/arm/helper.c`) — older than the 10.0.11 actually
       installed and tested against, but real reference material where
       none was expected. That source's `get_phys_addr_v6` (confirmed
       reached whenever `SCTLR.XP` is set, exactly this table's own
       setup) matches this table's encoding in every particular that
       matters: `XN` really is bit 4; `domain_prot==1` (client, what
       this table's DACR sets) takes the real AP/XN-checked path, not
       `domain_prot==3`'s (manager) full-access bypass; the combined
       APX/AP value correctly yields read-only for the code section's
       own encoding and read-write for data's, both already proven
       live; and a section with `xn=1` should never gain `PAGE_EXEC`
       regardless of AP/APX, which should then fail the instruction-
       fetch permission check and fault. Every step of that older
       source's own logic agrees with this table's intent — yet the
       currently-installed, five-plus-years-newer QEMU still didn't
       enforce it. This now points more specifically at a **QEMU
       version-specific behavior difference** than at a bug in this
       table's own encoding, though without 10.0.11's own source to
       diff against directly, that remains a strong inference, not a
       proven fact. The `XN` bits are kept set anyway — free if real
       hardware (or a different QEMU version) enforces them correctly,
       harmless if this specific installed QEMU doesn't.
       **Revisit once a real Pi 1B is connected** (see the
       hardware-in-loop section below) — testing the identical
       deliberate-execute probe against real silicon would
       definitively settle this either way, since real hardware's
       behavior is the actual ground truth regardless of which QEMU
       version's source agrees with the table.
     - New abort-mode diagnostics (`vectors.S`'s `fault_data_abort`/
       `fault_prefetch_abort`, previously both a silent infinite loop
       with zero output) were a real prerequisite built first, not
       optional scaffolding — printing the faulting address and status
       is what made this round's own live verification possible at
       all, and is now permanent, genuinely useful infrastructure for
       diagnosing any future real fault, not just this round's testing.
     - Full existing self-test/regression battery (including the full
       USB mass storage DMA chain — DWC2's own DMA engine reads/writes
       heap-allocated buffers under the exact same RAM mapping) verified
       to behave identically with the MMU on, confirming the Normal-
       Non-cacheable memory type choice preserves this project's
       existing zero-caching DMA-coherency assumptions unchanged.

## Hardware-in-loop testing (once a real Pi 1B is available)

Every item in this backlog should get as much regression coverage as
QEMU can actually provide before it's considered done — that's the
default, not an exception. Real hardware only enters the loop for
what QEMU's fidelity genuinely can't reach: real USB device timing/
quirks (the mass storage driver above, and anything in the "known
real-hardware-only gaps" section of the Dhruva Feature Ledger —
governor wattage, memory-ordering barriers, the real LAN9512's
hub port-2 behavior), and any future storage backend's real-media
behavior. When a real Pi 1B is connected, treat it as an additional
verification pass on top of the existing QEMU battery, not a
replacement for it — everything QEMU can already catch should still
be caught in QEMU first, keeping the fast local loop as the default
and hardware-in-loop as the final confirmation pass.

## Pi 4/5 port — now started (round 40 research, round 43 boot skeleton)

**Round 40 correction**: `docs/PORTING.md` previously claimed no QEMU
target exists for Pi 4/5 at all. Verified false for Pi 4 — QEMU's
64-bit `qemu-system-aarch64` binary (already installed, separate from
the 32-bit `qemu-system-arm` this project has used exclusively so
far) has a `raspi4b` machine model. A minimal bare-metal AArch64
stub was built (`aarch64-linux-gnu-gcc -mgeneral-regs-only -nostdlib`,
already installed, no new toolchain needed) and booted live under
`qemu-system-aarch64 -M raspi4b -kernel <elf>`, confirming: PL011 UART
at `0xFE201000`, ELF `-kernel` boot works the same way `dhruva.elf`
already relies on for Pi 1, and QEMU starts execution at **EL3**
(real boot code needs an explicit EL3→EL1 drop — nothing like
ARM1176's flat mode-switch model). `vani-compiler` also already has
generic bare-metal AArch64 cross-compile plumbing
(`is_bare_metal_triple`/`cross_cc_for_triple` + `CROSS_CC` override in
`src/main.rs`) — no compiler changes needed to start. Full details:
`docs/PORTING.md`'s "Correction (round 40)" section.

**Net effect**: a real Pi 4 port keeps this project's entire existing
QEMU-based verification discipline (self-tests, `phase4_milestone.py`-
style smoke tests, `heap_stress.py`, `power_yank.py`) — it is NOT
real-hardware-only the way it was previously assumed to be. Pi 5
remains real-hardware-only (no QEMU model exists for BCM2712/RP1).

**Round 43: real EL3→EL1 boot skeleton — DONE, checked in.**
`boot/rpi4/boot.S` (EL3→EL1 privilege drop), `boot/rpi4/vectors.S` (a
real 16-entry AArch64 exception vector table, diagnostic-only —
reports `ESR_EL1`/`ELR_EL1`/`FAR_EL1` then halts, same "never silently
loop forever" convention round 38 established), `boot/rpi4/link.ld`,
built via the new `build_rpi4.sh`, verified via the new
`test/rpi4_boot_smoke.py`. Both halves live-verified: the drop prints
`CurrentEL=1` (read AFTER dropping, at EL1), and the vector table was
proven to genuinely dispatch by deliberately executing `udf` and
confirming the correct vector fires with an architecturally-correct
`ESR_EL1`. That fault-injection test caught a real bug during
development (`uart_puts_rpi4_el` clobbered its own return address via
two un-saved nested calls) — fixed before the round closed. Full
details: `docs/PORTING.md`'s "Round 43" section.

Remaining scope for a real Pi 4 boot, now precisely identified rather
than assumed:

- ARMv8-A MMU (TTBR0_EL1/TCR_EL1, radically different from ARMv6's
  short-descriptor 1MB sections used in `boot/mmu_init.S`).
- GICv2/GICv3 interrupt controller (replaces BCM2835's simple
  interrupt controller — `timer_ic_init` and everything built on it).
- BCM2711 generic ARM timer at new peripheral addresses (same timer
  core the scheduler already assumes, different base).
- Porting `kernel_main.vani` itself (or a fresh AArch64-native rewrite
  of its boot-facing pieces) to this target — round 43's kernel is
  deliberately hand-written assembly only, no vani-compiled code yet.
- Only after all of the above: EMMC2 (storage) and XHCI (USB) drivers
  from scratch — both already flagged above as substantially larger
  than their Pi 1 SDHOST/DWC2 counterparts.

Still not sized (each of the bullets above is its own multi-round
effort).

## DharaFS advanced features + DhruvaOS observability ("Darshana") — distilled from 2026-08-29 brainstorm docs

Distilled from two brainstorm documents the user wrote (`~/dharafs-
idea.txt`, `~/dhruvaos-idea.txt`) — positioning/marketing framing
("benchmark against embedded requirements, not ext4", the ext4-
comparison table, "what Linux can't easily give you") is deliberately
left out below as non-actionable; only concrete, buildable mechanisms
are turned into backlog items. Several proposals turned out to
already be substantially built — called out explicitly so future work
extends rather than re-implements them. Everything here is new
backlog, not committed to a schedule; ordered roughly cheapest/
highest-leverage first within each subsection.

**Already substantially in place, don't re-build:**
`dharafs_append_raw`'s reverse-order multi-block write (every
continuation chunk before the head, so the head's own single-block
write is the one atomic commit point) already gives single-file
atomic updates and power-loss consistency (the brainstorm doc's items
3/4) — a real transaction API below would need to extend this across
*multiple* files, not introduce atomicity that doesn't exist yet.
Per-record checksums (`buf_checksum`) already give corruption
detection (item 5) — real gap is only that it's a simple rotate-mix,
not a real CRC/hash. Owner/group/other rwx (round 42) already covers
"Built-in ACLs" (item in the differentiation table). The frequency
governor already keeps a small history (`governor_history_get0..3`)
and `dhruva_heap_used_bytes` already exposes live heap usage — real
building blocks for a diagnostics command, not a green field.

### DharaFS

- **`dharafs_rename` + a real multi-file transaction primitive** —
  `[M, ~2 rounds — DONE, rounds 47 + 52]`
  First increment (round 47): `dharafs_rename_raw` (read the existing
  record, append it under the new path preserving owner/mode, tombstone
  the old path) + shell `mv`.

  Second increment (round 52): `dharafs_tx_begin_raw`, closing the "a
  crash between the append and the delete leaves both copies live" gap
  round 47's own comment flagged. Design: a TX_BEGIN marker record
  (using the existing 512-byte record format's `path_len` field set to
  a sentinel value outside the real 1-32 range, `data_len` repurposed
  to hold a block count) is appended before the N blocks it covers —
  deliberately no separate TX_COMMIT record, since block numbers in
  this log are strictly increasing and never reused within one boot
  session, so "are the next `block_count` blocks all present and
  checksum-valid" is itself a complete completion proof; nothing else
  could ever produce valid records at exactly those positions. On
  recovery, `dharafs_init` finds an INCOMPLETE transaction only ever at
  the very tail of the log (a crash stops everything, so nothing real
  could have been appended after one) and rolls the append cursor back
  to the transaction's own starting block, abandoning every half-
  written block after it — old data intact, new data simply never
  existed, extending the same "old OR new, never mixed" guarantee
  single-record atomicity already gives across multiple records.
  `dharafs_rename_raw` now wraps its own append+delete pair in exactly
  this.

  Verified with real simulated crashes, not just a normal-path test:
  (1) crash immediately after tx_begin, before either write — old data
  untouched, new path never created, future appends unaffected by the
  abandoned block; (2) the harder case, crash after the append half
  genuinely succeeds but before the delete — old data STILL fully
  intact, new path still invisible (the half-completed write doesn't
  leak through); (3) a genuinely completed transaction is correctly
  recognized as such and NOT rolled back. 26 new host-harness tests,
  215/215 PASS clean under ASAN/UBSAN. Live `mv` round trip unchanged,
  full regression battery clean including `power_yank.py` 70/70.

- **Stronger optional integrity hash for security-critical paths** —
  `[S, ~1 round — DONE, round 48]`
  `buf_checksum`'s rotate-mix (32 bits, not collision-resistant) is
  fine for catching torn writes but not tamper detection. Round 41's
  `sha256_hash` reused as an opt-in per-file stronger digest, stored at
  a companion `<path>.sha256` file rather than a change to the 512-byte
  on-disk record format (no PKI/secure-boot consumer exists yet to
  justify that larger cost). New `dharafs_write_verified_raw/_checked`/
  `dharafs_read_verified_checked` + shell `writev`/`catv`. Verified
  live, 110/110 host-harness PASS including a deliberate tamper test.

  **Follow-up: DONE.** `sha256_hash` now uses persistent scratch
  internally (`sha256_padded_scratch`/`_h_scratch`/`_k_scratch`/
  `_w_scratch`, `boot/scratch_state.S`) sized to the worst case for the
  largest real caller (`dharafs_file_max_len()` = 4096 bytes, giving a
  4168-byte padded-message bound derived from the padding formula, not
  guessed) instead of a fresh `dhruva_alloc_bytes` per call. The
  round-constant K table is also now initialized once at boot instead
  of recomputed (identically) every call. Crypto correctness
  re-verified carefully given the stakes: all 3 NIST/FIPS-180-4 KAT
  vectors still pass byte-exact, the host harness's own boundary tests
  (which already call `sha256_hash` repeatedly with varying lengths in
  one run) still pass 189/189 under ASAN/UBSAN, and a live `writev`/
  `catv` round trip still verifies correctly end to end.

- **Append-only log convenience API** (`dharafs_log_append`, automatic
  rollover + GC across numbered files) — `[DONE: append/rollover from
  round 49 (this entry's own text describing them as missing was
  stale); GC added round 66, 2026-09-01]`
  A log named `name` lives as numbered files `/logs/<name>-NNNN.log`
  plus an `/logs/<name>.hdr` header (round 49), rolling over to a new
  file automatically once the current one would exceed
  `dharafs_log_rollover_threshold()` (3584 bytes) — already wired to
  the shell `log` command and documented in `DHARAFS_MANUAL.md`. The
  one genuinely missing piece this entry correctly identified was GC:
  without it, every rollover left the previous file behind forever,
  unbounded growth for a log meant to run indefinitely. Fixed by
  reclaiming generation `N - dharafs_log_retention_count()` (5) once
  generation N's rollover — file AND header — are both safely durable,
  so a crash mid-rollover can never leave the header pointing at an
  already-deleted generation. No handle-based `dharafs_log_open`/
  `_sync` API was added — the existing stateless `dharafs_log_append(
  name, line)` (re-resolves the current file per call) was judged
  ergonomic enough already; a persistent handle would only be a
  caching optimization, not a functional gap.

  Verified with 77 new host-harness tests (392/392 PASS clean under
  ASAN/UBSAN) driving a real log through 7 rollovers and confirming:
  the correct 3 oldest generations are reclaimed, the 5 most recent
  (including current) remain readable, the header still correctly
  tracks the current generation after GC, and a second, unrelated log
  name's own generations are completely untouched (GC is scoped per
  name). Full regression battery green: `qemu_run.py`,
  `phase4_milestone.py` 14/14, `heap_stress.py`.

- **Immutable / append-only / system file attributes**
  (`DHARA_ATTR_IMMUTABLE`/`APPEND_ONLY`/`SYSTEM`) — `[S-M, ~1 round —
  DONE, round 50]`
  Packed into the EXISTING `mode` u32's otherwise-unused high bits
  (only the low 9 bits are real rwx permission bits) rather than a
  record-format change — same "don't touch the 512-byte layout without
  a real forcing need" reasoning round 48's companion-file digest
  already established. Checked in `dharafs_write_raw_checked`/
  `dharafs_write_verified_checked`/`dharafs_delete_raw_checked`/
  `dharafs_rename_raw_checked` (both source- and destination-side).
  Real chattr-matching semantics: immutable blocks write/delete/rename-
  as-source/being-a-rename-destination; append-only blocks delete and
  non-prefix-extending writes but allows rename (content travels with
  it); a non-root owner can set either but never clear them once set
  (only root can); `SYSTEM` is informational-only, no enforcement, so
  it's exempt from the no-clearing rule. New `dharafs_set_attr_raw`/
  `dharafs_get_attr_raw` + shell `attr`. Verified live over QEMU (all
  12 designed scenarios correct) and via 36 new host-harness tests
  (173/173 PASS clean under ASAN/UBSAN).

- **Priority/deadline-aware FS request queue** — `[M, ~2 rounds —
  shared dependency with the scheduler-side observability work below]`
  Every `dharafs_*` call today runs synchronously inline in whatever
  task called it — there's no separate FS request queue for a
  higher-priority task's I/O to preempt/precede a lower-priority one's.
  Real version needs a queue + the calling task's own priority
  (already tracked by the scheduler) as sort key. Lower priority than
  the items above — no current workload in this project actually
  contends on FS access across priority levels yet, so this is
  speculative until one does (per this project's own "don't design for
  hypothetical requirements" discipline).

- **Snapshots / versioned rollback** — `[L, several rounds, not
  started]`
  DharaFS is already log-structured with a full append history until
  `dharafs_compact` reclaims it — a "snapshot" is conceptually "pin
  sequence range N..M so compaction can't reclaim it, plus a query API
  to read a specific historical sequence." Real complexity is in
  `dharafs_compact`'s reclaim logic needing to respect pins it doesn't
  know about today. Defer until a concrete use case needs it (the
  brainstorm doc's own example — config rollback after a failed
  update — is exactly what the transaction primitive above already
  handles for the *single* "did the last write fully commit" case;
  snapshots only add value for "roll back further than the last
  write," a materially bigger ask).

- **Hashed directory index, wear/erase statistics, capability tokens
  beyond uid/gid/mode** — not started, explicitly deferred. Directory
  lookup is already bounded by `dharafs_init`'s own 2048-block scan
  ceiling and this project's realistic embedded file counts (tens to
  low hundreds, not millions) — a hash index is solving a scaling
  problem this project doesn't have yet. Wear/erase stats need a real
  flash-aware backend (EMMC2/NAND) to mean anything; both current
  backends (SDHOST, USB mass storage) don't expose that information at
  this layer. Capability tokens are a genuine security-model expansion
  beyond uid/gid/mode, sized similarly to (and worth designing
  alongside, if ever started) the security roadmap's PKI item above —
  not scoped further here.

### DhruvaOS observability ("Darshana")

Currently there is no profiling/observability subsystem at all beyond
raw self-test PASS/FAIL output and the frequency governor's own small
history buffer — this is genuinely new work, not an extension of an
existing subsystem the way most DharaFS items above are. Ordered
cheapest-and-highest-leverage first; later items depend on earlier
ones.

- **`dhruva diagnose` shell command** — `[DONE — this entry was stale,
  confirmed round 66, 2026-09-01]`
  Already fully implemented, incrementally across rounds 51/53/59 (this
  top-level entry was simply never marked done at the time). Live-
  verified this round: a real `diagnose` command run reports
  `uptime_ticks`, `scheduler ready` count, `heap` usage with a
  percentage and high-water-mark note, `cpu freq` plus governor
  history, `allocations`/`FS commits` counts, `context switches`/`IRQs
  serviced`/`prio_lock calls` (round 53's event counters, genuinely
  "wired into diagnose" as the section below already claimed), and
  `mutex contentions`/`mutex worst-case wait` (round 59). Nothing left
  to build here — see the "Self-observing kernel: event counters"
  entry immediately below for the one genuinely separate piece (a
  ring buffer of recent events, not yet started) and "Per-task runtime
  histograms" for what's deliberately still skipped and why.

- **Self-observing kernel: event counters** — `[M, ~2 rounds — counters
  DONE, round 53; ring buffer not started]`
  `context_switch_count` (scheduler_pick_next picked a genuinely
  DIFFERENT task — `boot/context_switch.S`), `irq_count` (every real
  IRQ, timer + UART RX — `kernel_main.vani`'s `irq_dispatch`), and
  `prio_lock_count` (ceiling-protected critical section entries),
  alongside round 51's `dhruva_alloc_count`/`dharafs_commit_count`, all
  wired into `diagnose`. These are deliberately the ONLY instrumentation
  built so far, and deliberately chosen for a specific reason: each one
  is real and meaningful regardless of what the running tasks actually
  do — a context switch, an IRQ, and a ceiling-protocol entry are real
  scheduler/interrupt EVENTS whether the tasks involved are the current
  synthetic LOW/MEDIUM/HIGH demo or a genuine future workload. That's
  NOT true of the items below, which is exactly why they're still
  deferred — see each one's own note on what's specifically missing.

  Found a real bug live while building this (not caught by code
  review): a counter increment used AAPCS callee-saved registers
  (r4/r5) as unsaved scratch in an assembly function called from
  vani-compiled C, silently corrupting a live compiler value. See
  `feedback_aapcs_callee_saved_registers_asm` — worth reading before
  touching `boot/context_switch.S`/`boot/irq_entry.S` again.

  A fixed-size ring buffer of recent events (for "last N seconds"
  queries, not just running totals) is a real, separable next step —
  not started. Needs a concrete decision on retention size and
  overhead budget (this project has no "instrumentation must cost
  < X% CPU" target set yet) before writing it.

- **Per-task runtime histograms + a real deadline/budget model** —
  `[M-L, ~3-4 rounds combined — SKIPPED FOR NOW, 2026-08-31, genuinely
  blocked on a real workload, not just unscoped]`
  This is the one place in this backlog where "build the mechanism
  now, apply it later" doesn't work: a runtime histogram or a
  deadline-miss count is only meaningful relative to something the
  task's OWN code actually promises. The only tasks that exist today
  (LOW/MEDIUM/HIGH, `kernel_main.vani`) are synthetic priority-ceiling-
  protocol demonstrations with no real timing requirement of their
  own — assigning them an invented "budget: 2ms" to have something to
  report against would be fabricating a number, not observing one, and
  actively misleading (a future reader of `diagnose`'s output has no
  way to tell a real deadline from a made-up one). **Concrete plan for
  when a real workload exists**: add `task_set_deadline(task_id,
  period_ticks, deadline_ticks, budget_ticks)` (a small state table,
  same shape as `eff_prio_table`/`sleep_until_table` in
  `boot/context_switch.S`), have `scheduler_pick_next` timestamp actual
  runtime per task using the already-real `tick_count`, and report
  actual-vs-declared in `diagnose` plus a running miss count. Build
  this the round a real timing-constrained task (a genuine sensor
  poll loop, a real network deadline, anything with an actual
  consequence for running late) gets added to this project — not
  before, and not against the demo tasks as a stand-in.

- **Priority-inversion detection/logging** — `[SUPERSEDED — see "Real
  priority-inversion primitive (blocking mutex + inheritance)" further
  below]`
  This entry originally argued detection was structurally impossible
  without a real blocking primitive, since the priority-CEILING
  protocol (`dhruva_prio_lock`/`dhruva_prio_unlock`) prevents inversion
  by construction and produces no scheduling-visible signal to detect.
  That blocking primitive now exists (round 55,
  `dhruva_mutex_lock`/`dhruva_mutex_unlock`) — this entry was left
  stale for a day after that landed. See the other entry for what's
  done and what instrumentation (contention count, worst-case wait)
  remains.

- **Fault injection framework** — `[DONE, round 62, 2026-08-31]`
  `dhruva_fault_inject_alloc_arm(after_n)` + shell `fault alloc <n>`:
  arms a countdown, and the Nth subsequent `dhruva_alloc_bytes` call
  fails via the real `dhruva_oom_fatal` halt regardless of whether
  genuine heap space remains — exactly the "exercise the OOM-fatal
  path under QEMU, not just the host harness's synthetic
  constructions" goal this item was written for.

  **Found a second real bug this way, not just exercised the first
  one**: live-testing this feature (arming a fault, watching what
  actually happened) revealed `dhruva_oom_fatal`'s own "Halting"
  didn't actually halt the SYSTEM — only the one calling task. Every
  caller reached it with interrupts already re-enabled (`dhruva_alloc_
  bytes` restored its saved CPSR before calling in), so the scheduler's
  timer tick kept firing and every OTHER task kept running normally,
  directly contradicting the documented "unrecoverable, whole-system
  halt" intent from round 45 and the same convention `boot/rpi1/
  vectors.S`'s `fault_data_abort`/`fault_prefetch_abort` correctly
  follow (ARM's own exception entry auto-disables IRQ for those; nothing
  re-enables it in either handler). Fixed by disabling IRQ explicitly
  and unconditionally at the top of `dhruva_oom_fatal` itself, so it's
  safe by construction regardless of caller state, not by caller
  discipline. This is exactly the kind of bug only live behavioral
  testing catches — code review alone would have seen a `while(1)`
  and reasonably assumed "halted."

  Also added two simple, real event counters wired into `diagnose`
  (`dhruva_alloc_count_get`, `dharafs_commit_count_get`). The rest of
  the "context switches, IRQ rate, mutex acquisitions" list from the
  original brainstorm doc — which needed touching the scheduler/
  interrupt assembly directly — is now DONE too, see the "self-
  observing kernel" item above (round 53).

  **Round 62 completed the remaining three fault types** — `fault
  write <n>`, `fault irqburst <n>`, `fault netdrop <n>` — following
  the same "0 means disarmed, production unaffected" contract as
  `alloc`, in a new `boot/fault_inject_state.S` (these three live in
  vani, not `runtime_stubs.c`, since their injection points --
  `sdhost_write_block`, `irq_dispatch`, `netif_send_frame` -- are vani
  functions, not C). The shell front end was factored into its own
  `shell_dispatch_fault` from the start (the same `#[bounded_stack]`
  reason `shell_dispatch_fw`/`_su`/`_passwd` already were), rather than
  inlining and discovering the same budget failure again.
  - `fault write <n>`: forces the Nth subsequent real SD write to fail
    (a real I/O error, no hardware touched) — exercises DharaFS's own
    write-failure handling on demand. Live-verified: armed to 1, the
    next `write` command reported `error`.
  - `fault netdrop <n>`: silently discards the next n outgoing network
    frames while reporting success to the sender — `netif_send_frame`
    is the single choke point every outgoing frame (ARP/IPv4/ICMP/UDP/
    TCP) already passes through, so one injection point covers all of
    them. Live-verified: armed to 1, `ping 0.0.0.0` (normally `reply
    from 0.0.0.0 seq=1`) instead reported `ping: no reply`.
  - `fault irqburst <n>`: on the next real timer tick, jumps
    `tick_count` forward by n EXTRA ticks via the existing
    `scheduler_set_tick_count_test_only` test hook. Deliberately scoped
    as a "clock time-warp" (simulating what a slow/blocked ISR
    catching up on missed ticks looks like from the scheduler's own
    point of view), NOT a simulation of n real, distinct context-
    switch/preemption events firing in rapid succession — that would
    need looping inside `scheduler_switch_from_irq`'s own AAPCS-
    sensitive native asm (`context_switch.S`), exactly the class of
    code round 53 already found a real, hard-to-spot callee-saved-
    register bug in (see [[feedback_aapcs_callee_saved_registers_asm]]
    in project memory) — not worth that risk for a test convenience.
    Live-verified: armed to 50, `diagnose` showed `uptime_ticks`
    jumping by ~59 over one real tick interval (base +9 real ticks
    during the round trip + the 50 injected), and incidentally stress-
    tested the mutex-wait tracker too (`mutex worst-case wait` jumped
    from 3 to 53 ticks in the same step, a genuine, unplanned side
    effect of a sudden clock jump while a task was mid-sleep holding
    the demo mutex).

  All three also get host-harness ASAN/UBSAN coverage
  (`test_fault_injection` in `host_main.c`) of the actual new countdown
  logic (the hardware-touching call sites themselves aren't meaningful
  to exercise on a host process). Full regression battery green
  (qemu_run, phase4_milestone, heap_stress, host_harness 315 PASS/0
  FAIL). One `phase4_milestone.py` run during this work hit the
  already-documented, pre-existing intermittent SD-boot bug (see the
  entry above) — confirmed unrelated to this round's own changes (5/5
  clean re-runs immediately after; same exact FATAL signature as
  before).

- **"Why is my task late?" query + determinism-certificate report** —
  `[L, not started — SKIPPED FOR NOW, 2026-08-31, blocked on the
  deadline model AND the event ring buffer above, in that order]`
  The causal-chain explanation (blocked on mutex X for Y us, preempted
  by IRQ Z for W us) needs the deadline model to know a task WAS late
  in the first place, and the event ring buffer to reconstruct WHY —
  genuinely the most sophisticated item in this list, correctly last
  in the brainstorm doc's own ordering, and doubly blocked since the
  deadline model itself waits on a real workload (see its own note
  above). Don't start this before that exists.

- **Incident/flight-recorder capture on watchdog reset** — `[L, not
  started — SKIPPED FOR NOW, 2026-08-31, blocked on a PERMANENT
  test-environment limitation, not just missing wiring]`
  `watchdog_arm`/`watchdog_init`/`watchdog_kick` already exist (Phase
  2), but are deliberately NOT wired into the real per-tick path.
  Checked directly against `watchdog_arm`'s own comment before assuming
  this was just an unwired convenience function: it's confirmed
  EMPIRICALLY (tested at both a 2-second timeout and the maximum
  possible 20-bit value) that QEMU's `raspi1ap` machine model does not
  honor `PM_WDOG`'s timeout field at all — writing `PM_RSTC` with
  `WRCFG=FULL_RESET` resets the emulated machine IMMEDIATELY regardless
  of what's armed. Since this project tests exclusively via QEMU,
  wiring `watchdog_kick` in would make the one and only test method
  permanently unable to boot at all. This is a hardware-verification
  gap in QEMU's own machine model, not a missing Dhruva feature —
  revisit only if real Pi 1 hardware-in-the-loop testing (the user's
  own stated eventual plan, see `project_dhruva_hardware_in_loop_plan`
  in project memory) becomes available, since real hardware may honor
  the timeout correctly where QEMU's emulation doesn't.

- **CI-integrated real-time regression thresholds** — `[M, not started
  — SKIPPED FOR NOW, 2026-08-31, blocked on the histogram work above,
  AND on accumulating real baseline data]`
  Natural fit for this project's existing `test/*.py` convention (same
  shape as `heap_stress.py`/`power_yank.py`) — run under QEMU, compare
  scheduler-latency/context-switch histograms against a checked-in
  baseline, fail on regression past a threshold. Needs the histogram
  work above first (itself gated on a real workload, see that item's
  own note); a single session's own counters aren't a "baseline" to
  regress against — this needs several real runs' worth of data
  accumulated first. QEMU's own timing won't match real hardware
  absolute numbers either, so any threshold would need to be
  QEMU-relative (regression-detection against its own prior runs), not
  an absolute real-time guarantee claim.

- **Production vs. developer profiling levels** — `[S-M — SKIPPED FOR
  NOW, 2026-08-31, once something above exists to gate]`
  This project has no compile-time feature-flag system today (one
  `kernel_main.vani`, compiled as a single unit) — a simple runtime
  on/off toggle per instrumentation tier (checked at each hook site) is
  the realistic near-term version; true compile-time stripping would
  need a real build-flag mechanism this project doesn't have yet and
  shouldn't be built speculatively ahead of an actual need for it.

## User-facing documentation + general-purpose RTOS gaps (2026-08-29)

Prompted by a direct user question: is this a "true RTOS", does it
have an API for a third party to add their own tasks, and is there a
user manual — plus a follow-up asking for USB WiFi/BLE drivers on Pi 1
(no onboard wireless exists on that board; the user's own call is USB
dongles there, onboard chips once a newer Pi's port matures). Honest
answers to the first three, verified against the actual code, not
assumed: the scheduler core (fixed-priority preemption + priority-
ceiling protocol + compiler-enforced `#[wcet(...)]`/`#[bounded_stack(
...)]`) is genuinely real-time-grade — more rigorous than most small
RTOS projects. But the task set is exactly 6 compile-time-hardcoded
slots (`sp_table`/`eff_prio_table`/`sleep_until_table` in
`boot/context_switch.S` are literal 6-word arrays; `start_multitasking`
takes exactly 6 stack-pointer arguments) with no creation API; there is
no user manual at all (`docs/` has only `TODO.md`/`PORTING.md`); and
networking is loopback-only with zero real NIC/wireless hardware
support of any kind.

- **DhruvaOS user manual** (`docs/DHRUVAOS_MANUAL.md`) — `[M, ~1-2
  rounds]`
  Boot process, the scheduler/task model (including its current
  6-task-fixed limitation, stated plainly rather than glossed over),
  the interactive shell and all ~20 commands, the heap allocator's
  never-free/OOM-fatal model, how to extend the kernel today (before
  a real task API exists) and how that changes once one does, build/
  run instructions. Written before the task-creation API below so it
  can honestly describe the CURRENT state, then gets a real update
  once that API lands rather than documenting something aspirational.

- **DharaFS user manual** (`docs/DHARAFS_MANUAL.md`) — `[M, ~1 round]`
  On-disk record format, the permission model (owner/group/other +
  immutable/append-only/system attributes), rename+transaction
  semantics, verified I/O (`writev`/`catv`), the append-only log API,
  crash-consistency guarantees (and their actual limits — compaction's
  own documented failure modes, the transaction primitive's own
  "old-or-new, never mixed" scope), the block-device backend
  abstraction, full `dharafs_*` API reference.

- **General task-creation API** — `[M, ~2-3 rounds]`
  Generalizes the current fixed 6-slot model
  (`task_create(entry_fn, priority, stack_bytes) -> task_id`,
  replacing the hardcoded `sp_table`/`eff_prio_table`/
  `sleep_until_table` 6-word arrays in `boot/context_switch.S` with a
  real, bounded-but-extensible table, plus generalizing
  `start_multitasking`'s fixed 6-argument signature). Real design
  question to settle first: a fixed MAX_TASKS compile-time bound (
  simplest, matches this project's own static-allocation-everywhere
  discipline) vs. anything more dynamic (not warranted — this project
  has no heap-fragmentation tolerance for it and no forcing need).
  Every existing self-test exercising the scheduler (priority
  ceiling, preemption, `task_sleep_ticks`) needs to keep passing
  unchanged against the generalized table — this is core scheduler
  surgery, treat with the same care as round 53's own register bug.

- **Real priority-inversion primitive (blocking mutex + inheritance)**
  — `[DONE, round 55, 2026-08-29]`
  `dhruva_mutex_lock`/`dhruva_mutex_unlock` (`boot/context_switch.S`) —
  a genuine wait queue (mutex_owner_table + mutex_waiters_table) where
  a lower-priority holder really can delay a higher-priority waiter,
  with dynamic priority inheritance (base_prio_table added alongside
  eff_prio_table) recovering from that delay. Direct ownership handoff
  on unlock, no spurious-wake re-check needed. Live-verified over QEMU
  with a deterministic (not timing-coincidence) contention demo:
  `task_mutex_demo_low` holds the mutex across a `task_sleep_ticks(5)`
  call while `task_mutex_demo_high` polls every 2 ticks — by the
  pigeonhole principle (2 < 5) contention is guaranteed every cycle,
  not probabilistic. UART trace shows a real multi-tick gap between
  "requesting" and "acquired", and `current_eff_prio()` proves the
  holder's priority genuinely reads 0 (boosted from base 2) for the
  duration. No recursion support, no nested-mutex inheritance stacking
  — both deliberately out of scope for the single-mutex demo needed
  here. **Instrumentation DONE, round 59, 2026-08-30**:
  `mutex_contention_count` (genuine blocks only, not every lock call —
  `mutex_contention_count`/`_get` in `boot/context_switch.S`) and
  `mutex_wait_worst_ticks` (longest observed gap between blocking and
  actually being handed ownership, computed in `dhruva_mutex_unlock`
  from a new per-task `mutex_block_start_tick_table` written by
  `dhruva_mutex_lock` right before blocking), both surfaced in
  `diagnose`. Live-verified against the same deterministic demo:
  contention count grew monotonically across two `diagnose` calls
  (2 → 7) while worst-case wait stabilized at a plausible steady-state
  value (3 ticks, well within the demo's own 5-tick hold window).

- **Wired NIC driver: CDC-ECM (DONE, round 56) + real SMSC LAN9512
  (spec-only, hardware-pending)** — `[M-L, ~3-4 rounds, mostly DONE]`
  QEMU's `raspi1ap` has no LAN9512 device model, so the real chip's
  own vendor register protocol can't be live-verified under QEMU the
  way every other round in this project has been. Split into two
  layers to get both a real, live-verified data path NOW and the real
  target chip's own protocol written to spec: a shared USB-bulk
  transport (`dwc2_net_bulk_out/in`, `usb_net_state.S`), a CDC-ECM
  backend (standard USB class QEMU's own `usb-net` device and real USB
  Ethernet dongles both speak — LIVE-VERIFIED: real MAC fetched via
  SET_INTERFACE + GET_DESCRIPTOR(String) exactly matches an
  independently-specified QEMU `-device usb-net,mac=...` value; a real
  `ping <slirp-gateway>`/`ping <other-slirp-host>` round trip over the
  actual USB link, both replying correctly; QEMU packet capture
  independently confirms real DHCPDISCOVER/OFFER frames crossing the
  wire), and a real LAN9512 backend (VID 0x0424, PID 0xec00/0x9904;
  vendor register read/write via USB requests 0xA1/0xA0; TX_CMD_A/B
  and RX status word framing; written against the public datasheet +
  Linux's `smsc95xx.c`/`.h` reference driver — **NOT live-verified**,
  pending real Pi 1B hardware-in-loop testing).
  **FIXED, round 66 (2026-09-01)**: `dhcp_client_poll` (and likely
  other netif-layer callers) passed a hardcoded `max_len=512` to
  `netif_recv_frame` — a loopback-era assumption from when this
  project only ever talked to itself over a 512-byte queue slot. A
  REAL DHCPOFFER from an external server (590 bytes, options included)
  exceeded it and got silently dropped (`netif_recv_frame`'s own
  documented "frame bigger than caller's buffer" contract, working
  exactly as designed — the CALLER's assumption was what was wrong,
  not this function). The CDC-ECM driver itself was unaffected and
  proven correct independently (`ping`'s own frames are small enough
  to stay under this cap) — this was a separate, pre-existing
  networking-stack constant that only a genuine external NIC could
  ever have exposed.

  Fixed by auditing every 512-sized buffer/cap across netif/ARP/IPv4/
  UDP/TCP/DHCP as this entry itself specified, not a point fix: added
  a single shared `netif_frame_slot_size()` accessor (1514 bytes — a
  real 1500-byte Ethernet MTU plus the 14-byte header, matching
  `netif_get_mtu()`'s own long-standing "a real hardware netif
  implementation later would need its own, larger buffers and report
  the real 1500 here instead" comment) and replaced every hardcoded
  `512` literal that fed it — `netif_init`'s ring-buffer allocation,
  `netif_send_frame`'s cap check AND its own loopback slot-address
  arithmetic (`head * 512`), `net_send_scratch`/`net_recv_scratch`/
  `dhcp_frame_scratch`'s own allocations, and `icmp_poll`/`socket_udp_
  recv`/`tcp_conn_poll`/`dhcp_client_poll`'s own `netif_recv_frame`
  calls. Self-test-local buffers (DHCP/TCP self-tests' own synthetic
  frames, already well under the old 512) were deliberately left
  untouched.

  **Caught a real regression during this fix, not just applied it
  blind**: raising `netif_get_mtu()` alone, without raising `net_send_
  scratch`'s own allocation in lockstep, would have reintroduced a
  genuine heap buffer overflow — `ipv4_send`/`udp_send`/`tcp_send_
  segment` write directly into that scratch buffer up to `netif_get_
  mtu()`'s own bound with no independent bounds check of their own,
  confirmed by reading their bodies directly. Also caught, via the
  full self-test suite (not assumed safe): a **second, separate**
  hardcoded `tail * 512` in `netif_recv_frame`'s own loopback branch
  that mirrored `netif_send_frame`'s `head * 512` slot-address
  computation — fixing only the send side left the ring buffer's read
  and write offsets misaligned for every slot past index 0, which
  broke ARP/ICMP/UDP/TCP/DHCP's own live round-trip self-tests outright
  (the single-frame `NETIF: loopback send/recv` test itself still
  passed, coincidentally, since slot 0's address is `0 * anything = 0`
  either way) until found and fixed too. `dhcp_payload_scratch`
  (separate from `dhcp_frame_scratch`) was checked and confirmed to
  NOT need raising — it only ever holds a DHCP request THIS client
  builds itself (small, predictable, self-determined size), never the
  incoming server response.

  Verified: full regression battery green after the fix, including a
  first (broken) attempt that failed ARP/ICMP/UDP/TCP/DHCP's own live
  round-trip self-tests outright before the second bug above was
  found — `qemu_run.py`, `phase4_milestone.py` 14/14, `host_harness`
  315/315 under ASAN/UBSAN (confirms no buffer overflow from the size
  increase), `heap_stress.py`. Heap headroom cost: ~7KB (262144-byte
  heap, 139488 bytes free after boot, comfortably unaffected).

- **BLE via USB dongle (Pi 1): HCI transport (DONE, round 57,
  spec-only) + GATT/ATT/L2CAP (not started)** — `[L, several rounds —
  the HCI transport itself is done; a full usable BLE stack on top is
  its own multi-round effort, comparable to this project's existing
  TCP/IP stack]`
  USB Bluetooth HCI is an OFFICIAL, STANDARDIZED USB class (interface
  class `0xE0`/subclass `0x01`/protocol `0x01`) — `dwc2_fetch_and_
  set_configuration`'s descriptor walk detects it exactly like mass
  storage's own `0x08`/`0x06`/`0x50` check, capturing 3 endpoints
  (bulk in/out for ACL data, interrupt-in for HCI events — this
  project's first use of the interrupt transfer type,
  `dwc2_hci_interrupt_in`). HCI commands go over the control endpoint
  (`dwc2_hci_send_command`, bmRequestType=0x20/bRequest=0x00 per the
  Bluetooth Core Spec's USB Transport Layer); `hci_reset_and_scan`
  sends HCI_Reset -> LE_Set_Scan_Parameters -> LE_Set_Scan_Enable on
  enumeration, checking each Command Complete event's own opcode and
  status. Packet building/parsing (opcode encoding, command headers,
  event parsing) is pure and has real host-harness test coverage.
  **NOT live-verified**: unlike CDC-ECM (which had a real QEMU stand-in
  device), QEMU's `usb-bt-dongle` — which implemented exactly this USB
  HCI transport — was deprecated in 2018 and removed from modern QEMU
  entirely; confirmed absent from this environment's own `qemu-system-
  arm -device help`. This transport has never received a real HCI
  event in response to anything it sends, pending real Pi 1B
  hardware-in-loop testing with an actual USB Bluetooth dongle
  attached — same honesty bar as the LAN9512 NIC backend.
  **Remaining, not started**: L2CAP, ATT, and GATT (the actual protocol
  layers an application uses to scan/connect/read/write BLE
  characteristics) are a SEPARATE stack sitting above HCI, comparable
  in scope to this project's own ARP/IPv4/TCP/UDP/ICMP stack — expect
  a similar number of rounds to reach the same maturity level
  `tcpecho`/`udpecho` represent for TCP/IP today.

- **WiFi via USB dongle (Pi 1): enumeration + vendor register I/O
  (DONE, round 58) + everything else (not started, and structurally
  blocked without a real firmware blob)** — `[XL, high risk, not sized
  further beyond what round 58 delivered — still the largest, riskiest
  item in this entire backlog]`
  A specific chipset was chosen (Realtek RTL8188CU/RTL8192CU family,
  VID `0x0bda`/PID `0x8176` — confirmed against Linux's `rtl8xxxu`
  driver's own device table) rather than leaving this unscoped.
  `rtl_reg_read8/16/32`/`rtl_reg_write8/16/32` implement the chip's own
  vendor register protocol (bRequest=0x05 for both directions,
  distinguished by bmRequestType 0xC0 read/0x40 write — a different
  wire format from LAN9512's own 0xA0/0xA1 scheme, register address in
  wValue not wIndex). `rtl8188cu_probe` runs on enumeration and reads
  two registers as a structural demonstration, then deliberately stops.
  **Firmware blob loading is a hard, structural stop, not a sizing
  problem**: every real USB WiFi chipset requires uploading a
  proprietary firmware image to an embedded MCU before the radio does
  anything, and that blob is a real Realtek binary this project cannot
  derive from a public spec or fabricate — it comes from the
  `linux-firmware` project (a legally separate, redistributable binary
  collection under the vendor's own terms), never from source. This
  project fetched the real firmware (`rtlwifi/rtl8192cufw_TMSC.bin`,
  from https://gitlab.com/kernel-firmware/linux-firmware, also on
  kernel.org's own linux-firmware.git) TEMPORARILY to verify
  `rtl8188cu_probe`'s own header-format documentation is accurate
  (confirmed: 16126 bytes, 32-byte header matching `struct rtl8xxxu_
  firmware_header` exactly, signature 0x88c1 matching the driver's own
  documented case, ramcodesize field self-describing the payload length
  exactly as `file_size - 32`) — then deleted it. Never committed to
  this repository, and never will be; a deliberate project-hygiene and
  licensing boundary, not an oversight.
  **Remaining, not started, and genuinely blocked until real hardware +
  a real firmware file are both available**: (1) the MCU firmware-
  download sequence itself (`rtl8xxxu_download_firmware` in Linux's own
  `core.c` — enable download mode, write the payload in chunks via
  register writes, verify a checksum, disable download mode); (2) 802.11
  MAC-layer state machine (association, authentication) on top of
  whatever this project's netif layer already provides for Ethernet
  framing; (3) **a real AES implementation** — WPA2's CCMP encryption
  is AES-based, and this project deliberately chose ChaCha20 INSTEAD
  of AES for round 44's own crypto foundation (ARMv6 has no AES
  instructions and constant-time software AES needs a real S-box
  strategy) — meaning WiFi isn't just a driver, it's also a new crypto
  primitive from scratch.

- **Onboard WiFi/BLE for Pi 4/5** — `[not sized, explicitly deferred]`
  The user's own call: onboard chips are the target once a newer Pi's
  own port matures, not now. Blocked on the entire Pi 4/5 port
  (ARMv8 MMU/GICv2-3/BCM2711 timer/vani AArch64 backend, see the
  "Pi 4/5 port" section above) landing first, and even then inherits
  everything the WiFi item above already flags (Broadcom's own
  onboard combo chip has the SAME closed-firmware-blob problem the
  USB dongle path has, arguably worse — less public documentation
  exists for it than for common USB dongle chipsets, since Broadcom's
  SDIO/UART wireless parts are notoriously under-documented even by
  the standards of consumer WiFi silicon).
