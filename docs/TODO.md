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

- **AES** — `[L, genuinely harder than it sounds — not yet begun,
  added 2026-08-30 per explicit request]`
  Two real, independent reasons to want it despite round 44's own
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

- **TLS** — `[XL, several rounds — genuinely blocked on multiple
  prerequisites above, not ready to start; added 2026-08-30 per
  explicit request]`
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

- **Long-running synchronous computation stalls permanently under the
  real scheduler** — `[found round 61, 2026-08-30, NOT YET ROOT-
  CAUSED — high priority]`
  Found while tuning real authentication's own PBKDF2 iteration count.
  A synchronous, non-yielding loop (no `task_sleep_ticks` calls) run
  from the interactive shell (`task_f`), once it survives enough timer
  ticks under the real post-`start_multitasking` scheduler, reliably
  **stops making progress permanently partway through** — not merely
  slowly, genuinely stuck: an independent, unconditional per-iteration
  counter (not just a debug print's own condition) stopped advancing
  too, and stayed flat across a 4-minute observation window with zero
  further progress. The identical loop body completes correctly and
  quickly when run at boot, before `start_multitasking` — single-
  threaded, no interrupts enabled yet.

  **Ruled out, not just suspected**: a priority-ceiling boost
  (`dhruva_prio_lock(0)`/`dhruva_prio_unlock`) around the computation
  was tried first (reasoning: `task_f`'s own priority 3 could starve it
  behind more-frequently-ready higher-priority demo tasks) and
  measured to make **no reliable difference** — the same stall
  reproduced with or without it, ruling out simple priority starvation
  as the root cause. The function's own parameters were also confirmed
  correct at entry via direct instrumentation (`iterations`/
  `password_len`/`salt_len` all printed exactly as passed) and stayed
  correct — the bug is not argument corruption, nor is it the debug
  print's own modulo condition (an independent, unconditional counter
  incrementing every real loop iteration showed the same flat-lining).

  Empirically bounded, not fully root-caused: 200 iterations of this
  specific loop shape reliably completes in ~1 real second; 500
  reliably never completes at all, confirmed across multiple runs.
  Whatever triggers this appears to depend on cumulative time/tick
  count survived by one continuously-running computation, not on the
  exact operation being performed.

  Candidate next steps for a dedicated follow-up round (not attempted
  here — this needs its own focused investigation, not a side effect
  of an unrelated feature's own time budget): reproduce with a GDB/
  QEMU-monitor breakpoint once the stall is observed, to get a real
  register/PC snapshot of exactly where `task_f` is stuck; audit
  whether `sleep_until_table`/`eff_prio_table`/`current_task` can be
  corrupted by an interaction between a long-held ceiling boost and
  the mutex-inheritance demo's own eff_prio writes (rounds 55/59, the
  first other consumer of a comparably long-running, heavily-preempted
  computation); check whether AAPCS 64-bit (`i64`) local variables
  held live across MANY repeated preemptions of the SAME function
  activation are correctly preserved by this project's context-switch
  frame (an untested case — no prior task in this codebase holds an
  `i64` local across anywhere near this many ticks). This is a
  genuine reliability concern beyond just authentication: ANY future
  feature needing a long synchronous computation from a task will hit
  the same wall.

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
  the crypto foundation above]`
  Real PKI means X.509 certificate parsing (a nontrivial ASN.1/DER
  parser, a genuinely large and historically bug-prone piece of code
  in any language) plus chain-of-trust validation against root CAs.
  Depends entirely on the crypto primitives item above (signature
  verification needs working asymmetric crypto first). A realistic
  FIRST increment, if ever started, is raw public-key trust (pin a
  known key, verify a signature against it directly) with no X.509/CA
  chain at all — full X.509 is a separate, much larger step after
  that, not a package deal.

- **Media (at-rest) encryption** — `[M-L, ~2-3 rounds — the crypto
  foundation this was scoped behind is DONE (round 44's ChaCha20);
  another concretely unblocked candidate]`
  Encrypt FS blocks before `dharafs_block_write`/after `dharafs_block_read`
  (the block-device abstraction rounds 33-36 built is the natural
  integration point — a cipher becomes a transform in that same
  pipeline, not a separate subsystem). ChaCha20 (round 44,
  `chacha20_encrypt`) is a perfectly real cipher choice for this —
  unlike WPA2/WiFi (round 58's own note), at-rest encryption isn't a
  standardized protocol demanding AES/CCMP specifically, so no new
  crypto primitive is needed here at all, just wiring the existing one
  in. Still needs a real design decision up front, not a detail to
  defer: a key-management story this hardware can't help with (BCM2835
  has no TPM, no secure element, no hardware key storage of any kind),
  so a key has to come from somewhere software-only — a passphrase
  entered at boot (via the existing UART shell) is the most realistic
  starting point, with a KDF deriving the actual ChaCha20 key from it
  — PBKDF2-HMAC-SHA256, the SAME primitive the "Real authentication"
  item above needs; build whichever of the two comes first and the
  other reuses it, rather than two independent KDF implementations.
  Nonce management also needs a real answer (ChaCha20's 96-bit nonce
  must never repeat under the same key — a per-block counter derived
  from the block number itself, matching this project's own `dev`/
  block-number addressing already in `dharafs_block_read`/`_write`, is
  the natural choice, not a random nonce needing its own persistent
  state). **Also needs Poly1305** (see the crypto-foundation gap noted
  above) — raw ChaCha20 alone gives confidentiality with no integrity,
  meaning a corrupted/tampered block would decrypt to silently wrong
  data instead of being detected; not real security without it. Lower
  priority than packet filtering above (no live-traffic angle to
  demonstrate it against the way filtering now has), but genuinely
  ready to start whenever picked up.

- **Secure boot** — `[not sized — hits the SAME hard hardware ceiling
  as USB boot, see docs/TODO.md's own USB-boot feasibility note above]`
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

- **Append-only log convenience API** (`dharafs_log_open`/`_append`/
  `_sync`, automatic rollover across numbered files) — `[M, ~1-2
  rounds]`
  The underlying primitives (append, checksum, chain-follow) already
  support this; what's missing is the ergonomic layer for the
  sensor-logging use case specifically (rollover to a new numbered
  file at a size threshold, sequence numbers, GC of old rolled files).
  A genuinely scoped, near-term-buildable win — no new on-disk format
  needed, just new entry points over the existing one.

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

- **`dhruva diagnose` shell command** — `[S, ~1 round — cheapest
  possible first step]`
  Nearly all of its inputs already exist as extern accessors:
  `dhruva_heap_used_bytes`, `scheduler_ready_count`,
  `scheduler_get_tick_count`, `governor_get_last_applied_mhz`/
  `governor_history_get0..3`. This item is mostly "add a shell command
  that formats what's already there into one readable report" plus a
  couple of genuinely new counters (deadline misses, allocation
  failures — the latter now meaningful since this session's round 45
  gave `dhruva_alloc_bytes` a real, countable OOM-fatal path instead of
  silent NULL). The single best first round of this whole section —
  low effort, immediately useful, and every later item in this
  subsection adds another row to the same report rather than needing
  its own new command.

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
  `[M-L, ~3-4 rounds combined, not started — genuinely blocked on a
  real workload, not just unscoped]`
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

- **Fault injection framework** — `[M, ~1-2 rounds — allocation-failure
  half DONE, round 51; FS write latency/IRQ bursts/forced
  retransmission not started]`
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

- **"Why is my task late?" query + determinism-certificate report** —
  `[L, not started — blocked on the deadline model AND the event ring
  buffer above, in that order]`
  The causal-chain explanation (blocked on mutex X for Y us, preempted
  by IRQ Z for W us) needs the deadline model to know a task WAS late
  in the first place, and the event ring buffer to reconstruct WHY —
  genuinely the most sophisticated item in this list, correctly last
  in the brainstorm doc's own ordering, and doubly blocked since the
  deadline model itself waits on a real workload (see its own note
  above). Don't start this before that exists.

- **Incident/flight-recorder capture on watchdog reset** — `[L, not
  started, currently blocked on a real gap]`
  `watchdog_arm`/`watchdog_init`/`watchdog_kick` already exist
  (Phase 2), but `watchdog_kick`'s own comment notes it is NOT
  currently called anywhere in the scheduler loop — so today a real
  hang would never actually trigger a watchdog reset to capture an
  incident from. Wiring `watchdog_kick` into the real per-tick path is
  a real prerequisite this item depends on, not just missing
  instrumentation around an existing reset path.

- **CI-integrated real-time regression thresholds** — `[M, not started
  — blocked on the histogram work above, AND on accumulating real
  baseline data]`
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

- **Production vs. developer profiling levels** — `[S-M, once
  something above exists to gate]`
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
  **Found via live testing, not fixed in this round** (real,
  pre-existing, in scope for a future round): `dhcp_client_poll` (and
  likely other netif-layer callers) pass a hardcoded `max_len=512` to
  `netif_recv_frame` — a loopback-era assumption from when this
  project only ever talked to itself over a 512-byte queue slot. A
  REAL DHCPOFFER from an external server (590 bytes, options included)
  exceeds it and gets silently dropped (`netif_recv_frame`'s own
  documented "frame bigger than caller's buffer" contract, working
  exactly as designed — the CALLER's assumption is what's now wrong,
  not this function). The CDC-ECM driver itself is unaffected and
  proven correct independently (`ping`'s own frames are small enough
  to stay under this cap) — this is a separate, pre-existing
  networking-stack constant that only a genuine external NIC could
  ever have exposed. Raising it needs auditing every 512-sized
  buffer/cap across netif/ARP/IPv4/UDP/TCP/DHCP consistently, not a
  point fix — deliberately scoped OUT of this round.

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
