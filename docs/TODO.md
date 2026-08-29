# Dhruva OS — open backlog

Effort buckets are relative to this project's own established
"round" cadence (see git log / project memory — one round is
typically one focused, fully-verified unit of work: build, full
self-test + `phase4_milestone.py` battery, `heap_stress.py`/
`power_yank.py`, commit). S/M/L/XL below is sized against that unit,
not calendar time.

## Storage & USB portability (Pi 4 / Pi 5 / Compute Module)

See `docs/PORTING.md` for the full writeup this backlog references.

- **Block-device abstraction for the FS layer** — `[S, ~1 round —
  DONE, round 36]`
  Replaced the FS layer's 8 real direct `sdhost_read_block`/
  `sdhost_write_block` call sites (`fs_init`/`fs_append_raw`/`fs_find_
  latest_block_raw`/`fs_compact`/`fs_read_raw` — more than the
  original ~5 estimate once actually counted; the SD driver's own
  8-block self-test sweep deliberately still calls SDHOST directly,
  since its whole point is testing that peripheral specifically) with
  calls through `fs_block_read`/`fs_block_write`. Not a function-
  pointer/vtable interface as originally envisioned here — no evidence
  vani supports storing a callable function value persistently across
  calls the way this project's own `extern "C"` state-accessor pattern
  needs, so a simple `fs_state`-backed integer selector (0=SDHOST,
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
    `write_block` call sites (`fs_init`/`fs_append_raw`/`fs_find_
    latest_block_raw`/`fs_compact`/`fs_read_raw` — more than the
    original ~5 estimate once actually counted) through `fs_block_
    read`/`fs_block_write` instead. SDHOST stays the permanent default
    (`fs_state`'s new `fs_block_dev` selector defaults to 0 via `.bss`
    zero-init) — every real FS operation (boot self-tests, shell
    `ls`/`cat`/`write`, `phase4_milestone.py`, `power_yank.py`'s own
    tear-sweep) is unaffected, confirmed by the full existing battery
    staying green unchanged. Then proved USB mass storage genuinely
    works as a second backend THROUGH the same abstraction (not just
    via round 35's own raw primitives): `fs_block_dev_self_check`
    temporarily flips the selector, writes a pattern via `fs_block_
    write`, reads it back via `fs_block_read`, byte-compares, then
    restores SDHOST. Independently verified at the host level again
    (LBA 200 in the backing image holds the real persisted pattern).
    `usb-net` (no BOT interface, selector never touched) confirmed
    unaffected.
    Scope note: this proves the raw block-I/O layer is genuinely
    backend-agnostic, live-verified both ways. It does NOT mean the OS
    can boot/operate its whole filesystem from a USB drive yet — that
    would need selecting the backend before `fs_init()` runs (today
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
     primitives for (`fs_block_read`/`fs_block_write` genuinely work
     against USB mass storage) — what's still missing is selecting
     that backend BEFORE `fs_init()` runs and validating the full
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
  the existing `fs_block_dev` selector — pick it before `fs_init()`
  runs instead of only inside `fs_block_dev_self_check`, and validate
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
  460-byte-per-block payload cap (`fs_block_payload_cap()`); files up
  to 4096 bytes (`fs_file_max_len()`) now chain across multiple
  blocks. `path_len == 0` is a reserved continuation-block sentinel
  (real lookups always have `path_len > 0`, so `fs_find_latest_block_
  raw`'s matching logic needed zero changes; `fs_compact`/`fs_list`
  needed an explicit skip-continuation-blocks guard added to their
  full-table scans). Crash safety: multi-block writes happen in
  *reverse* order — every continuation chunk first, the head block
  written *last* — so the head's own single-block atomic write is the
  one commit point that makes the whole chain reachable; a crash
  before it leaves only unreachable orphan blocks and the prior
  version of the file (or no file) intact, exactly like the existing
  single-block torn-write case. `fs_read`/`fs_read_raw` were
  consolidated (the old duplicated block-reading logic in `fs_read` is
  gone). Verified: two new self-tests (a real 1000-byte/3-chunk
  round-trip + overwrite, and a simulated-crash test that raw-writes
  an orphan continuation block without ever calling `fs_state_set` —
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

  **Still open**: real directory hierarchy (path-segment parsing,
  directory metadata, real hierarchical `ls` instead of prefix
  filtering) — deferred to a future round of this item.

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

  **Still open**: a symmetric cipher (ChaCha20 over AES: AES's
  standard software implementations lean on table lookups that are a
  timing-side-channel risk on hardware WITH a cache; ChaCha20 was
  designed for fast, naturally constant-time software implementation
  without them, and ARMv6 has no AES instruction extension to fall
  back on regardless — same `sha256_wrap_add32`-style wraparound
  workaround will be needed for its own add-rotate-xor quarter
  rounds). Bignum/asymmetric primitives (ECC point arithmetic, at
  minimum, for anything below needing real signatures) are a separate,
  larger sub-effort on top of both. Fully QEMU-testable via the
  ChaCha20 RFC 8439 known-answer test vectors, same technique as
  SHA-256 above.

- **Packet filtering / iptables-equivalent** — `[M, ~2-3 rounds]`
  A rule table (allow/deny by src/dst IP, port, protocol) with a hook
  at each protocol's own `*_poll` entry point
  (`icmp_poll`/`socket_udp_recv`/`tcp_conn_poll`), dropping a match
  before it reaches the state machine. Doesn't need real crypto or
  real off-box networking to build or verify the RULE-MATCHING logic
  itself — synthetic crafted frames (the same technique `tcp_conn_
  recv_bounds_self_test`/`netif_queue_contention_self_test` already
  use) exercise it fully under QEMU. Real value is currently capped by
  this project's own loopback-only netif (see the Dhruva Feature
  Ledger's "known real-hardware-only gaps" — DHCP never actually binds,
  `ping` only ever reaches itself) — a filter has nothing genuinely
  hostile to filter against until real off-box traffic exists, but the
  mechanism is honestly buildable and testable now regardless.

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

- **Media (at-rest) encryption** — `[M-L, ~2-3 rounds beyond the
  crypto foundation]`
  Encrypt FS blocks before `fs_block_write`/after `fs_block_read`
  (the block-device abstraction rounds 33-36 built is the natural
  integration point — a cipher becomes a transform in that same
  pipeline, not a separate subsystem). Needs a key-management story
  this hardware can't help with: BCM2835 has no TPM, no secure
  element, no hardware key storage of any kind, so a key has to come
  from somewhere software-only (a passphrase-derived key entered at
  boot, most realistically) — that's a real design decision to make
  up front, not a detail to defer.

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
  project's own networking is still loopback-only/demo-scoped (per the
  Dhruva Feature Ledger), so the threat PQC exists to counter doesn't
  apply to anything Dhruva actually does yet. Not recommended before
  the classical crypto foundation above exists AND real off-box
  networking is a going concern — at that point, this is worth
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

## Pi 4/5 port — now started (round 40, opening research + spike)

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

Remaining scope for a real Pi 4 boot, now precisely identified rather
than assumed:

- ARMv8-A EL3→EL1 (or EL3→EL2→EL1) exception-level drop — new,
  ARM1176 has no equivalent.
- Real AArch64 exception vector table (`VBAR_EL1`, 16 entries) —
  `boot/rpi1/vectors.S` is ARMv6-specific and doesn't carry over.
- ARMv8-A MMU (TTBR0_EL1/TCR_EL1, radically different from ARMv6's
  short-descriptor 1MB sections used in `boot/mmu_init.S`).
- GICv2/GICv3 interrupt controller (replaces BCM2835's simple
  interrupt controller — `timer_ic_init` and everything built on it).
- BCM2711 generic ARM timer at new peripheral addresses (same timer
  core the scheduler already assumes, different base).
- Only after all of the above: EMMC2 (storage) and XHCI (USB) drivers
  from scratch — both already flagged above as substantially larger
  than their Pi 1 SDHOST/DWC2 counterparts.

Still not sized (each of the bullets above is its own multi-round
effort); the spike above is validation/scoping only, not yet checked
into the repository.
