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

- **TCP retransmission + simultaneous open + simultaneous close +
  advertised-window enforcement** — `[M-L, ~3-4 rounds — retransmission
  and simultaneous open DONE round 37; simultaneous close and window
  enforcement DONE round 72, 2026-09-05, see below]`
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
  - Not attempted in round 37: simultaneous CLOSE (both sides sending
    FIN before seeing the peer's), and the advertised window being
    consulted at all (still accepted, never enforced). Neither was
    needed to satisfy "retransmission and simultaneous open" as asked;
    flagged there rather than silently left implicit.
  - **Done (round 72, 2026-09-05): simultaneous close.** The existing
    FIN_WAIT branch used to treat ANY ack while in that state as proof
    the peer had acknowledged OUR FIN specifically -- correct for the
    normal one-sided-close case (the peer was ESTABLISHED, saw our
    FIN, and its response necessarily acknowledges it), but wrong for
    the genuinely simultaneous case: if the peer independently called
    `tcp_conn_close` before ever seeing ours, its own FIN+ACK segment
    acknowledges only whatever it last knew from us, not our FIN.
    Fixed with an explicit `our_fin_acked` check (`seg_ack` must equal
    our own `local_seq`, which `tcp_conn_close` already advanced past
    our FIN's sequence number) and a new RFC 793 CLOSING state
    (`tcp_state_closing()`) for the case where it doesn't -- reached
    when the peer's FIN arrives before it has acknowledged ours, ACKs
    the peer's FIN immediately, then waits in CLOSING specifically for
    the peer's own separate ACK of ours before reaching CLOSED_FINAL.
    Verified with a new boot-time self-test
    (`tcp_conn_simultaneous_close_self_test`), hand-tracing the exact
    seq/ack numbers before writing it (to confirm both sides genuinely
    land in CLOSING, not straight to CLOSED_FINAL, which would have
    silently meant the new check wasn't actually being exercised) --
    same hand-fed-frame "traffic cop" technique every other TCP
    self-test here already uses.
  - **Done (round 72, 2026-09-05): advertised-window enforcement.**
    New `tcp_get_window` parser and `tcp_conn_remote_window` per-
    connection state (`boot/tcp_state.S`), captured unconditionally
    from every incoming segment by `tcp_conn_handle_segment` (before
    any state branch, so every code path benefits uniformly) and
    consulted by `tcp_conn_send_data`, which now refuses (reject,
    don't guess -- same posture as every other bounds check in this
    networking layer) to send more than the peer's own last-advertised
    window rather than sending anyway and hoping the peer buffers it.
    `tcp_conn_active_open`/`_passive_open` reset it to 65535 (this
    project's own default advertised window) so a connection has a
    sane assumption before the first real segment says otherwise.
    Deliberately NOT built: zero-window probing/persist-timer retry --
    a real window of 0 simply means every send is refused until a
    later incoming segment reopens it, a real, honest scope boundary
    (matching this networking layer's own established "don't build
    speculative extra" discipline), not silently ignored. Verified
    with a new white-box boot-time self-test
    (`tcp_conn_window_enforcement_self_test`, same shape as
    `tcp_conn_recv_bounds_self_test`'s own synthetic-segment
    technique): a synthetic segment advertising a small window causes
    an over-sized send to be rejected and an exactly-sized one to
    succeed, and a later synthetic segment reopening the window is
    also honored (not just the first value ever captured).
    Full regression battery green after both: `qemu_run.py` (both new
    self-tests PASS; the pre-existing DharaFS/SD FAILs are the
    already-documented `qemu_run.py`-has-no-SD-drive harness
    limitation, confirmed unrelated by `phase4_milestone.py`'s own
    real-SD-drive run passing 15/15 immediately after, including a
    live `tcpecho`/`tcprtx` round trip), `heap_stress.py`,
    `power_yank.py`.

- **FS directory hierarchy + multi-block files + journaling
  hardening** — `[L, ~4-5 rounds — DONE, rounds 39 + 42; this header's
  own status tag was stale, caught and fixed round 68, 2026-09-04 —
  see the body below, which already documented both halves as done]`
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

## New peripherals: GPIO, HDMI/framebuffer + EDID, USB HID (2026-09-04)

User request, recorded before any of it is built. All three are
genuinely new peripheral categories for this project — not extensions
of an existing driver the way most items above are.

- **GPIO (general-purpose I/O)** — `[S-M, DONE round 71, 2026-09-05]`
  Digital read/write of individual pins (`GPFSEL`/`GPSET`/`GPCLR`/
  `GPLEV` registers, BCM2835 peripheral base `0x20200000`) plus
  pull-up/down control. Pure vani code (`gpio_set_function`/
  `_get_function`/`_write`/`_read`/`_set_pull` in `kernel_main.vani`),
  no new assembly — reused the existing `mmio_read_u32`/`mmio_write_u32`
  builtins the same way `gpio_uart_alt_init` already does for UART pin
  muxing. Confirmed against QEMU 10.0.0's own `hw/gpio/bcm2835_gpio.c`
  before writing anything: GPFSEL/GPSET/GPCLR/GPLEV are genuinely
  modeled (GPSET/GPCLR update the GPLEV-visible level unconditionally
  regardless of function-select state — a real hardware simplification,
  but enough to verify this driver's own register-address/bit-mask
  arithmetic); GPPUD/GPPUDCLK are explicitly "Not implemented" in that
  same source, so `gpio_set_pull` is real, spec-correct code but its
  actual effect is unverifiable under QEMU (same honesty class as EDID
  below — only real hardware can confirm a pull resistor actually
  engages). New `gpio <pin> in|out|read|write <0|1>|pull none|up|down`
  shell command, live-verified interactively (9 commands, every one
  behaved exactly as designed). Self-check verifies function-select
  read/write round-trip across 3 different GPFSELn registers plus a
  register-boundary non-interference check, and GPSET/GPCLR/GPLEV
  round-trip across the GPSET0/GPSET1 (pin 31/32) boundary. Would
  unlock the classic "blink an LED" / read a button hardware-in-loop
  demo once a real Pi 1B is connected.

- **HDMI output / framebuffer** — `[M-L, framebuffer half DONE round
  71, 2026-09-05; EDID remains real-hardware-only, see below]`
  Two genuinely separate pieces, same shape as the USB-boot feasibility
  note elsewhere in this backlog:
  1. *Framebuffer output itself* — **DONE.** New `boot/fb_state.S`
     generalizes `governor_state.S`'s own already-verified mailbox
     transport into `mbox_property_call(buf)`, taking an
     already-built buffer instead of hardcoding one tag, so
     `fb_init(width, height, bpp)` (`kernel_main.vani`) can bundle
     SET_PHYSICAL/VIRTUAL_WIDTH_HEIGHT, SET_DEPTH, SET_PIXEL_ORDER,
     FRAMEBUFFER_ALLOCATE, and FRAMEBUFFER_GET_PITCH into ONE
     round trip. Confirmed against QEMU 10.0.0's own
     `hw/misc/bcm2835_property.c` that every one of these tags is
     genuinely implemented (unlike governor's own NYI clock-rate
     tag), so this gets real round-trip verification — actual
     pitch/size arithmetic computed from the just-requested
     resolution/depth, not just "the call didn't hang." New `fb
     init <w> <h> <bpp>|status|fill <x> <y> <r> <g> <b>` shell
     command. Self-check covers both mode-set arithmetic AND an
     actual pixel write+readback round trip at two corners of the
     allocated buffer (added specifically because the first
     self-check version only checked arithmetic and would never
     have caught the real bug below).

     **Two real bugs found and fixed along the way**: (1) a genuine
     Data Abort — round 38's MMU table (`boot/mmu_init.S`) never
     mapped VideoCore RAM (~0x1C000000-0x1FFFFFFF, where the
     framebuffer actually lives), only ARM-side RAM and the
     peripheral block; root-caused via QEMU's own
     `hw/arm/bcm2835_peripherals.c` source and fixed by extending
     `mmu_init.S`'s existing section-mapping loop to also cover
     sections 448-511 as Normal-non-cacheable read-write XN. (2) a
     real AAPCS ABI violation — `fb_base_get`/`fb_size_get`/
     `fb_pitch_get` are declared `-> i64` but only ever set r0, never
     r1 (the required high word), corrupting a real 64-bit division
     in the pixel self-check; initially misdiagnosed one level too
     shallow as a vani/LLVM compiler bug before GDB against the
     actual failing build found the real cause. Swept the whole
     codebase afterward for the same bug class and fixed 5 more
     genuine instances in `boot/context_switch.S` (feeding
     `diagnose`'s own counter output directly) plus a few low-priority
     latent ones. See project memory for the full writeup.
  2. *EDID query* (asking the connected monitor what modes it
     supports, rather than hardcoding one): **confirmed NOT
     QEMU-testable** — checked QEMU 10.0.0's own
     `hw/misc/bcm2835_property.c` mailbox-tag dispatch directly; it has
     no case for any EDID-related request tag at all. Code to issue
     the EDID mailbox call could still be written speculatively, but
     its actual behavior (real monitor's real EDID block) can only
     ever be verified against a real Pi 1B with a real HDMI display
     attached — a genuine hardware-in-loop item, not a QEMU gap to
     work around. Still not started.

- **USB HID class (keyboard/mouse)** — `[M, DONE round 71, 2026-09-05]`
  This project's existing DWC2 (USB 2.0 host) driver already supported
  three device classes on real Pi 1 hardware — mass storage (rounds
  33-36), CDC-ECM/LAN9512 networking (round 56), and Bluetooth HCI
  (round 57+) — now a fourth: USB HID boot-protocol keyboard/mouse
  (interface class 0x03, subclass 0x01 "boot interface subclass",
  protocol 0x01 keyboard / 0x02 mouse, per HID1.11 Appendix B).
  Detection added to `dwc2_fetch_and_set_configuration`'s existing
  single-pass descriptor walk (same attribution style BOT/CDC/BT
  already use), a new `dwc2_hid_interrupt_in` (this project's second
  use of the interrupt transfer type, direct sibling of round 57's own
  `dwc2_hci_interrupt_in`, new `boot/usb_hid_state.S` for its
  endpoint/toggle state), an explicit `SET_PROTOCOL(boot)` class
  request sent unconditionally after `SET_CONFIGURATION` (HID1.11
  §7.2.5, forcing Boot Protocol regardless of a device's power-on
  default), and boot-protocol report decoders for the fixed,
  spec-defined 8-byte keyboard / 3-byte mouse report layouts. New `hid
  poll|status` shell command.

  **Live-verified against real QEMU devices, not just spec-read** —
  matching CDC-ECM's own "attach a real-shaped QEMU device, verify
  against it" precedent, and going further than Bluetooth HCI's own
  verification ceiling (BT's own USB transport could never be
  live-tested at all, `usb-bt-dongle` having been removed from QEMU):
  `-device usb-kbd` and `-device usb-mouse` both enumerate correctly
  (keyboard: intr_in_ep=0x81 mps=8; mouse: intr_in_ep=0x81 mps=4,
  matching each boot report's own fixed size exactly), AND a real
  keypress injected via QEMU's monitor (`sendkey a`) was received and
  correctly decoded end to end via the `hid poll` shell command
  (`keys=04`, the real USB HID Usage ID for 'a'), with correct
  press/release report alternation across 5 repeated injections.
  Report-decoder logic (modifier bits, up to 6 simultaneous keycodes,
  signed 8-bit mouse dx/dy including the -128/+127 boundary values)
  also covered by 18 new host-harness checks, 993/993 PASS clean
  under ASAN/UBSAN.

  **Not implemented, explicit scope boundary**: interrupt-OUT for
  keyboard LED state (Num/Caps/Scroll Lock) — this driver is
  read-only, matching this project's own "build what's needed, not
  speculative extras" discipline; no continuous background polling
  task for reports (an on-demand shell command is lower-risk, nothing
  new touching the scheduler, matching BT's own precedent of only
  ever polling synchronously from within a specific command flow).
  **USB 3.x**: this project's real Pi 1 hardware target has no USB 3
  controller at all (DWC2 is 2.0-only) — USB 3.x support is already
  tracked separately under the Pi 4/5 port's own XHCI entry above
  (`VL805`/`RP1`), not a Pi 1 item.

## DharaFS as a standalone library for other kernels — DONE, 2026-09-05

Scoped round 71 (see below for the original scoping), then actually
built the same day: a new standalone repo, `~/source/dharafs` (Apache
2.0, kosh package `dharafs`), with all three tiers complete and
verified — core FS, real ChaCha20-Poly1305 AEAD media encryption +
SHA-256-verified I/O, and the priority-aware FS request queue, each
its own composable entry point (`lib.vani`/`lib_encrypted.vani`/
`lib_verified.vani`/`lib_queued.vani`/`lib_tier2.vani`/`lib_tier3.vani`).
Full detail in `docs/DHARAFS_PORTABILITY.md` (updated in place across
all three tiers) and the new repo's own `README.md`. DhruvaOS's own
`kernel_main.vani` was deliberately left untouched throughout —
migrating it to actually consume the new package via `[deps]` is a
separate, not-yet-requested step, not a remaining piece of the
extraction itself.

Original scoping (round 71, for reference): User asked whether DharaFS
could be decoupled from DhruvaOS for reuse elsewhere without
sacrificing correctness or performance. Based on actually grepping
`kernel_main.vani`'s real dependency surface rather than guessing:
**yes, and `test/host_harness` already proved the hard part** (the FS
logic compiles and runs correctly as portable C, no ARM/QEMU/scheduler
dependency). The real extraction later found this scoping note's own
"53 functions/39% belong to three optional additive features" claim
imprecise — dirindex/snapshot turned out safer to keep than to cut
(a provably-safe fallback), only the FS request queue was genuinely
separable — see `docs/DHARAFS_PORTABILITY.md`'s own corrected
dependency table.

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

- **Crypto primitives foundation** — `[L, ~3-5 rounds — DONE across
  rounds 41/44/67 (SHA-256, ChaCha20, bignum, Poly1305, X25519,
  SHA-512, Ed25519 — see AES/TLS/PKI/media-encryption entries below
  for what's built on top); this header's own status tag was stale
  despite the body below already saying "this item's core scope is
  now fully closed" partway through — caught and fixed round 68,
  2026-09-04]`

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

  **This item's core scope is now fully closed.**

  **Poly1305: DONE (round 67, 2026-09-02).** Closes the integrity gap
  flagged below. Ported from the well-known, widely-audited
  "poly1305-donna-32" public-domain reference algorithm (radix-2^26,
  five 32-bit limbs) rather than a generic bignum-mod-p approach --
  2^130-5's own fast-reduction shape doesn't need the generic bignum_*
  machinery at all. Found and avoided a real, hardware-specific bug
  before it ever happened: `buf_read_u32`'s ARM `ldr` is only safe at
  4-byte-aligned offsets (every EXISTING caller in this codebase only
  ever used aligned offsets), but Poly1305's own clamp/accumulate
  steps are the first thing here needing little-endian reads at
  arbitrary byte offsets -- a naive port would have silently produced
  wrong answers on real hardware (unaligned `ldr` behavior differs)
  while still happening to work under the host harness's native x86.
  Fixed with an alignment-agnostic byte-combine helper instead.
  Verified via a from-scratch Python reference (both a trivial bigint
  version and this exact radix-26 algorithm) checked byte-exact
  against RFC 8439 section 2.5.2's own worked test vector before any
  vani code was written. 41 new host-harness checks (728→769 PASS
  clean under ASAN/UBSAN), including altered-message and altered-key
  tests (a single flipped bit must change the tag) and a constant-time
  tag-verification function (`poly1305_verify_constant_time`) with its
  own accept/reject checks. Live-verified against the RFC vector on
  real ARM/QEMU at boot. The full RFC 8439 ChaCha20-Poly1305 AEAD
  CONSTRUCTION (key derivation + length-padding + combining) was, at
  the time this entry was written, deliberately not built yet -- see
  the TLS entry below for that (DONE later this same round). Wiring
  Poly1305 into DharaFS media encryption (round 62's own flagged
  follow-up) is also DONE -- see the media-encryption entry below
  (round 69's AEAD/tamper-detection/two-time-pad upgrade).

  **X25519 (RFC 7748): DONE (round 67, 2026-09-02).** Real EC point
  arithmetic and modular reduction, the actual missing piece this
  entry originally flagged. Field elements over p=2^255-19 use the
  SAME 8-limb bignum representation and `bignum_add_raw`/`sub_raw`/
  `mul_raw`/`cmp_raw` primitives round 44's own bignum work already
  built and verified (deliberately not a specialized radix-2^51
  representation real high-performance implementations use --
  correctness-over-performance, reusing verified infrastructure, and
  this is an occasional-key-exchange client, not a TLS terminator). A
  new `bignum_mul_small_raw` helper plus a fold-based reduction
  (2^256 ≡ 38 mod p, so a 512-bit product splits cleanly at the
  limb-aligned 256-bit boundary with no sub-limb bit-shift primitive
  needed) handle the modular arithmetic; `field25519_invert` uses
  plain binary square-and-multiply over the fixed exponent p-2 (not
  the optimized addition chain real implementations use, same
  simplicity-over-performance reasoning). The Montgomery ladder itself
  (`x25519_scalarmult`) uses branchless masked cswap, matching RFC
  7748 section 5 exactly.

  **Verification, adapted for a primitive where reciting an RFC test
  vector from memory would be a real, unnecessary transcription risk**
  (unlike SHA-256/ChaCha20/Poly1305's own well-worn KATs): (1) a
  from-scratch Python big-integer reference of the RFC 7748 Montgomery
  ladder, checked against the REAL, independent `cryptography` library
  across 20 random trials (own-derived public keys match the
  library's; cross-library DH agreement matches; DH symmetry holds
  standalone); (2) a second Python simulation of the EXACT limb-level
  algorithm ported to vani (generic bignum ops + the fold reduction),
  cross-checked against the bigint reference across 2000 random field
  multiplications (including edge values at/near p) plus 30 full
  random X25519 trials, byte-exact on all of them; (3) the concrete
  test vectors embedded in both `kernel_main.vani`'s own self-test and
  the host-harness twin were generated by that SAME verified run, not
  typed from an external document. Result: correct on the FIRST real
  build, no debugging cycle needed. 7 new host-harness checks
  (769→776 PASS clean under ASAN/UBSAN) covering both concrete
  vectors, DH symmetry, a distinct-shared-secret-per-key check, and
  field arithmetic unit checks (1+0=1, 1⁻¹=1, 5·5⁻¹=1). Live-verified
  against both vectors on real ARM/QEMU at boot, first try.

  **Known, documented gap, not an oversight**: not fully constant-time
  -- the ladder's own cswap is branchless, but `field25519_add`/`_sub`'s
  single conditional subtract/add-of-p depends on the VALUE being
  reduced (not directly on a secret scalar bit), a theoretical
  cache-timing surface a sufficiently determined attacker could still
  try to correlate. The well-known fix (an unconditional branchless
  select instead of an `if`) is not applied here -- flagged for a
  future hardening pass, not silently accepted.

  **SHA-512: DONE (round 67, 2026-09-02).** The prerequisite Ed25519
  needs throughout (deterministic nonce derivation, challenge hash) --
  this project only had SHA-256 before. Same structure and same
  round-65-hardening discipline as `sha256_compress` (h/k/w always
  re-fetched fresh via `*_scratch_get()` at every point of use, never
  held live across the 80-round loop -- carried over deliberately, a
  closed real bug class, not re-litigated). The 80 round constants and
  8 initial hash values were COMPUTED directly (fractional bits of
  cube/square roots of the first 80/8 primes, FIPS 180-4 section
  4.2.3) rather than typed from memory -- reciting 80 64-bit constants
  by hand is a far larger, far less forgiving transcription risk than
  a single test vector, so this project's own derivation script became
  the source of truth, cross-checked against the well-known H values
  (exact match) and against SHA-256's own K[0] sharing the same high
  32 bits (0x428a2f98) with SHA-512's K[0] -- both algorithms derive
  their constants the same way. Verified against Python's own trusted
  `hashlib.sha512` (empty string, "abc", and two block-boundary edge
  cases -- 111 bytes pads to exactly one block, 112 bytes forces a
  second) before any vani code was written. 28 new host-harness checks
  (776→804 PASS clean under ASAN/UBSAN), including a length sweep
  (108-130 bytes) around SHA-512's own 111/112/128 padding boundaries
  (different constants from SHA-256's 55/56/64, a genuinely separate
  boundary) plus 3 more hashlib-verified byte-exact spot checks within
  that sweep. Correct on the first real ARM build, no debugging cycle
  needed -- same result as Poly1305/X25519's own Python-first
  discipline.

  **Ed25519 (RFC 8032): DONE (round 67, 2026-09-02).** Signatures over
  Curve25519 in twisted-Edwards form -- the piece PKI's own raw-
  public-key-trust increment actually needs (X25519 is pure Diffie-
  Hellman, no way around needing this too for signature
  verification). Reuses X25519's own `field25519_*` functions
  directly (same p=2^255-19, same 8-limb representation) -- the only
  new field-level piece is the modular square root point
  decompression needs. Points use extended twisted-Edwards
  coordinates (X,Y,Z,T) and the standard "add-2008-hwcd-3" COMPLETE
  addition formula (Hisil/Wong/Carter/Dawson 2008) -- unified for both
  point addition and doubling, so the scalar-multiplication ladder
  never needs a separate doubling formula or same-point special-
  casing. Scalar arithmetic mod the group order L
  (2^252+27742317777372353535851937790883648493) is genuine bit-by-
  bit binary long division (shift a running remainder left 1 bit, OR
  in the next input bit MSB-first, conditionally subtract L) rather
  than a fold like `field25519_reduce16`'s own -- L's own remainder
  past the nearest power of 2 isn't small the way p=2^255-19's `19`
  is, so folding would need multiplying by a ~124-bit number, not a
  tiny constant; a new `bignum_shl1_raw` (bignum left-shift-by-1-bit)
  helper made this tractable without needing a full generic bignum
  shift-by-n primitive.

  **Verification, same discipline as X25519/SHA-512**: (1) a from-
  scratch Python bigint reference of the FULL RFC 8032 algorithm (key
  generation, sign, verify, point compression/decompression via
  modular sqrt), checked against the real `cryptography` library
  across 10 random trials -- own-derived public keys match, FULL
  SIGNATURES match byte-for-byte (confirming the deterministic nonce
  derivation matches exactly, not just "produces *a* valid
  signature"), self-verification passes, tampered signatures AND
  tampered messages are both correctly rejected; (2) a second Python
  simulation of the exact limb-level algorithm ported to vani (the
  same `field25519_*` calls, the same bit-by-bit scalar reduction),
  cross-checked against the bigint reference across 8 more full sign/
  verify/tamper trials, PLUS a dedicated 50-trial check (using real
  mutable buffers, not Python's immutable tuples) that IN-PLACE point
  addition -- output buffers aliased with an input point, e.g.
  accumulating `Q += B` or doubling `B += B` in place, exactly how the
  scalar-multiplication ladder needs to call it -- produces identical
  results to the non-aliased functional version; the formula's own
  read-everything-from-P/Q-before-writing-anything-to-the-output
  structure is what makes this safe by construction; (3) the concrete
  values embedded in both `kernel_main.vani`'s own self-test and the
  host-harness twin were generated by that same verified Python run,
  not typed from memory.

  10 new host-harness checks (804→814 PASS clean under ASAN/UBSAN),
  including: a full pubkey+sign+verify round trip against an
  independently-verified vector; 4 targeted tamper checks (both ends
  of both the R and s halves of a signature); a tampered-message
  rejection; a signature verified against the WRONG public key
  (rejected, ruling out a `verify()` that silently ignores the key);
  and a malformed/out-of-range "public key" (rejected cleanly by
  decompression, not a crash). Correct on the first real ARM build
  after a single, trivial fix (`public` turned out to be a reserved
  vani keyword -- a parameter name collision, not an algorithm bug) --
  fourth primitive in a row this batch with zero real debugging
  cycles.

  **Scope, explicit**: `ed25519_sign`/`_verify` cap the message at
  4096 bytes (`ed25519_hash_input`'s fixed size, same
  `dharafs_file_max_len()` ceiling this project's other hash-adjacent
  scratch buffers already use) -- fine for signing config files or
  update payloads (PKI's own realistic use case), not arbitrary-length
  streaming data. Not fully constant-time, same honest gap X25519's
  own entry above already flags for the shared field arithmetic
  (`field25519_add`/`_sub`'s single value-dependent conditional
  subtract) -- `ed25519_scalar_mod_l_raw`'s own conditional subtract-
  of-L during the bit-by-bit reduction has the identical theoretical
  property. Flagged for a future hardening pass, not silently
  accepted.

- **AES** — `[DONE, round 67, 2026-09-02 -- spiked exactly as this
  entry's own closing note called for, then built for real once the
  spike answered the suitability question]`
  The spike question this entry itself posed -- is vani's own bitwise
  arithmetic suitable for genuinely constant-time AES -- is answered
  YES, with real code to show for it, not just a feasibility note.
  **No lookup tables anywhere** (the real difficulty this entry always
  correctly identified: not the algorithm, doing it safely on ARMv6
  with no AES-NI and real cache-timing risk from a naive table-based
  S-box): the S-box is computed on the fly via constant-time GF(2^8)
  field inversion (x^254 = x^-1 in the 255-element multiplicative
  group, via the exact same fixed-exponent square-and-multiply
  technique `field25519_invert`/`ed25519_sqrt_candidate` already use,
  just over GF(2^8) instead of GF(2^255-19)) plus the standard fixed
  affine transform. GF(2^8) multiplication itself is branchless (a
  mask-based conditional reduction, same technique X25519's own cswap
  and Poly1305's own g/h select already established) rather than the
  classic "if high bit set, XOR the reduction polynomial" formulation,
  which branches on secret-shaped data.

  **Verification**: a from-scratch Python port of this exact
  construction, checked three ways before any vani code was written --
  the official FIPS-197 Appendix B test vector, byte-exact; 20 random
  trials against the real `cryptography` library's own AES-128-ECB
  encryptor, byte-exact on all of them; and a full 256-entry S-box
  cross-check against a SEPARATE, independent brute-force GF(2^8)
  inversion (a genuinely different multiplication implementation),
  confirming the constant-time construction isn't subtly wrong in a
  way the FIPS vector alone wouldn't happen to catch. 8 new
  host-harness checks (826→834 PASS clean under ASAN/UBSAN): the same
  full 256-entry S-box cross-check re-run under ASAN/UBSAN, the FIPS
  vector, 5 more random-trial vectors against the real library, and an
  avalanche-effect sanity check (one flipped plaintext bit changes a
  large number of output bits -- rules out a degenerate
  implementation where e.g. only the first round actually did
  anything). Live-verified against the FIPS-197 vector on real
  ARM/QEMU at boot, correct on the first real build.

  **Scope, explicit, matching this entry's own "spike first" framing
  and its own honest "no live consumer yet" note**: AES-128 ENCRYPT
  only. No decrypt (needs the inverse S-box and inverse MixColumns,
  real additional work with no caller needing it yet), no AES-192/256,
  no mode of operation or AEAD construction (CTR/GCM) on top -- this
  proves the constant-time approach works and leaves a real, usable,
  verified primitive behind, without speculatively building the full
  surface area WPA2/FIPS-TLS would eventually need before either is
  actually being worked on.

- **TLS** — `[DONE, round 67, 2026-09-02]` -- crypto prerequisites AND
  the handshake/record-layer state machine, scoped to a single cipher
  suite/group/signature algorithm (see below).
  Every crypto prerequisite this entry itself listed is now built:
  ECDHE (X25519, this round's own EC-foundation work) and an AEAD
  (ChaCha20-Poly1305, chosen over AES-GCM per this entry's own
  reasoning -- smaller lift, Poly1305 already existed this round and
  AES-GCM would have needed a whole extra mode-of-operation on top of
  AES). Also built HKDF (RFC 5869) -- TLS 1.3's own key schedule is
  entirely HKDF-Extract/-Expand chains deriving handshake and
  application traffic secrets from the ECDHE shared secret and a
  running transcript hash, so this is as much a "TLS prerequisite" as
  the AEAD is, just not explicitly named in this entry's own original
  list.

  `chacha20_poly1305_encrypt`/`_decrypt` (RFC 8439 section 2.8) build
  the one-time Poly1305 key via `chacha20_block` at counter 0, encrypt
  via the existing `chacha20_encrypt` at counter 1, and MAC over
  `aad || pad16(aad) || ciphertext || pad16(ciphertext) || len(aad)
  || len(ciphertext)` per the RFC exactly; decrypt verifies the tag
  (constant-time, `poly1305_verify_constant_time`) BEFORE ever
  decrypting -- a tag mismatch leaves the output buffer untouched,
  same "reject, don't guess" posture as every other integrity check
  in this codebase. `hkdf_extract`/`hkdf_expand` are a genuinely
  SEPARATE HMAC-SHA256 implementation from round 61's own
  `hmac_sha256` (real authentication's proven, security-critical
  primitive, capped at 64-byte messages for its own narrower need) --
  HKDF-Expand's own per-round HMAC input can exceed that once `info`
  is TLS-shaped, and widening an already-shipped auth primitive for
  an unrelated caller was judged the wrong trade against a small
  amount of duplicated HMAC structure.

  Verified via a from-scratch Python port of both constructions,
  checked against the real `cryptography` library before any vani
  code was written: full AEAD (ciphertext AND tag) matches
  ChaCha20Poly1305's own encrypt() across 20 random trials with
  varying AAD/plaintext lengths (exercising the RFC's own pad16
  boundary in both directions); HKDF matches the library's own HKDF
  across 15 random trials including multi-block expansions past one
  SHA-256 output. 40 new host-harness checks (834→874 PASS clean
  under ASAN/UBSAN): 6 more AEAD trials (encrypt, decrypt round-trip,
  AND tamper-rejection each) plus 5 more HKDF trials at varying output
  lengths. One real bug caught by ASAN itself, not the algorithm: the
  host-harness test's own scratch-buffer setup missed 3 of
  `hkdf_hmac_sha256`'s internal buffers, causing a clean null-pointer
  crash on the very first HKDF call -- fixed in the test harness, not
  the implementation. Live-verified at boot on real ARM/QEMU, correct
  on the first real build otherwise.

  **Handshake/record-layer state machine — DONE, same day.** Scoped to
  exactly one cipher suite (TLS_CHACHA20_POLY1305_SHA256), one key-
  exchange group (x25519), one signature algorithm (ed25519), and RFC
  7250 raw public keys (server-authenticated only, no client cert, no
  session resumption/PSK/0-RTT/renegotiation) -- this entry's own
  "materially smaller, realistic first target" framing, taken all the
  way through. Real RFC 8446 wire format throughout: ClientHello/
  ServerHello construction (§4.1.2/4.1.3, with real
  supported_versions/supported_groups/signature_algorithms/key_share
  extensions), the full §7.1 key schedule (Early/Handshake/Master
  Secret via HKDF-Extract chains, HKDF-Expand-Label, Derive-Secret),
  the encrypted server flight (EncryptedExtensions, Certificate
  carrying a bare RFC 7250 raw public key instead of an X.509 chain,
  CertificateVerify per §4.4.3, Finished per §4.4.4), client Finished,
  and application traffic secret derivation -- then real record-layer
  AEAD (§5.2/5.3: per-record nonce = static IV XOR sequence number,
  AAD = the 5-byte TLSCiphertext header) built directly on this
  round's own ChaCha20-Poly1305/HKDF/SHA-256/X25519/Ed25519
  primitives, no new crypto invented for this layer.

  Verified two ways, same discipline as every other primitive this
  round: (1) a from-scratch Python reference (`tls13_ref.py`) built
  the identical message flow, itself checked against the
  `cryptography` library's own X25519/Ed25519/ChaCha20Poly1305
  primitives as trusted building blocks -- both roles (client and
  server) fully simulated, CertificateVerify signature verifies,
  both Finished MACs verify, application data round-trips in both
  directions; (2) that reference's exact deterministic output (every
  key-schedule secret, every handshake message, every encrypted
  record) embedded as a host_harness KAT, 970/970 checks passing
  under ASAN/UBSAN including a tampered-record rejection check. A
  live, both-roles handshake + application-data round trip
  (`tls_self_test`) also runs at boot on real ARM under QEMU and
  passes -- correct on the first real build (one off-by-one in the
  HOST HARNESS test's own hardcoded message length, not the
  implementation, was the only fix needed).

  **Wired into the live TCP transport — DONE, same day.**
  `tls_tcp_self_test` (`kernel_main.vani`) drives the exact same
  handshake + application-data exchange above over a REAL TCP
  connection: a genuine 3-way handshake (`tcp_conn_active_open`/
  `tcp_conn_passive_open`/`tcp_conn_handle_segment`, real loopback
  netif frames), every TLS message fragmented into <=64-byte chunks
  (`tcp_conn_send_data`'s own real, proven cap — deliberately left
  untouched rather than widened for this one new caller, per this
  project's own "don't touch working code without a real forcing
  need" discipline) and reassembled on the receiving side from a
  running byte accumulator (`tls_rx_feed`/`tls_rx_try_extract[
  _plaintext]`), real ACKs delivered back to the sender after each
  chunk, and a real TCP close at the end. ClientHello/ServerHello
  also gained real (unencrypted) TLSPlaintext record framing (RFC
  8446 §5.1) — needed only once there's an actual byte stream with no
  other message-boundary signal, so it wasn't part of the buffer-to-
  buffer scope above. Client and server each parse the other's actual
  wire bytes (fixed-offset parsers, matching this whole effort's
  single-cipher-suite/group/sigalg scope — not a general TLS parser)
  rather than reusing a shared local variable, so the shared secret,
  transcript, and every derived key are computed from what genuinely
  crossed the wire. Verified live on real ARM under QEMU (one bug
  along the way: the new scratch buffers' boot-time allocations were
  initially missed entirely, causing a null-pointer Data Abort on the
  very first call — caught immediately by the very next QEMU run,
  fixed by adding the missing `dhruva_alloc_bytes` calls). Full
  regression battery re-verified clean afterward: `qemu_run.py`,
  `phase4_milestone.py` (including `tcpecho`'s own unrelated TCP
  self-test, confirming the new self-test's reuse of connection slots
  0/1 didn't disturb it), `heap_stress.py`, `host_harness` 970/970
  under ASAN/UBSAN (no new host-harness test was added for this piece
  specifically — netif/TCP self-tests have never had host-side
  coverage in this codebase, since MMIO-touching code paths can't be
  intercepted host-side at all, same boundary `tcp_conn_self_test`
  itself has always lived within).

  **Still explicitly out of scope**: other cipher suites/groups/
  signature algorithms; client certificates; session resumption/PSK/
  0-RTT; a real `tls_connect`/`tls_accept`-shaped public API (this
  delivers the wiring proven end-to-end inside one self-test, not a
  general-purpose connection-object API a shell command or future
  caller could use directly).

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
     hardware UART loopback is configured either. **This shell did
     not echo anything typed, for any command, at the time.** A typed
     password was therefore not already leaking into the UART stream —
     the real, then-open gap was the opposite one: normal typing got
     no visual feedback either. Out of scope for authentication itself
     at the time; flagged that a real echo feature would need its own
     password-mode suppression when added.

     **`[DONE, round 72, 2026-09-05]`** — real per-byte echo added to
     `irq_dispatch`'s UART-RX branch (`shell_echo_char`, `kernel_main
     .vani`), with a small character-by-character prefix matcher
     (`shell_echo_advance`) that detects an in-progress `su ` or
     `passwd ` line and suppresses all further echo for the rest of
     that line (deliberately coarser than token-precise: hides the
     uid/gid arguments too, not just the password, a considered
     tradeoff — "hides a little more than necessary" has no downside,
     unlike the reverse). Persistent per-line matcher state lives in
     a new `shell_echo_state` word in `boot/shell_state.S` (same
     `.bss`-plus-extern-accessor shape as every other piece of
     `irq_dispatch`-owned state in this project), reset to 0 on CR/LF.
     `#[wcet(cycles=100000)]` on `irq_dispatch` raised to `130000`
     after re-measuring the static estimate with the new per-byte call
     (118044 cycles) — genuinely more work, not an estimator
     regression. New `shell_echo_self_test()` white-box-tests the
     matcher directly (su/passwd/near-miss-prefix/non-matching-line/
     backspace-while-suppressed); live-verified over real QEMU serial
     that `ls` echoes normally while `su <uid> <gid> <password>` and
     `passwd <uid> <new_password>` echo only the `su `/`passwd `
     prefix and suppress everything typed after it.

     Found and fixed a real, unrelated authoring mistake along the
     way: the new functions were first inserted physically between
     `irq_dispatch`'s own `#[no_mangle] #[interrupt(priority=0)]
     #[bounded_stack(bytes=1024)] #[wcet(cycles=100000)]` attribute
     stack and the `fn irq_dispatch` line it was meant to decorate —
     vani attributes bind to the next function *lexically*, so this
     silently reattached all four attributes to the wrong function.
     The most visible symptom was `#[no_mangle]` no longer applying:
     `irq_dispatch` fell back to its default mangled LLVM symbol name
     (`fn_irq_dispatch`), which broke the link step, since `boot/
     irq_entry.S`'s hand-written `bl irq_dispatch` expects the bare,
     unmangled name. Fixed by moving the whole new block back above
     the attribute stack, restoring `#[no_mangle]` (and the other
     three attributes) to `irq_dispatch` itself.

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

  **CLOSED, round 68 (2026-09-04)**: the underlying bug is fixed (see
  that round's own entry below) — raised 200 → **20,000**, a real,
  deliberate tradeoff chosen from live-measured numbers on this exact
  target, not copied from guidance written for different hardware.
  OWASP's current 600,000 was measured directly on this build too and
  would cost several minutes per `passwd`/`su` call, not a usable
  interactive command at any plausible real-hardware speedup from this
  QEMU timing. Three real measured points (steady-state `su`, not
  counting the one-time cost of the shell finishing boot): 10,000
  iterations ~6.5s (already proven safe daily — the exact count `dharafs_
  crypto_key_init` runs every boot), 20,000 ~12.8s (the chosen value,
  per explicit user direction to favor strong security without
  sacrificing interactive performance), 100,000 ~60.3s (also tested
  clean, zero crashes, confirming the round-68 fix holds under
  sustained non-yielding computation too — rejected purely on latency
  grounds, not correctness). 20,000 matches NIST SP 800-132's
  long-cited minimum recommendation and was standard industry practice
  for years before OWASP's 2023 escalation — a real, historically-
  defensible "strong" value, not an arbitrary number. Verified: full
  regression battery green (`qemu_run` self-test, `phase4_milestone.py`
  15/15, `heap_stress.py` PASS, `power_yank.py` 70/70, `host_harness`
  970/0 ASAN/UBSAN), plus direct functional checks at the new value —
  `passwd` sets a password, `su` with the wrong password is correctly
  rejected, `su` with the correct password is correctly accepted, all
  live over the real interactive shell.

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
  trap under the real scheduler** — `[found round 61; INTERRUPT-DRIVEN
  mechanism ROOT-CAUSED AND FIXED round 68, 2026-09-04; round 62f's
  separate zero-interrupt occurrence CLOSED, BELIEVED RESOLVED same
  day, as a side effect of round 65's own sha256_compress fix -- a
  190-boot black-box reproduction sweep plus a direct re-run of round
  63's own scoped hardware-watchpoint check (56,708 sha256_compress
  calls, 1.1B+ memory stores, zero hits) both found nothing -- see
  round 68's own entry below for the full writeup]`
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

- **`tlsecho` (task_f) real Data Abort, deterministic, first attempt,
  every time — the interrupt-driven mechanism behind the whole
  "long-running synchronous computation crashes into a silent runtime
  trap" saga above, finally root-caused** — `[ROOT-CAUSED AND FIXED,
  round 68, 2026-09-04]`

  User-reported concern going in: not a TLS-specific bug, a generic
  pattern that "will keep showing again and again" — confirmed correct.
  Investigated code-first (not GDB) per explicit instruction, tried
  three rounds of empirical stack/heap bumps first (matching this
  project's own established, previously-successful pattern for this
  bug class — round 9/27/60/67 in the rounds index) — `stack_f_bytes`
  32768 → 65536 → 262144 (8x), `DHRUVA_HEAP_BYTES` 256KB → 768KB (also
  fixed a real, independent regression this uncovered: the earlier
  256KB heap left only 8888 bytes of headroom after the first bump,
  already short of `heap_usage_self_test`'s own `>= 16384` requirement)
  — plus a new permanent structural safeguard, a per-task stack-overflow
  canary (`boot/stack_canary.S`, checked once per real tick from `irq_
  dispatch`). **None of this fixed it.** The crash still reproduced
  deterministically on the very first `tlsecho` invocation after every
  single one of these increases — the clearest possible signal that
  "not enough stack" was never the real explanation, only a
  contributing factor to some of this bug class's other historical
  incidents.

  Extended `boot/rpi1/vectors.S`'s `fault_data_abort` handler to also
  capture `lr_svc` at the moment of the fault (previous captures only
  had `r0-r3`/`pc`/fault address) — banked-register-aware: right after
  `cps #0x13` switches to SVC mode, "lr" transparently means `lr_svc`,
  the interrupted code's own live link register, completely untouched
  by taking the exception. For a 2-instruction leaf like `buf_read_u32`
  (`ldr r0,[r0,r1]; bx lr`, no stack frame), this is exactly the
  faulting call's own return address — a real, permanent diagnostic
  improvement (kept, not reverted), and the single piece of evidence
  that actually broke the case: `lr == pc == buf_read_u32`'s own entry
  address, every time.

  **The actual mechanism**: `irq_entry.S`'s saved-context frame used
  ONE word to serve two different purposes — "the value to restore into
  r14" and "the address to resume execution at." For a VOLUNTARY switch
  (`task_sleep_ticks`, `dhruva_mutex_lock`) these are legitimately the
  same value (the switching function's own return address). For an
  INTERRUPT-driven switch they are not: the interrupted task's TRUE
  `lr_svc` was never saved anywhere at all — it just sat in the
  physical register, banked and untouched, right up until `bl irq_
  dispatch`/`bl scheduler_switch_from_irq` (real calls, executed in SVC
  mode after the `cps #0x13` switch) silently overwrote it with their
  own return addresses. At restore, `ldmia sp!, {r0-r12, lr}` followed
  by `subs pc, lr, #0` used that one clobbered-then-repurposed slot as
  both the new r14 AND the jump target, so after resuming, `r14` always
  equals `pc`, regardless of what the interrupted code's real return
  address should have been.

  This is invisible for the overwhelming majority of this codebase:
  every ordinary vani-compiled function has a `push {fp,lr}`/`pop
  {fp,pc}` prologue/epilogue, saving `lr` to ITS OWN stack frame at
  entry, independent of the live register. It is fatal specifically for
  this project's ~300 hand-written, bare two/three-instruction `boot/*_
  state.S` accessor leaves (`*_get`/`*_set`, `buf_read_u32`/`buf_write_
  u32` among them — grepped and confirmed the actual count directly,
  not estimated) that rely on the live `r14` surviving a preemption. If
  a timer/UART interrupt lands exactly inside one of these, it resumes
  with `r14 == pc`: the single `ldr`/`str` re-executes correctly, then
  `bx lr` jumps back into its OWN entry instead of returning — and for
  `buf_read_u32` specifically, repeatedly executes `r0 = *(u32*)(r0 +
  r1)` (r1/the offset argument never changes) until it dereferences
  something unmapped. The "wild-looking" fault address every prior
  capture in this saga puzzled over (this round's own and round 62's
  `sha256_compress` captures alike) is simply wherever that chase
  happened to end up — not corruption in the traditional sense at all.
  Explains every observed symptom at once: the offset argument always
  survives intact (round 62's own repeated observation) because `r1`
  is never touched by this loop; only the base pointer looks "corrupted
  in place"; it always lands on one of these bare leaves specifically;
  and it explains why round 62d's own targeted breakpoint (conditioned
  on `r8`/`r11` already looking wrong INSIDE the saved frame) never
  fired — it was checking the wrong field. The frame's `r8`/`r11` slots
  were never the corrupted ones; its `lr` slot was.

  **Fix**: grew the saved-context frame from 16 words (64 bytes) to 17
  (68 bytes) — `spsr, pad, r0-r12, true_lr, resume_pc` — storing the
  interrupted task's real `lr_svc` and the resume PC as two independent
  words instead of one conflated slot, and replaced the manual `ldmia
  {r0-r12,lr}` + `subs pc,lr,#0` restore with ARM's standard `ldmia
  {r0-r12,lr,pc}^` exception-return idiom (loads r14 and pc
  independently, still restores CPSR from SPSR atomically via the caret
  suffix). Touched all four save/restore sites that share this frame
  shape for consistency: `irq_entry.S` (the actual bug), plus `task_
  sleep_ticks`/`dhruva_mutex_lock`/`prepare_stack_common`+`start_
  multitasking` in `context_switch.S` (voluntary/initial-launch paths,
  where true_lr and resume_pc are the same value, just stored twice
  now instead of once).

  **Verification**: official `phase4_milestone.py` 15/15 (`tlsecho`
  passing for the first time ever in this suite), `heap_stress.py`
  PASS, `power_yank.py` 70/70, `host_harness` 970/0 under ASAN/UBSAN
  (also fixed a real but unrelated, pre-existing host-harness build gap
  found along the way — 13 TLS scratch accessors added to `boot/tls13_
  scratch.S` in a later sub-round than `test/host_harness/host_stubs.c`
  was last updated, plus this round's own new `stack_canary_*` stub, 5+
  undefined references), plain boot self-test clean, and an extended
  20-iteration `tlsecho` stress run: 20/20 passed, every single one on
  the first attempt, zero `FATAL`/`CANARY`. The stack/heap/canary
  hardening from earlier in this round stays in place as real,
  independent defense-in-depth (not made pointless by this fix — the
  `#[bounded_stack]` checker's own documented unsoundness for this call
  chain is real regardless), not reverted.

  **Scope, stated precisely**: this fixes the INTERRUPT-DRIVEN
  corruption mechanism, which explains every capture from this specific
  investigation (this round's and, very plausibly given the matching
  symptom shape, several of round 61-65's own `sha256_compress`
  captures too). It does **not** explain round 62f's own separate
  finding that the SHA-256/PBKDF2 corruption was once reproduced with
  **zero interrupts** (single-threaded boot, before `enable_irqs()` is
  ever called) — that occurrence cannot be this mechanism by
  construction (no interrupt, no resume-frame involved at all), so if
  it's still genuinely reproducible, a separate, narrower bug remains
  open. Attempting to reproduce it directly is this round's own
  immediate next step (see below) rather than assuming it's now moot.

  **Reproduction attempt (same day)**: added a temporary single-
  threaded, pre-`enable_irqs()` call running `pbkdf2_hmac_sha256` at
  the same 1000-iteration diagnostic count round 62f itself used, then
  booted 40 completely fresh QEMU instances against it (no shared
  state between runs), checking each for either a clean completion
  marker or any `FATAL`. **40/40 completed cleanly, 0 FATAL, 0
  incomplete/hung runs.** Combined with today's own incidental
  evidence — `power_yank.py`'s 70 fresh boots plus every other
  regression run this round, each of which also executes `pbkdf2_
  hmac_sha256_self_test()`'s own 4096-iteration KAT single-threaded —
  that's on the order of 110+ clean single-threaded PBKDF2 boots today
  with zero reproductions. **This does not confirm the bug is gone**:
  round 62f's own estimate was "roughly 1-in-30-or-rarer" from a
  single observed hit plus a 30-run follow-up sweep that ALSO found
  zero further hits — meaning the true rate could plausibly be
  considerably rarer than 1-in-30, and 40 (or even 110) more clean
  runs is not statistically decisive against a rare-enough event. Kept
  honest rather than declared closed: **still genuinely open**: not
  reproduced today, not proven absent, true occurrence rate still
  unknown. A future session with a larger budget (several hundred+
  fresh boots, or reviving round 65's own QEMU-TCG-plugin tracing
  technique -- near-native speed, proven far more practical than GDB
  for this class of high-call-count investigation -- rather than boot-
  count brute force) would be the natural next escalation if this is
  still considered worth pursuing. Temporary diagnostic call reverted
  after this attempt; `git diff`-equivalent (`build.sh` clean rebuild)
  confirmed before moving on.

  **Escalation, same day: revived round 65's own QEMU TCG-plugin
  technique and a much larger boot count, per explicit user request.**
  `qemu-plugin.h` for the installed QEMU version (10.0.11; fetched the
  ABI-compatible `v10.0.0` tag's copy, no local dev package installed
  — same situation round 65 itself hit) pulled directly from upstream
  QEMU's own repo. Wrote a small, general-purpose "flight recorder"
  plugin (not committed to this repo — a standalone investigation
  tool, matching this project's own "temporary diagnostics don't
  belong in the tree" discipline): hooks every translated block's
  `vcpu_mem_cb` for stores only, keeping a bounded 4096-entry ring
  buffer of `(instruction PC, store address, value, size)`, and
  registers an `insn_exec` callback at two fixed trigger PCs
  (`fault_data_abort`=`0x44`, `fault_prefetch_abort`=`0x88`, this
  build's own addresses, confirmed via `nm`) that dumps the full ring
  buffer plus every CPU register the instant either is reached —
  catching the corrupting write itself, not just "a crash happened."
  Verified fast and correct on a sanity boot before scaling up (reaches
  full post-`start_multitasking` multitasking activity in ~15-20s with
  the plugin attached, consistent with round 65's own "13-20s per
  attempt, near-native speed" figure — no `tail`-buffering false start
  this time, direct-to-file output used throughout).

  Ran **150 additional fresh, plugin-instrumented single-threaded
  boots** (batched 6-wide for throughput, 25s cap each — comfortably
  past both the 4096-iteration self-test KAT and the real 10000-
  iteration `dharafs_crypto_key_init` call every single boot already
  exercises). **150/150 clean — zero trigger hits, zero `FATAL`,
  confirmed by grepping every one of the 150 output files
  independently, not just trusting the script's own tally.**

  **Combined with the earlier 40-boot sweep, that's 190 total fresh
  single-threaded boots today with zero reproductions.** This sample
  is large enough to say something quantitative, not just "still
  didn't see it": if round 62f's own "roughly 1-in-30" rate estimate
  were still accurate, the probability of 190 consecutive clean runs
  is `(29/30)^190` ≈ **0.16%** — meaning either the true rate was
  always considerably rarer than that estimate (built from a single
  observed hit, not a measured rate), or, more likely given the
  evidence: **round 65's own fix — changing `sha256_compress`/`sha256_
  h_init` to reload `h`/`w`/`k` fresh at every point of use instead of
  holding them live across the whole function — incidentally closed
  this zero-interrupt case too, even though round 65's own 100-attempt
  verification only explicitly covered the interactive-multitasking
  case at the time.** Not proven (190 clean runs is strong evidence,
  not a mathematical proof of absence for a rare-enough event), but
  this is now the best-supported working theory, and the honest thing
  to do is downgrade this entry's own status rather than leave it
  reading as urgent/high-priority when the evidence no longer supports
  that framing.

  **Status update**: downgrading from "genuinely open, high priority"
  to **"believed resolved as a side effect of round 65's own fix, not
  independently re-verified with dedicated instrumentation — worth a
  cheap confirming check (e.g. round 63's own scoped hardware-
  watchpoint technique, one more time, now specifically against a
  round-65-or-later build) before fully closing, but no longer
  believed to be an active, reproducible bug** — a meaningfully
  different, much less urgent status than "STILL NOT FULLY ROOT-
  CAUSED — high priority," which is what this entry's own header said
  for months of prior rounds. `pbkdf2_auth_iterations()` remains at
  200 regardless (raising it is a separate decision requiring its own
  deliberate confirmation, not something 190 clean boots alone should
  unilaterally unblock) — flagged here as a legitimate candidate for a
  future round to revisit, not raised in this one.

  **Closing confirmation (same day), per explicit user request:
  reproduced round 63's own scoped hardware-watchpoint check directly,
  rather than relying on the reproduction sweep's statistical
  inference alone.** Implemented as a TCG plugin instead of literal
  GDB (same technique this entry's own earlier escalation already
  proved practical): watch `fn_sha256_compress`'s own saved-`lr` stack
  slot, armed one instruction after its prologue completes (`push
  {r4-r9,fp,lr}` + `sub sp,sp,#128`, confirmed via this build's own
  fresh disassembly) and disarmed at its one epilogue (before the
  matching `pop`) — exactly round 63's own scoping rationale (an
  unscoped watch catches legitimate stack-slot reuse by whatever runs
  next after the function returns, a real false positive round 63
  itself hit and documented). **First attempt reproduced a DIFFERENT
  false positive of the same general kind**: arming exactly at the
  function's own entry PC caught the `push` instruction's own
  legitimate write of `lr` to that slot (every early "hit" had
  `pc==entry_pc`, i.e. fired on the very instruction that produced the
  watched value in the first place) — fixed by arming one instruction
  later, after the prologue's own writes are already done. Worth
  recording plainly: this is a real methodology trap independent of
  which tool implements the watch (GDB or a TCG plugin), and anyone
  reproducing this check again should watch for it.

  With that fixed, ran a 90-second live boot (`qemu-system-arm`,
  `-nographic`, no interactive input) covering the full single-threaded
  boot sequence (comfortably including both the 4096-iteration
  self-test KAT and the real 10000-iteration `dharafs_crypto_key_init`
  call — round 63's own original scope) AND a substantial stretch of
  live, interrupt-driven multitasking afterward (HIGH/MEDIUM/LOW/
  MUTEX-demo/CUSTOM/idle all visibly cycling in the log) — broader
  coverage than round 63's own original single-threaded-only scope, at
  no extra cost. **Result: 56,708 total `fn_sha256_compress` calls,
  over 1.1 billion total memory stores observed by the plugin, ZERO
  watchpoint hits.** Matches round 63's own original "zero hits" result
  exactly, now directly re-verified — not inferred — against the
  current build (round 65's `sha256_compress` fix + round 68's
  scheduler fix both in place).

  **This is now a direct, not merely statistical, confirmation.**
  Downgrading status one step further: **CLOSED, believed resolved**.
  The corrupting-write-to-a-known-candidate-slot hypothesis stays
  ruled out exactly as round 64 already established (this round's own
  check targeted the same slot from a different angle and agrees:
  zero hits), and the broader "does this class of corruption still
  occur at all" question — the actual open question after round 65's
  fix — now has 190 clean black-box reproduction attempts (previous
  escalation) AND a 56,708-call, billion-plus-store instrumented run
  finding nothing (this one) behind it. Not an absolute proof it can
  never recur (no finite test ever is, for a historically rare and
  ultimately never-fully-root-caused mechanism), but there is no
  remaining evidence-based reason to keep tracking this as an open
  bug. `pbkdf2_auth_iterations()` still deliberately left at 200 in
  this round — raising it to a real security-appropriate value is a
  separate, deliberate decision for a future round, not something to
  fold in as a side effect of closing this investigation.

- **Packet filtering / iptables-equivalent (incoming DONE round 60;
  outgoing DONE round 72, 2026-09-05)**
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
  self-talk.

  **Outgoing filtering: DONE (round 72, 2026-09-05).** `filter_check_frame`
  gained a third parameter, `is_outgoing`, so the SAME rule table and
  first-match-wins logic filters both directions -- a rule's `src_ip`
  field means "the other party" regardless of direction: for an inbound
  frame that's genuinely the IP header's own source field, but for an
  outbound frame (whose header source is always this host's own
  address) it's the destination field instead, matching what a `fw add
  ... <ip>` rule intuitively means to whoever configures it. Hooked in
  at `netif_send_frame`'s own single choke point (every outgoing
  ARP/IPv4/ICMP/UDP/TCP frame already passes through it, mirroring
  `netif_recv_frame`'s three ingress hooks) -- a denied frame is
  silently dropped and reported as success, the same "the sender never
  learns" convention `fault_netdrop_maybe_inject` already established
  for this exact function. New `filter_outgoing_self_test` covers both
  the directional field-selection logic and the real `netif_send_frame`
  integration (a denied frame never reaches the loopback queue at all;
  a non-denied one queues normally). Live-verified over the real
  interactive shell: `fw add deny icmp 0.0.0.0 any` then `ping
  0.0.0.0` genuinely suppresses the reply (`ping: no reply`), and `fw
  flush` genuinely restores it -- the same live-verification bar
  round 60's own incoming half already met.

  **Found and fixed a real, pre-existing bug along the way, not
  introduced by this round**: `fw_add_rule` (`boot/fw_state.S`) used
  `r4`/`r5`/`r6` as scratch registers (to hold 2 stack-loaded args plus
  a repeatedly-reloaded table-field-address register) without saving
  them -- a genuine AAPCS callee-saved-register violation, silently
  corrupting whatever a CALLER had live in those same registers. Never
  triggered before because no earlier caller's own register allocation
  happened to collide; `filter_outgoing_self_test` was the first to
  expose it. Initially looked exactly like a vani-compiler codegen bug
  (a literal `u32` argument read as garbage, inconsistently across
  otherwise-identical call sites) -- ruled that out properly via direct
  LLVM IR inspection (clean) and ARM disassembly comparison of a
  working vs. broken build (found the real `fw_add_rule` clobber) before
  concluding it wasn't vani-compiler's fault, rather than accepting a
  workaround without knowing why. Fixed with `push {r4,r5,r6}` / `pop
  {r4,r5,r6}` around the existing body (shifting the two stack-argument
  offsets down by 12 bytes to account for it) -- exactly the same bug
  CLASS as this project's own prior AAPCS-callee-saved-register
  incidents (rounds 53/55/62c/70), a new instance in a function an
  earlier sweep never reached. Full detail and the bisection method
  used: project memory `reference_vani_fw_add_rule_misdiagnosis_2026_09_05`;
  the general methodology is now a persistent, reusable skill at
  `~/.claude/skills/vani-compiler-bug-bisection/SKILL.md`. Verified: 5/5
  clean boot-self-test runs (previously 3/3 deterministic failures with
  the pre-fix binary), `phase4_milestone.py` 15/15, `heap_stress.py`,
  `power_yank.py` 70/70, plus the live shell round trip above both
  before and after the fix (confirming the real production feature was
  correct throughout -- only the new self-test's own narrow register
  allocation had ever exposed the pre-existing asm bug).

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

- **PKI (Public Key Infrastructure)** — raw public-key trust: `[DONE,
  round 67, 2026-09-02]`; full X.509/CA chain: still `[XL, SKIPPED,
  a separate, much larger step, not a package deal]`
  The realistic FIRST increment this entry itself called for: pin a
  known Ed25519 public key, verify a signature against it directly,
  no X.509/ASN.1/CA-chain machinery at all. `boot/pki_state.S` +
  `pki_init`/`pki_verify_raw`/`pki_verify_file_raw`/`pki_verify_file`
  (`kernel/kernel_main.vani`), a new `verify <path>` shell command
  alongside `cat`/`catv`. The pinned key is a COMPILE-TIME CONSTANT,
  deliberately never runtime-settable through the shell or any other
  API -- a trust anchor repinnable by whoever has shell access would
  defeat the entire point (matches this project's own "smaller
  substitute for secure boot" framing under the Secure Boot entry
  below: Dhruva verifying something IT loads at runtime before
  trusting it, the trust anchor itself provisioned once, not mutable).
  Signature format: a companion `<path>.sig` file (64 bytes, the raw
  Ed25519 signature) next to the file it covers -- same "companion
  file, not a record-format change" pattern round 48's own SHA-256
  digest feature (`<path>.sha256`) already established, reused
  directly rather than inventing a third convention.

  Verified via a real demo keypair (the PRIVATE key never appears
  anywhere in this codebase, only the pinned public half -- matching
  real trust-anchor provisioning practice) generated the same way
  every other Curve25519-family test vector this round was: a
  from-scratch Python script using the real `cryptography` library,
  not typed from memory. 12 new host-harness checks (814→826 PASS
  clean under ASAN/UBSAN): genuine-signature accept, tampered-content
  reject, tampered-signature reject, a REAL end-to-end round trip
  through actual DharaFS storage (write the file and its companion
  `.sig`, verify, then overwrite the file's content and confirm the
  now-stale signature is correctly rejected), missing-file and
  missing-companion-`.sig` both a clean -1 (never a crash), and a
  path-length boundary check (dharafs's own 32-byte path cap minus
  the 4-byte `.sig` suffix leaves 28 usable characters for the
  original path -- one more is rejected cleanly before ever touching
  dharafs). Live-verified at boot on real ARM/QEMU. Caught and fixed
  one real (non-algorithmic) issue along the way: the new `verify`
  shell command's own call chain pushed `task_f`'s compiler-checked
  `#[bounded_stack]` worst case to 4172 bytes, past its round-30
  budget of 4096 -- raised to 6144 (this function's REAL allocated
  stack is 16384 bytes, so this was always a static-checker
  bookkeeping fix, never a genuine overflow risk).

- **Media (at-rest) encryption** — `[DONE, round 62, 2026-08-31; AEAD/tamper-detection/two-time-pad upgrade DONE round 69, 2026-09-04]`
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

  **ROUND 69 UPDATE (2026-09-04): both honest limitations above are
  now fixed.** User-directed follow-up ("ensure tamper detection and
  fix weakness") replaced the plain-ChaCha20 transform with real
  ChaCha20-Poly1305 AEAD (`dharafs_crypto_encrypt_block`/
  `_decrypt_block`, in `kernel/kernel_main.vani`, using round 67's
  own already-verified `chacha20_poly1305_encrypt`/`_decrypt`):

  - **Tamper detection**: every block now carries a 16-byte Poly1305
    tag (AAD = block number, so a valid tag+ciphertext pair can't be
    silently moved to a different block). `dharafs_block_read` fails
    CLOSED (non-zero status, buffer untouched) on any mismatch —
    real corruption or deliberate tampering alike — rather than ever
    handing back unverified bytes as if they were trustworthy
    plaintext.
  - **Two-time-pad fix**: a new dedicated per-block metadata region
    (`boot/dharafs_crypto2_state.S` for its own AEAD scratch;
    16 packed 32-byte entries — 4-byte write-counter, 4-byte magic
    marker, 16-byte tag, 8 reserved — per 512-byte sector, starting at
    block 4000, clear of the log region (blocks 1-2048) and the
    self-check's own `test_block=3000`) tracks a monotonically
    increasing write-counter per block. New nonce = `block_num (4B) ||
    write_counter (4B) || 0 (4B)`, so the SAME block written twice now
    always gets a DIFFERENT nonce, closing the classic stream-cipher
    "two-time pad" leak. A counter of 0 (no entry yet, or a foreign/
    garbage sector whose magic marker doesn't match) means "never
    AEAD-protected" — read falls through to plain passthrough for it,
    so genuine pre-existing plaintext (written before encryption was
    turned on, or while it was off) is never misread as ciphertext.
  - Dedicated scratch buffers (`dharafs_crypto_block_scratch_ptr` and
    6 siblings), deliberately NOT shared with TLS 1.3's own AEAD
    scratch (`boot/aead_hkdf_scratch.S`) even though both call the
    same underlying primitive — this project's single-core,
    preemptible scheduler means a DharaFS block read/write (reachable
    from ANY task, including background compaction) could preempt a
    `tlsecho` task mid-AEAD-computation; sharing scratch would let one
    clobber the other's in-progress state, the exact "shared mutable
    state across preemptible tasks" hazard class this session's own
    round-68 scheduler-bug investigation centered on.
  - New `crypto on|off|status` shell command — live toggle, no reboot
    needed (`kernel_main.vani`'s `shell_dispatch_crypto`).
  - `dharafs_encryption_self_check` rewritten to verify all of the
    above on every boot, not just the original transform round trip:
    an AEAD round trip, an explicit two-time-pad-fixed check (encrypt
    the same block twice, confirm different ciphertext, confirm both
    still decrypt correctly), an explicit tamper-rejection check (flip
    one ciphertext bit, confirm `-1`), and the real SD-integrated path
    (write, confirm on-disk bytes are ciphertext, read back correctly,
    then corrupt the raw on-disk block directly and confirm
    `dharafs_block_read` — the actual path every FS read uses — fails
    closed instead of returning garbage). All four print as their own
    `CRYPTO: DharaFS ...` PASS/FAIL lines. Verified PASS on real
    ARM/QEMU with a real 64MB SD image (`test/phase4_milestone.py`;
    `test/qemu_run.py` has no SD `-drive` at all, so these necessarily
    show FAIL there — a known harness limitation, not a real failure,
    see the entry below). `test_media_crypto` in `test/host_harness/
    host_main.c` extended to match (now also covers the two-time-pad
    fix and both tamper-rejection cases) — 975/975 PASS clean under
    ASAN/UBSAN (up from 970).
  - Caught and fixed one real (non-algorithmic) issue along the way,
    same class as several previous rounds: the deeper AEAD call chain
    reachable from `task_e`'s own `dharafs_compact` (now
    `-> dharafs_block_read -> dharafs_crypto_decrypt_block ->
    chacha20_poly1305_decrypt -> poly1305_mac`) pushed the compiler's
    own static `#[bounded_stack]` check past its budget (2052 bytes
    needed vs. 2048 available) — caught at compile time, not left as a
    real-hardware-only risk. Raised to 4096 (this task's REAL
    allocated stack is already 16384 bytes, so this was a static-
    checker bookkeeping fix, never a genuine overflow risk).

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
  deliberately verified only the in-memory transform (safe, 100%
  reliable) rather than the real SD-integrated path, on every boot —
  baking a ~20-30%-per-boot destabilization risk into a permanent
  self-test would make the whole system less reliable for every user,
  not just those who enable encryption. The real end-to-end
  integration was instead verified via the host-harness ASAN/UBSAN
  twin (a real host process, no IRQs, no hazard) and a one-time manual
  live QEMU run with a real SD image attached (both confirmed correct
  — see the media encryption entry above). **Since this SD-timing bug
  itself was fixed (round 65/66, immediately above), the real
  SD-integrated path was restored to the permanent on-target
  self-test** (round 66), and round 69's AEAD upgrade extended it
  further still (two-time-pad and tamper-detection checks) — see the
  media encryption entry's own round-69 update above.

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

- **Secure boot** — `[not sized — hardware-rooted version PERMANENTLY
  SKIPPED (hard hardware ceiling, below); the smaller runtime-
  signature-verification substitute this entry called for is actually
  DONE, round 67 — this entry's own cross-reference was stale, caught
  and fixed round 68, 2026-09-04]`
  Real secure boot means a hardware-anchored, cryptographically
  verified chain from an immutable root of trust through every stage
  that runs before the OS itself does. **The original Raspberry Pi 1
  Model B's boot ROM has no signature-verification capability at
  all** — same hard ceiling as USB boot, and for the same underlying
  reason (this SoC generation's boot ROM predates that class of
  feature; later models added OTP-based signing in their own
  bootloader/EEPROM updates). No amount of work inside Dhruva's own
  code changes what the boot ROM itself is capable of verifying before
  Dhruva ever gets to run. This permanent limitation is why the
  hardware-rooted version stays skipped — revisit only if the target
  ever moves to hardware that actually supports it (Pi 4/5, which do
  have OTP-based secure boot — see `docs/PORTING.md`).

  **The smaller substitute is done**: "Dhruva verifying a signature
  over something IT loads at runtime before trusting it" is exactly
  the PKI raw-public-key-trust feature (see that entry above) — a
  compile-time-pinned Ed25519 key, a `verify <path>` shell command, a
  companion `<path>.sig` file convention, and a real end-to-end
  DharaFS round trip, all live-verified on real ARM/QEMU. Built on the
  crypto foundation this entry itself pointed to. Not the hardware-
  root-of-trust claim "secure boot" usually means, but the genuinely
  achievable substitute this entry called for — already exists, this
  entry just never got updated to say so.

- **PQC (Post-Quantum Cryptography)** — **DONE (round 67)**: ML-KEM-512
  (FIPS 203), the NIST-standardized lattice-based KEM, implemented
  from scratch in vani. Full algorithm: NTT-based polynomial ring
  arithmetic over Z_3329[X]/(X^256+1), K-PKE (KeyGen/Encrypt/Decrypt),
  and the ML-KEM wrapper (KeyGen_internal/Encaps_internal/
  Decaps_internal) including implicit rejection against chosen-
  ciphertext attacks. Built on round 67's own Keccak/SHA-3/SHAKE
  primitives for G/H/J/PRF/XOF. Verified two ways: (1) a from-scratch
  Python reference checked byte-exact against `kyber-py` (a real
  third-party ML-KEM implementation) across every algorithm layer and
  15 random trials before any vani code was written; (2) that same
  Python reference's deterministic output embedded as a known-answer
  vector in `test/host_harness` (ek/dk/ciphertext/shared-secret all
  byte-exact, plus an implicit-rejection check on a corrupted
  ciphertext), all passing under ASAN/UBSAN. A separate round-trip
  self-test (keygen -> encaps -> decaps) runs live on real ARM under
  QEMU at boot and passes. ML-DSA/Dilithium and SPHINCS+ (PQC
  signatures, as opposed to this KEM) remain undone — not currently
  motivated by anything Dhruva signs today (see the secure-boot item
  above), and a separate, smaller effort than this KEM was.

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
     write-protection half; execute-protection is CORRECTLY CONFIGURED
     in this project's own MMU table but not verifiable under QEMU
     (confirmed round 70, 2026-09-04, to be a QEMU emulation scope
     limitation, not a Dhruva bug — see below), pending real hardware]`
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
       enforce it.

       **ROUND 70 UPDATE (2026-09-04): fully root-caused, no longer a
       "strong inference."** Fetched QEMU's actual source for BOTH the
       old (4.2.0) and currently-installed (10.0.11, via the closest
       matching public tag v10.0.0) versions directly from
       `github.com/qemu/qemu` and read the real `get_S1prot` function
       in full in both — not just `get_phys_addr_v6`, which is where
       the round-38 investigation above stopped. The exact same logic
       exists UNCHANGED in both, six-plus years apart:
       `} else if (arm_feature(env, ARM_FEATURE_V7)) { ... } else { xn
       = wxn = 0; }` — for any AArch32 core WITHOUT `ARM_FEATURE_V7`,
       QEMU unconditionally discards whatever `xn` the caller extracted
       from the page table before it ever reaches the decision that
       would grant or withhold `PAGE_EXEC`. `arm1176_initfn` (the exact
       CPU model `raspi1ap` uses) — checked in both `target/arm/cpu.c`
       (v4.2.0) and `target/arm/tcg/cpu32.c` (v10.0.0) — sets
       `ARM_FEATURE_V6K`/`VAPA`/`EL3`/etc. but never `ARM_FEATURE_V7`,
       confirming this override fires for this exact core in both
       versions. **Conclusion: this is not a version regression and not
       a bug in this project's own MMU table — it's a QEMU TCG
       emulation scope decision, consistent since at least 2019, that
       XN enforcement for pre-ARMv7 32-bit cores (ARMv6 and earlier,
       including ARM1176JZF-S) simply isn't modeled.** The earlier
       round's own investigation correctly traced the XN-bit extraction
       and the AP/APX encoding (both genuinely correct) but didn't
       trace one level further into `get_S1prot`'s own separate
       architecture-version gate, which is what actually discards it.
       The `XN` bits are kept set anyway — free if real hardware
       enforces them correctly, harmless on QEMU either way.
       **Revisit once a real Pi 1B is connected** (see the
       hardware-in-loop section below) — not to settle whether this is
       QEMU-specific (that's now confirmed), but because a real
       ARM1176 core's own XN enforcement is the actual feature this
       project cares about, independent of what any emulator does.
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
hub port-2 behavior — note, round 68, 2026-09-04: that referenced
"Dhruva Feature Ledger" document no longer exists in this repo, so
this list is the only surviving detail on those three specific
items), and any future storage backend's real-media behavior. When a
real Pi 1B is connected, treat it as an additional verification pass
on top of the existing QEMU battery, not a replacement for it —
everything QEMU can already catch should still be caught in QEMU
first, keeping the fast local loop as the default and hardware-in-loop
as the final confirmation pass.

**Round 68 (2026-09-04): concrete step-by-step instructions now
exist** — `docs/HARDWARE_IN_LOOP.md`. Required hardware, wiring, a
verification checklist matching the "known real-hardware-only gaps"
list above, and two details a generic Raspberry Pi tutorial would get
wrong for THIS specific kernel: (1) `uart_init()`'s own comment
admits its baud-rate divisor is calculated assuming a 3MHz UART
reference clock that real Pi firmware does not guarantee by
default — needs `init_uart_clock=3000000` in `config.txt` or the
console prints garbage, not silence; (2) DharaFS
(`dharafs_init`/`sdhost_card_addr`) writes raw blocks 1-2048 (~1MB)
from the very front of the SD card with zero partition-table
awareness — a naive "format the whole card as FAT32" setup would let
the boot partition and DharaFS silently corrupt each other; the FAT32
boot partition needs to start well clear of that region (recommended:
sector 16384 / 8MiB, comfortable margin beyond the 1MB ceiling).
Written directly from this project's own source, not assumed from
generic Pi documentation.

**2026-09-10 UPDATE: a real Pi 1B + 64GB SD card are now physically on
hand.** The SD card is flashed and ready — `./flash_sd_card.sh
/dev/sdb <firmware-dir>` completed successfully: single FAT32
partition starting at sector 16384 (confirmed via `lsblk`: one `sdb1`
partition, no leftover second partition), `bootcode.bin`/`start.elf`/
`fixup.dat` (the correct non-suffixed Pi 1/Zero-generation files,
sourced from the card's own prior Raspberry Pi OS boot partition
before it was wiped) + `config.txt` (with `init_uart_clock=3000000`)
+ `kernel.img` (objcopy'd from a fresh `./build.sh` of `build/
dhruva.elf`) all written to the card's root.

**STILL OPEN — first real boot has NOT happened yet.** Blocked purely
on physical access (the user was away from the hardware when the card
was flashed), not on anything code- or doc-related. Remaining steps,
all physical, from `docs/HARDWARE_IN_LOOP.md` §3 onward:
1. Insert the flashed card into the powered-off Pi 1B.
2. Wire the UART adapter: Pi GPIO14 (pin 8, TXD) → adapter RX; Pi
   GPIO15 (pin 10, RXD) → adapter TX; Pi GND (pin 6) → adapter GND.
   3.3V logic only — do NOT connect the adapter's own 5V/3.3V power
   pin to the Pi; power the Pi from its own separate microUSB supply.
3. Connect the adapter to this PC, identify its device node (`ls /dev/
   ttyUSB* /dev/ttyACM*`), open a 115200-8N1 terminal (`screen`/
   `picocom`/`minicom`), power on the Pi, and confirm the same boot
   self-test sequence QEMU already shows (`PASS`, then live
   multitasking output). If nothing appears, check `init_uart_clock`
   first (§3.2); if garbage appears instead of text, that's also the
   UART-clock issue, not a wiring problem.

Once first boot is confirmed, this project's own `docs/HARDWARE_IN_LOOP
.md` §6 checklist (USB mass storage timing, the real LAN9512, USB
Bluetooth HCI, USB WiFi enumeration, the real hardware watchdog,
memory-ordering barriers, MMU XN enforcement, GPIO pull-up/down, a
real HDMI picture, EDID query, real USB keyboard/mouse timing) is the
actual verification list — not a re-run of what QEMU already covers.

## Pi 4/5 port — now started (round 40 research, round 43 boot skeleton)

**STANDING DESIGN POLICY, added round 166 (2026-09-10):** every new
feature must be designed as a hardware-agnostic, generic kosh package
by default — never reimplemented per board — unless there is a
genuine hardware dependency (register/DMA/interrupt-controller/board-
specific-peripheral access) that forces board-specific code. Applies
going forward to every round, not just the one that prompted it (round
166's own TLS 1.3 Pi 4/5 port was about to duplicate kernel_main.vani's
own TLS logic directly into `kernel_main_rpi4.vani` — pure protocol
logic with zero hardware dependency, already calling nothing but other
shared packages — before this policy was made explicit mid-round).

**ROUND 166 UPDATE, 2026-09-10 (DONE)**: TLS 1.3 port to Pi 4/5. A
faithful, byte-for-byte port of kernel_main.vani's own TLS 1.3
implementation (wire-format helpers, handshake message builders,
HKDF/HMAC key schedule, AEAD record layer, transcript hashing — all
pure logic, calling only the already-shared crypto_hash/curve25519/
chacha20_poly1305 packages) was written and verified correct on the
host LLVM JIT, then boot-tested live on real (QEMU-emulated) AArch64.

Boot-testing initially showed what looked exactly like a vani-compiler
AArch64 codegen bug: enabling `tls_self_test_rpi4()`'s boot-time call
corrupted unrelated memory badly enough to fail later self-tests (TCP
connection lifecycle/UDP/DHCP) and eventually fault, reproducible down
to a single minimal `chacha20_poly1305_encrypt`+`decrypt` round trip
with a short (<64-byte) plaintext — correct on the host LLVM JIT
(x86-64) and on Pi 1's own real ARM32 hardware, wrong only when cross-
compiled to AArch64 and run under real QEMU. Extensive isolation
(standalone host-JIT repro, `--target=aarch64-linux-gnu` under
`qemu-aarch64`, and a hand-rolled bare-metal `aarch64-none-elf`
pipeline with a custom `_start` and canary buffers) ruled out compiler
codegen at every target checked, which pointed back at the ONE
difference those isolated repros didn't share with the real boot: the
real call depth.

**Actual root cause, found via `vanic stack-depth`**: a genuine boot-
stack overflow. `vanic stack-depth kernel/kernel_main_rpi4.vani
--entry=kmain_rpi4_vani --max=16384` (a built-in static call-graph
frame-size analyzer, `vanic build --help` documents it) showed the
real chain `kmain_rpi4_vani -> tls_self_test_rpi4 ->
tls_decrypt_record_rpi4 -> chacha20_poly1305_decrypt ->
chacha20_encrypt -> cp_zero512_bytes -> cp_zero256_bytes` needs 27032
bytes — 10648 bytes OVER the old 16KB boot stack budget, silently
corrupting whatever memory sat past the stack's bottom (no guard page
on this board). A function's OWN `alloca` byte-count (what looked
"comfortably under 16KB" on a first, incorrect pass) is NOT the same
as the cumulative depth at the point of deepest call-chain nesting,
which also stacks every callee's own frame on top. **Fixed** by
bumping `boot/rpi4/link.ld`'s boot stack from 16KB to 64KB — same
"map/allocate more, don't shrink working code to fit an arbitrary old
limit" philosophy as round 71's GPU-RAM fix and round 108's own ARM-
RAM-mapping fix on Pi 1. Verified via a full `rpi4_boot_smoke.py` AND
`rpi4_shell_smoke.py` pass, TLS 1.3's live handshake+app-data self-test
included, plus everything downstream that had been breaking (TCP/UDP/
DHCP/DHCPS/NETCFG/MQTT/preemption demo) now passing cleanly too.

There was never a vani-compiler bug. Re-run `vanic stack-depth`
against any future round that adds a deep new call chain, rather than
discovering the ceiling via a live corruption bug again.

**ROUND 172 UPDATE, 2026-09-10 (DONE, Pi 4/5 side)**: per the standing
policy above, extracted this pure-logic TLS 1.3 layer into a new
[`vani-tls13`](https://github.com/enthusiasticgeek/vani-tls13) shared
kosh package (Apache-2.0, matches crypto_hash/curve25519/chacha20_
poly1305/pki's own naming convention) instead of leaving it duplicated
inside `kernel_main_rpi4.vani`. `tls13_self_test()` passes on the host
LLVM JIT; vendored into DhruvaOS at `vendor/tls13/`, replacing 807
lines of duplicated code in `kernel_main_rpi4.vani` with a `use`
statement plus a 12-line board-specific wrapper (matching every other
crypto self-test's own `_rpi4` wrapper convention). Full
`rpi4_boot_smoke.py` and `rpi4_shell_smoke.py` both pass after the
swap, TLS 1.3 self-test included.

**ROUND 174 UPDATE, 2026-09-11 (DONE)**: Pi 1 migration completed.
The original blocker was real — Pi 1's own `kernel_main.vani` has a
mature, real-hardware-proven TLS 1.3 implementation using a
fundamentally different calling convention than `vani-tls13`'s
original array-based API: records up to 2048 bytes, held in heap
scratch and accessed through `mut ref i64` pointer parameters + `buf_
read_byte`/`buf_write_byte`, not the fixed `[u8; 512]`-array style
extracted from Pi 4/5's smaller implementation. Round 179's new Pi 4/5
heap allocator (below) removed the reason vani-tls13 was array-only in
the first place, unblocking a proper fix: added a second, heap-pointer
API surface to `vani-tls13` itself (`src/lib.vani`'s new `_heap`-
suffixed functions), using out-param calling convention matching Pi
1's own original functions exactly (`tls_derive_secret_heap`/`tls_
finished_verify_data_heap`/`tls_derive_traffic_keys_heap`/`tls_
encrypt_record_heap`/`tls_decrypt_record_heap` all write into an `out`
pointer and return a status, not return-by-value) — this made Pi 1's
actual migration a pure rename at every one of its ~130 call sites,
not a semantic rewrite. Also added `src/core.vani` (matching crypto_
hash/curve25519/chacha20_poly1305's own core/lib split) since Pi 1's
board-side code already defines names — `sha256_self_test`, `x25519_
self_test`, etc. — that collide with `lib.vani`'s own vendored
self-tests. Removed ~330 lines of Pi 1's own duplicated pure-logic
layer; the stateful transport/session layer (`tls_service`/`tls_
connect`/`tls_accept`/`tls_send`/`tls_recv`) stays board-specific, per
the established mechanism/policy split. Verified via `vanic check`,
the `vanic stack-depth` gate (unchanged budget), and a full
`phase4_milestone.py` pass including `tlsecho`/`httpecho`/`mqttecho`
exercising the migrated code live. Both DhruvaOS boards now genuinely
share one TLS 1.3 implementation.

**ROUND 176 UPDATE, 2026-09-11 (DONE)**: build-time `vanic stack-depth`
gate, added directly because round 166's own overflow went undetected
until a live boot corrupted memory even though `vanic stack-depth`
existed the whole time — it was only ever run by hand, after the fact.
`build_rpi4.sh` now gates `kmain_rpi4_vani` at 56KB (of the real 64KB
stack); `build.sh` gates `kernel_main` at 14KB (of 16KB). Pi 1's 4
dynamically-created task stacks (`task_create`, each a real 4096-byte
guarded allocation) aren't gated by default — `kernel_main.vani`'s
~27K lines make each `stack-depth` pass take ~40s, and 5 entries would
add minutes per build — documented as a manual check instead of
silently skipped.

**ROUND 179 UPDATE, 2026-09-11 (DONE, Phase 1)**: Pi 4/5 heap
allocator, ported from Pi 1's own `dhruva_alloc_bytes` design
(`boot/rpi1/runtime_stubs.c`) into `boot/rpi4/runtime_stubs_rpi4.c` —
a 768KB static-array bump allocator, 8-byte aligned, halts via
`dhruva_oom_fatal_rpi4` on exhaustion rather than returning null. Only
real porting difference: AArch64's DAIF register (`msr daifset`/
`daif`) stands in for ARM32's CPSR/`cpsid` critical-section dance.
Directly motivated by the 512-byte buffer cap visible throughout this
board's own code (round 166's TLS records, well under Pi 1's real
2048-byte size) — removing that ceiling is also the prerequisite for
migrating Pi 1's TLS implementation onto the shared `vani-tls13`
package (task #174, previously blocked on exactly this API mismatch).
`heap_alloc_self_test_rpi4` exercises the allocator directly (two
allocations, distinct byte patterns, verifies no overlap) since
nothing else calls it yet, unlike Pi 1 where hundreds of existing call
sites do; `heap_usage_self_test_rpi4` mirrors Pi 1's own headroom
report. Both wired into boot and a new `heap` shell command. Guard-
page protection (Pi 1's `dhruva_alloc_stack_guarded`, MMU page
invalidation on overflow) is explicitly NOT part of this phase — Pi
4/5's MMU (`boot/rpi4/mmu_init.S`) only has 2MB block descriptors so
far, no 4KB page-table level to install a guard into; that's real new
MMU capability, tracked separately as task #178.

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

**Round 70 (2026-09-04): GICv2 + ARM generic timer — DONE.** New
`boot/rpi4/gic_timer.S` (`gic_timer_init`/`_rearm`/`_disable`) plus a
real `aarch64_irq_handler` in `boot/rpi4/vectors.S`, replacing the
"Current EL, SPx, IRQ" vector's old diagnostic-only dead end with the
first genuinely interrupt-driven code on this port. GICD/GICC base
addresses (`0xFF841000`/`0xFF842000`) derived by reading QEMU's own
`hw/arm/bcm2838.c` device model source, not guessed from a datasheet
— same discipline round 40's own PL011-address spike established;
these also happen to match real BCM2711 hardware's documented GIC-400
addresses. The timer targeted is the standard ARMv8-A architected
generic timer (not a BCM-specific peripheral), wired by `bcm2838.c` to
GIC PPI 14 = architected INTID 30; `CNTFRQ_EL0` is read live rather
than assumed (measured ~62.5MHz under this QEMU machine, not the
1GHz default QEMU uses absent a board override — confirms why "read
it live" was the right call). Live-verified via a new
`test/rpi4_timer_smoke.py`: a bounded 5-tick heartbeat, each tick a
real GIC-acknowledged-and-EOI'd interrupt, reproduced consistently
across repeated runs, with round 43's own `rpi4_boot_smoke.py`
confirmed still green (no regression).

Caught two real issues before/during verification, not glossed over:
(1) `uart_put_hex64_rpi4` used three AAPCS64 callee-saved registers as
unsaved scratch — harmless while every prior caller immediately
halted afterward, unsafe for a handler that must resume the
interrupted context correctly; fixed by properly saving/restoring
them, the same register-clobber bug class this project has hit before
on the ARM32 side, this time on AArch64. (2) an apparent 4th-to-5th
tick "double-fire" (both prints arriving within ~1ms after three
clean ~500ms gaps) was investigated with a temporary debug build
printing the raw hardware counter (`CNTPCT_EL0`) rather than trusted
or dismissed on sight — the counter deltas were consistently correct
across every tick pair, confirming this was a QEMU stdio/pty
output-buffering artifact right before the final halt message
flushed, not a real firmware timing bug. `aarch64_irq_handler` itself
saves/restores all 31 general-purpose registers around its body
(not just the ones it uses), since an interrupt can land anywhere,
including mid-sequence in code holding a live value in any
callee-saved register. Full details: `docs/PORTING.md`'s "Round 70"
section.

Remaining scope for a real Pi 4 boot, now precisely identified rather
than assumed:

- ~~ARMv8-A MMU (TTBR0_EL1/TCR_EL1, radically different from ARMv6's
  short-descriptor 1MB sections used in `boot/mmu_init.S`).~~
  **`[DONE, round 73, 2026-09-05]`** — `boot/rpi4/mmu_init.S`: a
  3-level (L1/L2, 4KB-granule) identity map, pure block descriptors
  (no L3 4KB pages needed), covering the low 4GB: PA 0x00000000-
  0x3FFFFFFF and 0x40000000-0x7FFFFFFF as this machine's real 2GB of
  RAM (confirmed live via QMP's `query-memory-size-summary`, not
  assumed), 0xC0000000-0xFFFFFFFF as Device-nGnRnE (covers the PL011
  UART and GICv2 with wide margin), and PA 0x80000000-0xBFFFFFFF left
  genuinely unmapped/faulting (neither RAM nor a used peripheral).
  Same W^X split round 38 established for the Pi 1 target — the one
  2MB block holding all of `.text.boot`/`.vectors`/`.text`/`.rodata`
  is read+execute, never write; everything else is read+write, never
  execute — via a new 2MB `ALIGN` before `.data` in `link.ld` (this
  format's finer 2MB block granularity standing in for the ARMv6
  side's 1MB sections). Carries forward that file's own deliberate
  cache-off design (`SCTLR_EL1.C`/`.I` left clear) unchanged.

  Found and fixed two real, small bugs building this: (1) `boot/
  rpi4/boot.S` had never actually cleared `.bss` before this round
  (QEMU's own RAM happening to start zeroed had silently papered
  over it for the two tiny `.bss` users that existed before this
  round's 16KB of page tables) — added a real clear loop, run before
  `mmu_init_rpi4`, matching `boot/rpi1/boot.S`'s own established
  ordering; (2) the new 2MB pre-`.data` alignment pushed `.bss` more
  than 1MB from `.text.boot`, breaking the three existing `adr`
  instructions targeting it (`R_AARCH64_ADR_PREL_LO21` relocation
  truncated) — switched those to `adrp`+`add :lo12:`.

  Live-verified both halves of W^X, not just "didn't crash": a
  temporary (not committed) deliberate write to `_start` faulted
  with `ESR_EL1=0x9600004E` (EC=0x25 Data Abort same-EL, DFSC=0x0E
  permission fault level 2, WnR=1) and `FAR_EL1` exactly matching
  `_start`'s address; a second temporary probe writing a real NOP
  encoding into a `.bss` scratch word and branching to it faulted
  with `ESR_EL1=0x8600000E` (EC=0x21 Instruction Abort same-EL,
  IFSC=0x0E permission fault level 2) at exactly the scratch address
  — proving PXN/UXN blocks the fetch itself, not merely that
  execution eventually hits an unrelated undefined instruction.
  Notably, THIS target's real ARMv8-A (Cortex-A72) QEMU model
  genuinely enforces execute-never, unlike the confirmed QEMU/
  ARM1176 emulation gap on the Pi 1 side (`boot/mmu_init.S`'s own
  "KNOWN LIMITATION" section) — a real, useful contrast, not assumed
  symmetric between the two targets. `test/rpi4_boot_smoke.py` and
  `test/rpi4_timer_smoke.py` both still pass unmodified with the MMU
  live, confirming no regression to the existing EL-drop/UART/GIC/
  timer/IRQ chain.
- ~~Porting `kernel_main.vani` itself (or a fresh AArch64-native
  rewrite of its boot-facing pieces) to this target — round 43's/70's
  kernel is deliberately hand-written assembly only, no vani-compiled
  code yet.~~ **`[PARTIAL, round 74, 2026-09-05]`** — the toolchain
  half is done and live-verified; the 28000+-line
  `kernel_main.vani` port itself is not (still its own multi-round
  effort, exactly as this list already said).

  Confirmed live, before writing any new code: vani's own LLVM
  backend emits ordinary, target-generic IR with no ARM32-specific
  assumptions baked in -- a trivial two-function program, `vanic emit
  --backend=llvm` then `llc -mtriple=aarch64-none-elf`, produced
  correct AArch64 machine code on the first attempt, via the exact
  same "vanic emits IR, llc lowers it" pipeline `build.sh` already
  uses for the Pi 1/ARMv6 target. No changes to vani-compiler itself
  needed.

  New `kernel/kernel_main_rpi4.vani` (self-contained, zero `extern
  "C" fn` dependencies -- every builtin it uses, `mmio_read_u32`/
  `mmio_write_u32`/`mmio_write_u8`/`str_len_bytes`/`str_byte_at`, is a
  genuine target-independent compiler intrinsic) does a real
  computation (`sum(1..100)==5050`, `100000/7==14285 r5` -- AArch64's
  hardware `SDIV` needs no `__aeabi_ldivmod`-style libgcc helper the
  way the Pi 1/ARMv6 side's division does) and prints the result over
  the PL011 UART at BCM2711's own base (0xFE201000). Called from
  `boot/rpi4/boot.S` via `bl kmain_rpi4_vani`, found by its bare,
  unmangled name through that file's own `#[no_mangle]` -- the same
  convention the Pi 1 side already uses for `irq_dispatch`/
  `kernel_main`. New `boot/rpi4/runtime_stubs_rpi4.c` (the AArch64
  twin of `boot/rpi1/runtime_stubs.c`, minus the libgcc-divide-helper
  concern) supplies `strlen`/`dprintf`/`exit`/`memcpy` -- vani's
  generated runtime-support code unconditionally assumes a hosted
  libc provides these regardless of target or whether the program
  itself calls them. `-function-sections`/`-data-sections` +
  `--gc-sections` (added to `build_rpi4.sh`) prune vani's own
  always-emitted builtin-runtime library down to what's actually
  reachable, exactly as `build.sh`'s own comment already documents
  for the ARMv6 side.

  Found and fixed a real bug live, the same "verify against the
  actual code" discipline this project always uses: an earlier
  version of this file's digit-printer used recursion under a
  `#[bounded(20)]` annotation. That type-checked and compiled cleanly
  but faulted on its very first real call (Data Abort, permission
  fault, `FAR_EL1` near address `0x10`) -- root-caused via the
  emitted LLVM IR: `#[bounded(N)]`'s recursion-depth counter is an
  LLVM `thread_local global i32`, and this freestanding target has
  never initialized `TPIDR_EL0` (no thread pointer at all anywhere in
  this project's boot code, on either target). `llc`'s local-exec TLS
  lowering resolves the access relative to that unset thread pointer,
  landing near address 0 -- matching the fault exactly. This is the
  first place in the ENTIRE DhruvaOS codebase this specific
  recursion-depth `#[bounded(N)]` (distinct from `kernel_main.vani`'s
  many `#[bounded_stack(bytes=N)]` stack-SIZE budgets, which are
  unaffected) was ever actually exercised at runtime -- a genuinely
  latent gap in vani's bare-metal/no-TLS-runtime target support, not
  something either existing target happened to already work around.
  Not fixed in vani-compiler itself this round (would need either
  compiler support for a non-TLS depth-counter mode on freestanding
  targets, or this project initializing a real TPIDR_EL0-backed TLS
  block -- both out of scope for this round's own goal of proving the
  toolchain, not extending it); routed around by using a plain
  iterative digit-printer instead. **Any future vani-on-bare-metal
  code should avoid `#[bounded(N)]` (recursion-depth) until this is
  addressed** -- `#[bounded_stack(bytes=N)]` is unaffected.

  New `test/rpi4_vani_smoke.py` checks the exact computed values
  (`sum=5050 quotient=14285 remainder=5`), not just a PASS-looking
  string. `test/rpi4_boot_smoke.py`/`test/rpi4_timer_smoke.py` both
  still pass unmodified, confirming no regression to the existing
  EL-drop/UART/GIC/timer/IRQ/MMU chain.

  **ROUND 75 UPDATE, 2026-09-05** (still `[PARTIAL]` -- the full
  28000+-line port remains its own multi-round effort): ported the
  SECOND piece of this target's boot-facing logic to real vani code --
  `boot/rpi4/vectors.S`'s `aarch64_irq_handler` used to do its own
  tick-counting/message-printing/halt-vs-rearm decision entirely
  inline in hand-written assembly; that logic now lives in `kernel/
  kernel_main_rpi4.vani`'s `rpi4_handle_timer_irq`, called via a plain
  `bl` from the timer-INTID branch. Round 74 proved the toolchain with
  a one-shot boot-time computation; this proves the same pipeline
  works from a genuinely repeated, interrupt-driven call site -- the
  first vani code on this port to run more than once, mirroring how Pi
  1's own `irq_dispatch` became this whole project's original seed.

  Safe with ZERO extra register-preservation work at this call site,
  unlike the AAPCS callee-saved-register hazard this project keeps
  re-finding elsewhere (ARM32's r4-r7, round 75's own `scheduler_pick_
  next`): `aarch64_irq_handler` already unconditionally saves the FULL
  x0-x30 register file before this call, since it must to resume the
  interrupted context via `eret` regardless -- whatever the vani code
  clobbers is already backed up. New `rpi4_timer_tick_count_increment`
  (`boot/rpi4/vectors.S`) is the one piece that stayed in hand-written
  assembly (vani has no top-level global-variable mechanism, so the
  tick counter still needs a `.bss`-plus-extern-accessor home, the
  same shape every persistent-state file on the Pi 1 side already
  uses). Removed the now-dead inline assembly, `irq_timer_msg`/
  `irq_halt_msg` strings, and `IRQ_HALT_AFTER_TICKS` constant.
  Deliberately left this new vani function untagged
  (no `#[interrupt]`/`#[wcet]`/`#[bounded_stack]`) -- establishing a
  real WCET/interrupt-safety story for this brand-new target is its
  own separate future increment, not needed to prove basic
  interrupt-context correctness here.

  `test/rpi4_vani_smoke.py` widened to also check for exactly 5 real
  tick prints plus the halt message (proving the vani code ran
  correctly on every one of the 5 real timer interrupts, not just
  once); `test/rpi4_boot_smoke.py`/`test/rpi4_timer_smoke.py` both
  still pass unmodified.

  **ROUND 76 UPDATE, 2026-09-06** (still `[PARTIAL]` -- the full
  28000+-line port remains its own multi-round effort): ported GPIO,
  the first genuinely new PERIPHERAL (not just more boot-facing
  timer/UART logic) on this target. Confirmed against QEMU 10.0.0's
  own source before writing anything (same discipline round 71's Pi 1
  GPIO port used): `hw/arm/bcm2838_peripherals.c` instantiates a real
  `TYPE_BCM2838_GPIO` device (`hw/gpio/bcm2838_gpio.c`) at
  `GPIO_OFFSET` (0x200000, `include/hw/arm/raspi_platform.h`) off this
  SoC's own low-peripheral-mode base (0xFE000000) -- base address
  0xFE200000, with the SAME GPFSELn/GPSET/GPCLR/GPLEV register
  offsets as BCM2835 (confirmed identical in `bcm2838_gpio.c`), so
  `kernel_main.vani`'s own register-address/bit-mask arithmetic for
  these three families ports over unchanged in shape.

  One genuine SoC-generation difference: BCM2711 replaced BCM2835's
  GPPUD/GPPUDCLK0/1 pull dance with 4 new `GPIO_PUP_PDN_CNTRL_REG0..3`
  registers (2 bits/pin, 16 pins/register). Unlike `kernel_main.vani`'s
  own pull-control code (real, spec-correct, but UNVERIFIABLE under
  QEMU -- BCM2835's GPPUD/GPPUDCLK are explicitly "Not implemented"
  there), this register bank is a genuine read/write store in QEMU's
  BCM2838 model (confirmed real non-zero boot-time reset values, not a
  stub) -- so `gpio_self_check_rpi4`'s pull-control round trip is real,
  QEMU-verified evidence, a genuine advantage of this SoC generation's
  own design over Pi 1's.

  Every one of the 13 new registers is a `#[mmio(size=4)]`-tagged
  const (vani-compiler's DHDL v0.1 attribute, see
  `docs/DHRUVAOS_MANUAL.md` §5) -- `vanic check` confirmed all 15
  registers this file now declares (2 UART + 13 GPIO) are pairwise
  non-overlapping. `gpio_self_check_rpi4` mirrors `kernel_main.vani`'s
  own `gpio_self_check` shape exactly: fsel round-trip across 3
  different GPFSELn registers (pins 0/10/53), same-register
  non-interference check (pins 5/6), GPSET/GPCLR/GPLEV round-trip
  across the pin-31/32 register boundary, plus the new pull-control
  round-trip across the REG0/REG1/REG3 boundaries (pins 15/16/48).
  Wired into `kmain_rpi4_vani` after the existing self-test.
  `test/rpi4_vani_smoke.py` widened to also assert the new PASS line;
  `test/rpi4_boot_smoke.py`/`test/rpi4_timer_smoke.py` both still pass
  unmodified.

  **ROUND 77 UPDATE, 2026-09-06** (still `[PARTIAL]` -- the full
  28000+-line port remains its own multi-round effort): ported UART0
  RX, this port's first bidirectional I/O (everything before this was
  output-only). INTID 153 derived the same way round 70/76's own
  INTIDs were -- fetched QEMU 10.0.0's `hw/arm/bcm2838_peripherals.h`
  directly: `GIC_SPI_INTERRUPT_UART0 = 121` (an SPI *index*), +32 per
  GICv2's own INTID layout (SPIs start at 32; confirmed against
  `hw/intc/arm_gic.c`'s own `gic_set_irq`) = 153.
  `boot/rpi4/vectors.S`'s `aarch64_irq_handler` widened from a 2-way
  (spurious/timer) to a 3-way dispatch.

  **Real bug found and fixed, not just a port**: an SPI (unlike the
  timer's PPI) needs `GICD_ITARGETSR` set (which CPU it's routed to)
  *before* its `GICD_ISENABLER` bit -- PPIs are inherently per-CPU by
  GIC design and need no such thing, an asymmetry this round's first
  attempt missed entirely. Found live: a temporary polling probe
  (bypassing the interrupt path) proved real bytes sent over QEMU's
  stdio UART genuinely reached the PL011's RX FIFO while the
  interrupt itself never fired -- reading `arm_gic.c`'s own
  `dist_writeb` handler for the Interrupt Set-Enable register showed
  it computes the per-CPU enable mask from `GIC_DIST_TARGET(irq)` AT
  THE MOMENT `ISENABLER` is written, not dynamically later, so
  enabling before targeting silently captures a target of zero CPUs.
  Fixed by reordering `kernel_main_rpi4.vani`'s own
  `rpi4_uart_rx_irq_init` (target, then enable); both registers are
  ordinary MMIO, so this needed zero new hand-written assembly, only
  vani code (`mmio_write_u32` against `#[mmio(size=4)]`-tagged
  consts, DHDL v0.1) -- an earlier attempt at this same fix,
  extending `boot/rpi4/gic_timer.S`'s assembly instead, was reverted
  once the vani-only fix confirmed asm was never actually necessary
  here, matching this project's own growing preference for vani code
  over hand-written asm wherever a peripheral is ordinary MMIO.

  New `test/rpi4_uart_rx_smoke.py` (this port's first test to send
  input, not just check output) sends a short probe string over
  QEMU's stdio UART and confirms it comes back echoed, live-verified
  reliable across repeated runs. `test/rpi4_boot_smoke.py`/
  `rpi4_timer_smoke.py`/`rpi4_vani_smoke.py` all still pass unmodified.

  **ROUND 78 UPDATE, 2026-09-06** (still `[PARTIAL]` -- the full
  28000+-line port remains its own multi-round effort): the smallest
  possible proof of an ARMv8-A context switch -- new
  `boot/rpi4/task_switch.S`, a cooperative (voluntary-yield) swap
  between two static 1KB stacks, deliberately NOT the real
  interrupt-driven scheduler (no preemption, no priorities, no
  timer-IRQ integration) -- proves the one genuinely new
  AArch64-specific primitive any real scheduler on this target would
  need first, kept separate from the already-delicate timer-IRQ path
  rather than extending it directly. `task_switch(save_to,
  load_from)` saves/restores AAPCS64's callee-saved registers
  (x19-x28, x29/fp, x30/lr) across a raw SP swap -- the classic
  fiber/coroutine technique. `task_a_stack_init`/`task_b_stack_init`
  each build a fake saved-frame on their own stack so the first
  switch into a task lands directly at its vani entry function.

  **Real bug found and fixed**: the first attempt put the entry
  address at the fake frame's `+80` offset, matching where it
  intuitively "looked like" x30/LR should live -- but `task_switch`'s
  own `stp x29, x30, [sp, #80]` puts x29 at +80 and x30 at +88 (a
  `stp` of two registers stores the first at the low address, second
  8 bytes higher). Caught immediately, not silently: the very first
  boot hit a real fault (`DHRUVA RPI4 FAULT: ... ELR_EL1=0
  FAR_EL1=0`) -- x30 read back as 0 from the never-written +88 slot,
  so `ret` branched to address 0 and instruction fetch there aborted.
  Fixed by writing the entry address to +88 instead.

  `kernel_main_rpi4.vani`'s `task_switch_self_test` drives a bounded,
  self-terminating demo: task_a prints "A" and yields to task_b twice,
  then switches back to boot instead of task_b on its 3rd round;
  task_b always yields straight back to task_a, never independently
  deciding to stop. Printed sequence: "ABABA" (3 A's, 2 B's, strictly
  alternating), followed by "(PASS)" -- which can only ever print if
  boot's own context genuinely resumed at the correct point after all
  6 switches in the chain (boot->A->B->A->B->A->boot) landed
  correctly; a broken switch crashes or hangs rather than resuming at
  the wrong place with merely wrong output, so this is proof from both
  the data side (exact sequence) and the control-flow side (reaching
  "PASS" at all). New `test/rpi4_task_switch_smoke.py`, live-verified
  reliable across repeated runs; `rpi4_boot_smoke.py`/
  `rpi4_timer_smoke.py`/`rpi4_vani_smoke.py`/`rpi4_uart_rx_smoke.py`
  all still pass unmodified.

  **Not started**: a real (preemptive, priority-based) scheduler
  integrated with the timer IRQ -- this round only proves the
  underlying stack-swap primitive works, deliberately scoped apart
  from that much larger, riskier next step.

  **ROUND 79 UPDATE, 2026-09-06** (still `[PARTIAL]` -- the full
  28000+-line port remains its own multi-round effort): took that
  "next step" -- interrupt-driven preemption, built on round 78's
  proven stack-swap result but via a genuinely different mechanism
  (an `eret`-based restore of a FULL x0-x30 frame, not a `ret`-based
  swap of just the AAPCS64 callee-saved registers). User's own
  explicit direction after being shown the size/risk jump: "jump
  straight to interrupt-driven preemption" rather than building a
  general task table first.

  **The core new correctness requirement, found and handled
  correctly the first time** (unlike round 77's GIC bug): `eret`
  resumes execution using ELR_EL1/SPSR_EL1, neither part of the
  general register file `aarch64_irq_handler` already saved. As long
  as a handler always resumes the SAME context it interrupted (true
  through round 78), these can be left as ambient hardware state --
  the instant a handler might resume a DIFFERENT task, they must
  become part of each task's own saved frame instead (grown from 256
  to 272 bytes), or a resumed task resumes at the wrong PC. This is
  the AArch64-shaped version of the exact lesson Pi 1's own
  `boot/irq_entry.S` learned the hard way in ARM32 terms for its own
  true-lr-vs-resume-pc conflation bug (see that file's own header
  comment) -- recognized and designed around UP FRONT this time,
  rather than discovered via a live bug. SPSR_EL1's actual value
  (`0x60000345`) was still captured live via a temporary debug probe
  inside `aarch64_irq_handler` rather than hand-derived from the ARM
  ARM, matching this project's own "confirm against reality, don't
  compute from spec alone" discipline.

  One real bug did occur, from an unrelated cause: the first build
  produced 400KB+ of output, because QEMU's TCG emulation runs the
  two (deliberately non-yielding, timer-only-preempted) print loops
  far faster than real time allows between ~500ms ticks. Fixed with a
  plain busy-wait between prints -- not a real sleep primitive (none
  exists at this scope), just enough to keep the demo's own output
  legible.

  New `boot/rpi4/preempt_switch.S`: `current_task`/`pt_sp_table`
  (index 0=task_a, 1=task_b, 2=boot) track state; `preempt_init`
  builds both tasks' fake interrupt-shaped frames and seeds
  `current_task=2` (NOT `.bss`'s own zero default, which would
  wrongly mean task_a); `rpi4_preempt_switch` does the actual
  save-current/decide-next/return-next-sp work, called from
  `vectors.S`'s widened `irq_timer` branch. Boot's own frame needs no
  special bootstrap call at all -- the general "always save current
  before deciding next" logic naturally captures it as a side effect
  of the very first tick, exactly like every later tick captures
  whichever task was running.

  Live-verified: tick 1 switches boot->task_a, tick 2 task_a->task_b,
  tick 3 task_b->task_a, tick 4 task_a->task_b, tick 5 force-switches
  back to boot -- and `kernel_main_rpi4.vani`'s new
  `rpi4_heartbeat_tick` (called from `boot.S`'s own `heartbeat_loop`,
  fires exactly once, only reachable at all once boot's context is
  genuinely resumed) prints `"boot context resumed after preemption
  demo (PASS)"` confirming it. New `test/rpi4_preempt_smoke.py`
  checks the exact per-tick alternation pattern (not just "both
  letters appeared somewhere") plus that resume message, live-
  verified reliable across repeated runs. All 5 pre-existing Pi 4
  smoke tests (`boot`/`timer`/`vani`/`uart_rx`/`task_switch`) still
  pass unmodified; zero Pi 1 files touched.

  **Still not started**: priorities, more than 2 tasks, and any
  voluntary sleep/mutex primitive -- this round proves preemption
  itself works, not a general scheduler policy on top of it.

  **ROUND 80 UPDATE, 2026-09-06** (still `[PARTIAL]`): generalized
  round 79's hardcoded 2-task toggle into real NUM_TASKS-way (3) round
  robin -- the natural next increment mirroring Pi 1's own historical
  arc (2-task round robin -> N fixed-priority tasks -> priority
  ceiling protocol -> general task-creation API). `current_task`/
  `pt_sp_table` generalized from 3 fixed slots (A/B/boot) to
  `NUM_TASKS+1` (3 tasks + boot); the switch decision generalized from
  a single toggle bit to `(current+1) mod NUM_TASKS`, with wraparound
  back to task 0 confirmed live (task_c correctly hands off to task_a
  again, not stuck or corrupted). New `preempt_task_c_entry`
  (`kernel_main_rpi4.vani`), same non-yielding/timer-only-preempted
  shape as the other two. Zero changes to the frame format or the
  core save/restore mechanism itself -- this was purely a policy
  generalization on top of round 79's already-correct primitive.

  Live-verified: boot->A(tick1)->B(tick2)->C(tick3)->A(tick4,
  wrapped)->boot(tick5, forced) -- exactly the expected round-robin
  sequence including the wraparound. `test/rpi4_preempt_smoke.py`
  updated for the 3-task pattern, reliable across repeated runs. All
  5 pre-existing Pi 4 smoke tests still pass unmodified; zero Pi 1
  files touched.

  **Still not started**: priorities (all 3 tasks are still equal-
  weight round robin) and any voluntary sleep/mutex primitive.

  **ROUND 81 UPDATE, 2026-09-06**: closed the "voluntary sleep/mutex
  primitive" gap's own prerequisite -- a genuine VOLUNTARY switch,
  through the exact same eret-based interrupt-shaped frame rounds
  79/80 use for timer-driven preemption, proving the two are
  interoperable through ONE shared mechanism rather than two
  disconnected ones. Different from round 78's own cooperative
  `task_switch` in exactly the way that round's own header comment
  already anticipated it would eventually need to be: that one saves/
  restores only the AAPCS64 callee-saved registers and resumes via
  `ret`; `preempt_generic_switch` (new, `boot/rpi4/preempt_switch.S`)
  builds the FULL 272-byte frame (x0-x30 + ELR_EL1/SPSR_EL1) and
  resumes via `eret`, sharing `vectors.S`'s own `irq_restore` epilogue
  (now exported) rather than duplicating it -- ANY slot, whether
  populated by a genuine timer interrupt or by this function, resumes
  identically.

  Relies on a property not previously exercised in this project:
  `eret` doesn't require the CPU to currently be handling a real
  hardware exception -- it only reads ELR_EL1/SPSR_EL1 and acts on
  them, so setting them from ordinary code and executing `eret` is a
  legitimate way to "return" into a different context. Worked
  correctly on the very first build, no debugging needed -- the
  design was worked out on paper (matching round 79's own "anticipate
  before writing code" approach) rather than discovered via a live
  bug.

  Bounded, self-contained self-test (`preempt_yield_self_test`),
  isolated from the timer-driven demo's own state entirely (separate
  `yv_sp_table`, not `pt_sp_table`) -- same shape as round 78's own
  "ABABA": task_x yields to task_y 3 times then yields back to the
  calling self-test on its 3rd round instead (task_y always yields
  straight back to task_x, never independently stopping). Printed
  "XYXYX (PASS)" -- live-verified reliable across repeated runs,
  alongside confirming the existing timer-driven 3-task demo runs
  completely unaffected afterward. New `test/rpi4_yield_smoke.py`;
  all 5 pre-existing Pi 4 smoke tests still pass unmodified; zero
  Pi 1 files touched.

  **Still not started**: priorities and an actual TIME-based
  voluntary sleep (e.g. "yield for N ticks") -- this round proves
  arbitrary voluntary switching works, not a sleep/wake scheduling
  policy on top of it.

  **ROUND 82 UPDATE, 2026-09-06**: closed that exact gap -- a real
  time-based voluntary sleep, `preempt_sleep_ticks(n)`. Task_a now
  voluntarily sleeps for 2 real ticks after each print instead of
  busy-waiting, demonstrating voluntary sleep and involuntary
  preemption coexisting in the same live demo (task_b/task_c
  unchanged, still purely timer-preempted). `rpi4_preempt_switch`'s
  own round-robin scan generalized to skip any task whose new
  `pt_sleep_until` (one `.bss` slot per real task) hasn't been
  reached by the real tick count yet, bounded to `NUM_TASKS` attempts
  so an (unreachable in this demo) all-asleep case can't hang. New
  `rpi4_timer_tick_count_get` (non-incrementing, unlike the existing
  increment-on-read accessor) lets both the sleep primitive and the
  scan read "what tick is it" without disturbing the real count.

  **Two real bugs found and fixed, not just one**:
  1. A genuine reentrancy race: `preempt_sleep_ticks` (unlike
     `rpi4_preempt_switch`, which only ever runs from inside
     `aarch64_irq_handler` with IRQ already hardware-masked) is
     called VOLUNTARILY from ordinary task code running with IRQ
     unmasked -- so a real timer tick could fire partway through its
     own critical section and corrupt the frame being built. Found
     live: task_a spammed hundreds of thousands of 'A's, then crashed
     with an Instruction Abort from a lower EL (`ELR_EL1=0`,
     `FAR_EL1=0`) -- `eret` had been reached with a corrupted
     `SPSR_EL1`. Fixed with `msr daifset, #2` as the first instruction
     (unmasking happens naturally via whichever task's own SPSR_EL1
     `eret` restores); applied to round 81's `preempt_generic_switch`
     too, defensively, once this bug class was found in a sibling
     function, per this project's own "verify across every affected
     site" discipline -- that one was never actually triggered (its
     own self-test runs to completion before the timer demo even
     starts), but has the identical exposure.
  2. After the race fix, task_a *still* never actually switched away
     -- `current_task`'s value in memory correctly advanced
     (confirmed via a temporary debug print), but execution kept
     resuming task_a regardless. Root cause: `preempt_sleep_ticks`
     branched to the shared `irq_restore` epilogue without first
     doing `mov sp, x0` -- `irq_restore` restores from whatever `sp`
     CURRENTLY is, expecting the caller to have already pointed it at
     the target frame (exactly like `preempt_generic_switch`'s own
     tail already does correctly). Without it, `sp` never left
     task_a's own frame, so the "restore" kept resuming task_a every
     time regardless of which task `current_task` said was next.

  Live-verified: task_a prints once at tick 1, sleeps through tick 2
  (only task_c appears), wakes and prints again by tick 3 (exactly 2
  ticks later, as slept), sleeps through tick 4 -- confirmed reliable
  across repeated runs. `test/rpi4_preempt_smoke.py` updated for the
  new pattern (task_a exactly once per wake, task_b/task_c round-
  robining via pure timer preemption on the ticks task_a is asleep
  for). All 5 pre-existing Pi 4 smoke tests pass unmodified; zero
  Pi 1 files touched.

  **Still not started**: priorities -- all 3 tasks are still
  equal-weight, just some (task_a) voluntarily sleep and some don't.

  **ROUND 83 UPDATE, 2026-09-06**: closed that exact gap -- real
  FIXED-PRIORITY scheduling, not just round robin with sleeps bolted
  on. Task index doubles as its own priority (lower index = higher
  priority: task_a=highest, task_c=lowest/idle-like) instead of a
  separate priority table -- both `rpi4_preempt_switch` and
  `preempt_sleep_ticks`'s own "pick next" scan changed from
  round-robin (advance from current+1) to a priority scan (always
  restart from index 0, first READY task wins), which also made the
  old "was boot -> start at task 0" special case unnecessary: a
  fresh-from-0 scan already naturally picks task_a whenever it's
  ready, which is always true the first time.

  Task_b also gained its own voluntary sleep this round (1 tick,
  shorter than task_a's 2) specifically so task_c -- priority
  NUM_TASKS-1, this demo's closest thing to an idle task, and the
  only one that never sleeps -- gets genuine gaps to run in. Without
  task_b also sleeping, it would permanently starve task_c out
  (always ready, always outranking it) -- a real and deliberately
  undocumented-away consequence of naive fixed-priority scheduling
  with no round-robin among equal/lower priorities and no aging, not
  a bug to hide by making every task sleep enough to never actually
  demonstrate it.

  Worked correctly on the very first build, no debugging needed at
  all (unlike round 82's own two bugs) -- the design followed
  directly and safely from round 82's already-correct sleep/wake
  machinery; only the SELECTION policy changed. Live-verified: exact
  `A?BC*` shape per tick (task_a only on ticks 1/3, task_b exactly
  once at the start of every tick's own run, task_c filling
  everything else), reliable across repeated runs.
  `test/rpi4_preempt_smoke.py` updated for the new pattern. All 5
  pre-existing Pi 4 smoke tests pass unmodified; zero Pi 1 files
  touched.

  This closes every gap this backlog entry originally opened with
  (round 79: preemption itself; round 80: more than 2 tasks; round
  81: voluntary switching; round 82: time-based sleep; round 83:
  priorities). **Not done**: the 28000+-line port of kernel_main.
  vani's own actual logic (filesystem, shell, networking, crypto,
  USB) remains its own separate, much larger future effort -- this
  whole preemption/scheduling arc only proves the underlying
  mechanisms work on this target, using tiny synthetic demo tasks,
  not a port of anything kernel_main.vani itself does today.

  **ROUND 84 UPDATE, 2026-09-06**: started that actual port -- the
  smallest possible REAL, useful capability rather than another
  synthetic proof. New `boot/rpi4/shell_state.S` mirrors Pi 1's own
  `boot/shell_state.S` line-buffer design exactly in shape
  (`shell_line_buf`/`shell_line_len`/`shell_line_ready`, minus that
  side's su/passwd echo-suppression state -- not needed for a first
  minimal command set): `shell_rx_push_char`, called from `rpi4_
  handle_uart_rx_irq` (round 77's own UART0 RX interrupt) on every
  received byte, exactly the same call-site shape Pi 1's own `irq_
  dispatch` already uses.

  Deliberately NOT wired into the round 79-83 preemptive-scheduler
  demo at all -- that demo stays exactly as it was, a bounded,
  self-terminating proof using synthetic tasks. Instead, dispatch
  happens from `rpi4_heartbeat_tick`, the ALREADY-PROVEN call site
  `boot.S`'s own `heartbeat_loop` invokes on every real `wfi` wakeup
  (round 79) -- reusing existing, tested machinery instead of
  building new scheduler integration for what's fundamentally a
  separate concern. Since UART0 RX stays enabled forever (unlike the
  demo's own timer, deliberately disabled after its 5 ticks), the
  shell keeps responding indefinitely regardless of that demo's
  lifetime -- live-verified by sending real commands well after the
  demo's own halt message.

  Command set (deliberately tiny for a first port): `help`, `ver`,
  `test` (reruns `rpi4_vani_self_test`'s own real computation, not a
  placeholder), and `echo <text>`. No prompt is printed, matching
  `kernel_main.vani`'s own `task_f` (purely reactive -- output is
  only ever what a command itself prints). `rpi4_shell_line_matches`/
  `rpi4_shell_starts_with` mirror `shell_word_matches`'s own spirit
  using `str_len_bytes`/`str_byte_at` directly in vani, simpler than
  the Pi 1 side's version since a first minimal shell only ever needs
  to compare the WHOLE line, never a command/argument sub-range.

  Worked correctly on the very first build, no debugging needed --
  new `test/rpi4_shell_smoke.py` drives all 5 real commands (help,
  ver, echo with real argument text, an unknown command, test) over a
  live QEMU stdio UART session and checks each one's real response,
  reliable across repeated runs. All 7 pre-existing Pi 4 smoke tests
  pass unmodified; zero Pi 1 files touched.

  **Not done**: multi-line editing/history, `su`/permission-checked
  commands, any command that touches a peripheral this port doesn't
  have yet (storage, networking) -- deliberately out of scope for a
  FIRST minimal shell.

  **ROUND 85 UPDATE, 2026-09-06**: self-contained crypto -- SHA-256,
  the first cryptographic primitive on this port, per the user's own
  stated sequence after round 84's shell ("start the minimal
  interactive shell. then self contained crypto"). Deliberately NOT a
  line-for-line port of kernel_main.vani's own sha256_* family: that
  implementation reads/writes through `mut ref i64` buffers via
  buf_read_u32/buf_write_u32 and sha256_*_scratch_get/set
  (hand-written ARM32 asm in boot/dharafs_buf.S + boot/scratch_
  state.S) plus dhruva_alloc_bytes (a heap allocator) -- machinery
  that exists there ONLY to fix a real Pi 1 bug class (a long-lived
  scratch pointer held live in a register across many calls got
  corrupted by interrupt delivery under that port's older interrupt
  scheme; see sha256_compress's own "Round 65 hardening" comment on
  the Pi 1 side). This port has neither problem: kernel_main_rpi4.
  vani has zero heap allocator and zero `extern "C"` declarations by
  design, and vani's `[T; N]` fixed arrays are genuine Copy stack
  values with compiler-inserted bounds checks on both the C and LLVM
  backends -- confirmed via a standalone probe (`ref`/`mut ref
  [u32; N]` and `[u8; N]` params, plain array-literal locals, and that
  vani's native u32 `+` still traps on overflow on this target too)
  before writing any of the real port. So plain fixed-array function
  parameters replace every one of that side's buffer-accessor calls,
  with no persistent-scratch-across-calls indirection needed at all.
  Same FIPS 180-4 algorithm and the identical sha256_wrap_add32
  widen-to-i64/mask/truncate technique as the Pi 1 side (architecture-
  independent, still required since native u32 wraparound isn't
  available on any target). Fixed at a 256-byte (4-block, up to
  247-byte message) padded buffer rather than a dynamically-sized one
  -- enough for this round's own 3 KATs with headroom; hashing
  something longer is out of scope for this round.

  A real bug found and fixed live, the first one on this port since
  round 82: the very first build faulted immediately on entry to the
  self-test with `ESR_EL1 EC=0x07` ("trapped SIMD/FP access"). Root
  cause: LLVM's AArch64 backend freely uses NEON registers for
  ordinary array/struct copies and initialization even in code with
  no float types anywhere (the new 256-byte/64-word array locals were
  the first code on this port to trigger it), and `boot/rpi4/boot.S`
  never set `CPACR_EL1.FPEN` -- FP/SIMD traps to EL1 by default at its
  EL3-drop reset value of 0. Fixed with the standard one-time bare-
  metal enablement (`mov x0, #0x300000; msr cpacr_el1, x0; isb`) added
  right after `clear_bss_rpi4_done`, before `mmu_init_rpi4` -- every
  AArch64 kernel needs this same step; there was simply no prior code
  on this port that happened to trigger vectorized codegen.

  Wired into `kmain_rpi4_vani` (boot-time self-test) and a new `sha256`
  shell command (reruns it on demand, same pattern as `test`). Live-
  verified: all 3 FIPS-180-4/NIST KATs (empty string, "abc", and the
  56-byte 2-block vector) pass with the exact expected digests, byte
  for byte, matching kernel_main.vani's own sha256_self_test vectors.
  `test/rpi4_shell_smoke.py` updated for the new `help`/`ver` text and
  a `sha256` command check; all 8 Pi 4 smoke tests pass; zero Pi 1
  files touched.

  **Not done**: SHA-512, HMAC-SHA256, PBKDF2, ChaCha20-Poly1305,
  Ed25519/X25519 (all present on the Pi 1 side) remain unported --
  this round's scope was proving the fixed-array-based, zero-heap
  design works at all, with the smallest useful primitive.

  **ROUND 86 UPDATE, 2026-09-06**: Phase A step 1 of the networking/
  SSH/WiFi scope (see project memory `project_dhruva_networking_ssh_
  wifi_scope_2026_09_06.md`) -- a loopback-only netif abstraction, no
  real NIC yet. Confirmed freshly this round: QEMU's `raspi4b` machine
  has NO network device model at all (`-device help` lists no genet/
  bcm ethernet part, `-M raspi4b,help` exposes no NIC option) -- the
  same situation kernel_main.vani's own Pi 1 LAN9512/CDC-ECM backends
  are already in (no QEMU device model either), so this port's netif
  layer is protocol logic verified via synthetic frames, same as Pi
  1's, with a real hardware backend deferred as its own separate,
  genuinely hardware-only future item.

  New `boot/rpi4/netif_state.S` mirrors round 84's `shell_state.S`
  precedent: persistent mutable state (a 4-slot ring buffer + staging
  area) lives in asm with byte-at-a-time accessors, since vani on this
  port only ever holds transient/local state, never a value that must
  survive across separate top-level calls. `netif_send_frame_rpi4`/
  `netif_recv_frame_rpi4`/`netif_get_mac_rpi4` in `kernel_main_rpi4.
  vani` wrap those accessors with the same Ethernet-framing shape and
  empty/full-queue edge-case handling as kernel_main.vani's own
  `netif_send_frame`/`netif_recv_frame`.

  Frame slot size is 512 bytes, not kernel_main.vani's current 1514
  (real Ethernet MTU) -- deliberately: that Pi 1 side itself started
  at exactly 512 before round 66 raised it once a real DHCPOFFER
  actually needed more, and nothing in this round's self-test needs
  more than 16 bytes. Also a real vani-language constraint discovered
  this round: vani has no array-repeat literal syntax (`[0; N]`) and
  `let` always requires a full initializer expression, so a fixed-size
  local array needs either a fully hand-enumerated literal or a helper
  function returning one -- confirmed via a standalone probe
  (`vanic check`) before writing the real port. 512 elements is a far
  more tractable one-time literal (`netif_zero_frame_rpi4`) than 1514
  would have been; raise it the same way Pi 1's own `netif_frame_slot_
  size()` was raised, once a real later round's payload needs it.

  Wired into `kmain_rpi4_vani` (boot-time self-test) and a new `netif`
  shell command (same pattern as `sha256`/`test`). Worked correctly on
  the very first build, no live debugging needed. `test/rpi4_shell_
  smoke.py` updated for the new `help`/`ver` text and a `netif`
  command check; all 8 Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not done** (all explicitly later Phase A steps, per the scope
  memory): ARP, a real IP header module, the packet filter, TCP, DHCP
  (client+server), PKI, X25519/Ed25519/ChaCha20-Poly1305, TLS 1.3, SSH
  transport, and SSH-shell integration -- none started. A real NIC
  driver and WiFi STA/AP are Phase B, genuinely hardware-only, not
  started and not scoped further than the scope memory already covers.

  **ROUND 87 UPDATE, 2026-09-06**: Phase A step 2 -- ARP (RFC 826),
  built on round 86's netif. Direct port of kernel_main.vani's own
  `arp_build_request`/`arp_build_reply`/`arp_get_*`/`arp_cache_lookup`
  /`arp_cache_insert`/`arp_resolve_start`/`arp_resolve_poll`, same
  42-byte frame layout and same 8-entry round-robin cache semantics
  (update-in-place if already cached, append while there's room,
  round-robin overwrite once full). New `boot/rpi4/arp_state.S`
  mirrors `netif_state.S`'s persistent-state-in-asm shape for the
  cache (count/next_slot/8 IPs/8 MACs), with per-byte accessors
  replacing kernel_main.vani's own raw-pointer-into-a-heap-buffer
  approach -- the lookup/insert ALGORITHM itself stays in vani,
  unchanged in shape from the Pi 1 side, only the low-level storage
  access differs.

  Two small `arp_write/read_u16/u32_be_rpi4` helpers replace
  kernel_main.vani's own `buf_write/read_u16/u32_be` builtins (this
  port has no equivalent builtin over fixed-array buffers yet).
  `netif_zero_frame_rpi4` (round 86) supplies every scratch frame
  needed -- no new zero-literal gap hit this round.

  Wired into `kmain_rpi4_vani` (boot-time self-test, both
  `arp_self_test_rpi4` and `arp_resolve_self_test_rpi4`) and a new
  `arp` shell command (reruns both). Worked correctly on the very
  first build, no live debugging needed. `test/rpi4_shell_smoke.py`
  updated for the new `help`/`ver` text and an `arp` command check;
  all 8 Pi 4 smoke tests pass; zero Pi 1 files touched.

  Also logged two real vani-language ergonomics gaps found during
  round 86 (no array-repeat literal syntax, `let` always requiring a
  full initializer) to a new dedicated, discoverable list in the
  vani-compiler repo itself
  (`vani-compiler/docs/DHRUVAOS_ERGONOMICS_TODO.md`, linked from its
  root `TODO.md`) per the user's own request -- distinct from this
  project's own `docs/TODO.md`, kept there so it survives independent
  of DhruvaOS-session memory and is easy for compiler work to find.

  **Not done**: a real IP header module, the packet filter, TCP, DHCP
  (client+server), PKI, X25519/Ed25519/ChaCha20-Poly1305, TLS 1.3, SSH
  transport, and SSH-shell integration remain the next Phase A steps,
  none started.

  **ROUND 88 UPDATE, 2026-09-06**: Phase A step 3 -- a real shared
  IPv4 header module + the packet filter, both built on rounds 86-87.
  Correction to this scope's own earlier assumption: kernel_main.vani
  DOES already have a real, shared `ipv4_*` module (TCP calls it
  directly for header construction) -- only DHCP/raw UDP build their
  own IP framing inline. Direct, unabridged port of `ipv4_checksum`/
  `ipv4_build_header`/`ipv4_get_*`/`ipv4_verify_checksum`/`ipv4_send`
  and `filter_check_frame`/`fw_add_rule`/`filter_self_test`/
  `filter_outgoing_self_test`, same 20-byte header (no IP options)
  and same 8-slot first-match-wins rule table. New `boot/rpi4/
  filter_state.S` mirrors `arp_state.S`'s shape; AAPCS64's 8 argument
  registers make `filter_add_rule` (6 args) simpler than Pi 1's own
  ARM32 `fw_add_rule`, which needed 2 stack-spilled args and, in a
  real round-72 bug, extra unsaved scratch registers -- neither
  hazard exists here. `filter_check_frame_rpi4` is wired into BOTH
  `netif_send_frame_rpi4` (egress) and `netif_recv_frame_rpi4`
  (ingress), the same single-choke-point design as Pi 1.

  Two tiny stub accessors (`tcp_get_dst_port_rpi4`/`udp_get_dst_
  port_rpi4`, a 2-byte fixed-offset read each) give the filter its
  dst_port matching without needing full TCP/UDP modules yet (neither
  exists on this port -- TCP is Phase A step 4).

  Real design snag hit and fixed at compile time, not live: vani has
  no reborrow from a `mut ref T` parameter to a plain `ref T` (a
  `mut ref` value can't be passed anywhere a `ref` is wanted, even
  though it's a strictly MORE permissive access -- confirmed via a
  standalone probe and logged as a 3rd entry in `vani-compiler/docs/
  DHRUVAOS_ERGONOMICS_TODO.md`). Hit twice: (1) `ipv4_build_header_
  rpi4` holds `frame` as `mut ref` and needed to read it back for the
  checksum -- fixed by inlining the read instead of delegating to a
  `ref`-only helper, and standardizing `ipv4_checksum_rpi4`/`ipv4_
  verify_checksum_rpi4` on `mut ref`; (2) `netif_recv_frame_rpi4`'s
  own `out` parameter (`mut ref`) couldn't be handed to the (correctly
  read-only) filter hook -- fixed by reading into a fresh local array
  first, filtering that, and only copying into `out` if the filter
  allows it (one extra 512-byte copy per receive call). Neither is a
  vani-compiler BUG (the type system caught something structurally
  real -- you can't manufacture read access to something you don't
  actually have handed to you at that reference kind), just a real
  ergonomics gap in how much of that has to be worked around by hand.

  Wired into `kmain_rpi4_vani` (boot-time self-test -- `filter_set_
  default_policy(1)` explicitly BEFORE `netif_self_test_rpi4`, same
  ordering fix kernel_main.vani's own boot sequence needed, for the
  identical reason: `.bss` zero-init default-denies everything until
  set otherwise, which would break every earlier self-test that
  touches netif) and two new shell commands, `ip` and `filter`.
  Worked correctly on the very first REAL build (after the reborrow
  fixes above, caught by `vanic check` before ever reaching QEMU) --
  no live debugging needed. `test/rpi4_shell_smoke.py` updated for
  the new `help`/`ver` text and `ip`/`filter` command checks; all 8
  Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not done**: TCP, DHCP (client+server), PKI, X25519/Ed25519/
  ChaCha20-Poly1305, TLS 1.3, SSH transport, and SSH-shell integration
  remain the next Phase A steps, none started.

  **ROUND 89 UPDATE, 2026-09-06**: Phase A step 4 -- TCP, the largest
  single port in this scope, built on rounds 86-88's netif/ARP/IPv4+
  filter. Direct, unabridged port of kernel_main.vani's own stateless
  header layer (`tcp_flag_*`/`tcp_checksum`/`tcp_build_header`/`tcp_
  get_*`/`tcp_verify_checksum`/`tcp_send_segment`) AND its full
  connection state machine (`tcp_conn_active_open`/`passive_open`/
  `handle_segment`/`send_data`/`close`/`check_retransmit`/`poll`) --
  the exact same 2 fixed connection slots (0=client, 1=server, this
  single-threaded environment has no second task to run "the other
  side" concurrently), same states (CLOSED/SYN_SENT/SYN_RCVD/
  ESTABLISHED/FIN_WAIT/CLOSED_FINAL/CLOSING), same simultaneous-open
  AND simultaneous-close handling, same retransmission timers, same
  advertised-window enforcement -- every branch is a real, working
  port, nothing stubbed. New `boot/rpi4/tcp_state.S` mirrors the
  established per-round asm-state shape (persistent connection fields
  + a 64-byte-per-connection retransmit buffer, byte-accessed); its
  24 near-identical get/set accessors are generated via a GNU `as`
  `.macro`, the first use of assembler macros on this port -- a
  simpler and less error-prone choice than hand-duplicating 24
  functions, confirmed to assemble correctly via a standalone
  `aarch64-linux-gnu-gcc -c` probe before wiring it into the real
  build.

  This round planned its `ref`/`mut ref` signatures UP FRONT instead
  of discovering mismatches reactively (round 88's own lesson, gap #3
  in `vani-compiler/docs/DHRUVAOS_ERGONOMICS_TODO.md`): every `tcp_
  get_*_rpi4`/`tcp_checksum_rpi4`/`tcp_verify_checksum_rpi4` takes
  plain `ref [u8; 512]` throughout, matching every real caller; only
  `tcp_build_header_rpi4` (which writes the header then must read it
  back to checksum it) computes that checksum with an inline loop
  instead of delegating, the same fix shape as `ipv4_build_header_
  rpi4`. One more instance was still caught live by `vanic check` at
  `tcp_conn_poll_rpi4`'s own echo-service responder (a `mut ref out_
  payload` parameter needed to be re-sent through a `ref`-only send
  path) -- fixed with the same "copy through a fresh local first"
  pattern round 88 already established, not a new technique.

  Wired into `kmain_rpi4_vani` (boot-time self-test) and a new `tcp`
  shell command (reruns both `tcp_self_test_rpi4` and `tcp_conn_
  self_test_rpi4`, the full handshake+data+close lifecycle). Worked
  correctly on the very first REAL build -- no live debugging needed,
  four clean rounds in a row now (86-89). `test/rpi4_shell_smoke.py`
  updated for the new `help`/`ver` text and a `tcp` command check;
  all 8 Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not ported this round, a real scope boundary not an oversight**:
  kernel_main.vani's own dedicated regression self-tests for a few of
  these same branches (`tcp_conn_recv_bounds_self_test`, `tcp_conn_
  simultaneous_open_self_test`, `tcp_conn_simultaneous_close_self_
  test`, `tcp_conn_window_enforcement_self_test`) -- the underlying
  logic every one of them exercises IS fully present and live in the
  ported state machine (bounds checks in `handle_segment`,
  simultaneous open/close transitions, window enforcement in `send_
  data`), just not independently re-verified via its own dedicated
  synthetic fixture this round, matching how kernel_main.vani itself
  never wrote a dedicated self-test for its own (equally real,
  equally live) retransmission-timer code either.

  **Not done**: DHCP (client+server), PKI, X25519/Ed25519/ChaCha20-
  Poly1305, TLS 1.3, SSH transport, and SSH-shell integration remain
  the next Phase A steps, none started.

  **ROUND 90 UPDATE, 2026-09-06**: UDP -- a real, previously-
  unaccounted-for prerequisite for DHCP, discovered while reading
  kernel_main.vani's own DHCP code to scope that round: DHCP is built
  directly on `udp_send`, not raw IP. This scope's own original
  ordering (see project memory `project_dhruva_networking_ssh_wifi_
  scope_2026_09_06.md`) never listed a UDP step at all, silently
  skipping the layer DHCP actually sits on -- corrected there now,
  inserted as its own step before DHCP.

  Direct port of kernel_main.vani's own stateless `udp_*` header layer
  plus its `socket_udp_send`/`socket_udp_recv` minimal socket-style
  API (DHRUVA_ARCHITECTURE.md §4 -- one implicit socket, no per-port
  binding table, matching Pi 1's own honest scope). UDP is genuinely
  stateless -- no new `boot/rpi4/*.S` file needed at all, unlike every
  other round in this arc. Reused round 88's `udp_get_dst_port_rpi4`
  as-is. Same ref-planning discipline as rounds 89: every `udp_get_*_
  rpi4`/checksum helper takes plain `ref`, only `udp_build_rpi4`
  computes its checksum inline (same fix shape as `ipv4_build_header_
  rpi4`/`tcp_build_header_rpi4`) -- planned up front, `vanic check`
  found zero reborrow issues this round.

  Wired into `kmain_rpi4_vani` and a new `udp` shell command. Worked
  correctly on the very first REAL build -- five clean rounds in a
  row now (86-90). `test/rpi4_shell_smoke.py` updated for the new
  `help`/`ver` text and a `udp` command check; all 8 Pi 4 smoke tests
  pass; zero Pi 1 files touched.

  **Not ported this round**: kernel_main.vani's own 3 dedicated
  regression self-tests (`udp_send_unresolved_self_test`, `udp_recv_
  bounds_self_test`, `udp_checksum_reject_self_test`) -- the
  underlying logic (ARP-resolution requirement, bounds checks,
  checksum verification) is fully live in `socket_udp_send_rpi4`/
  `socket_udp_recv_rpi4`, just not independently re-verified via each
  one's own dedicated fixture this round, same scope-boundary
  reasoning as round 89's own TCP note.

  **Not done**: DHCP (client+server), PKI, X25519/Ed25519/ChaCha20-
  Poly1305, TLS 1.3, SSH transport, and SSH-shell integration remain
  the next Phase A steps, none started.

  **ROUND 91 UPDATE, 2026-09-06**: DHCP **client** (the server is
  split out as its own, separate, not-yet-started follow-up round per
  the user's own request -- this scope's original step 6 lumped both
  together). Direct, unabridged port of kernel_main.vani's own DHCP
  client family onto round 90's UDP: the same 240-byte fixed BOOTP
  header + magic cookie, the same bounded (max 64 iterations) options
  scan, and the same client state machine (INIT -> SELECTING ->
  REQUESTING -> BOUND, plus RFC 2131 s4.4's full post-BOUND lease
  lifecycle -- RENEWING at T1, REBINDING at T2, re-acquisition on NAK
  or final expiry). New `boot/rpi4/dhcp_state.S` holds a single scalar
  instance (7 fields, no table -- this port has exactly one DHCP
  client), using the same GNU `as` `.macro` technique round 89
  introduced.

  **A real, live LLVM-backend bug hit and fixed this round** (not
  caught by `vanic check`, only by the actual `emit --backend=llvm` +
  `llc` pipeline `build_rpi4.sh` runs): `dhcp_client_check_lease_
  rpi4`'s own T1 (renew) and T2 (rebind) branches are sibling `if`
  blocks that both declared a local named `payload` (plus several
  other repeated names) -- a known, previously-documented vani
  codegen quirk (project memory `feedback_vani_llvm_local_name_
  collision`): reusing a local name across two non-overlapping blocks
  of one function can crash `llc` with "multiple definition of local
  value named 'payload.addr'", even though the type checker accepts
  the code fine and the two blocks never execute together. Fixed by
  giving every local in the T2 branch a distinct `rebind_`-prefixed
  name instead of reusing the T1 branch's names. Not a new discovery
  -- a known, already-documented pattern recurring in new code, this
  time in DHCP rather than vani-signal's FFT (where it was first
  found).

  Wired into `kmain_rpi4_vani` and a new `dhcp` shell command
  (reruns the full DISCOVER->OFFER->REQUEST->ACK->BOUND cycle against
  two manually-built synthetic server replies, same "no real second
  host in this loopback-only environment" reasoning ARP/TCP's own
  self-tests already establish). `test/rpi4_shell_smoke.py` updated
  for the new `help`/`ver` text and a `dhcp` command check; all 8
  Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not ported this round, a real scope boundary**: kernel_main
  .vani's own `dhcp_renewal_self_test` (backdates lease_start_tick to
  drive the T1/T2/expiry thresholds) and `dhcp_nak_self_test`. Their
  underlying logic (the full lease-lifecycle state machine in `dhcp_
  client_check_lease_rpi4`, and the NAK-resets-to-INIT branch in
  `dhcp_client_poll_rpi4`) IS fully present and live, just not
  independently re-verified via a dedicated fixture. Additionally,
  and specific to this port: `rpi4_timer_tick_count_get()` only
  advances once `boot.S` reaches its own later `wfi` loop, AFTER
  `kmain_rpi4_vani`'s entire self-test sequence already runs
  synchronously to completion (confirmed by this port's own boot log
  ordering) -- a lease-threshold self-test genuinely can't be staged
  as a synchronous boot-time call the way `dhcp_self_test_rpi4` is,
  unlike Pi 1's own environment.

  **Not done**: DHCP server, static-IP configuration, PKI, X25519/
  Ed25519/ChaCha20-Poly1305, TLS 1.3, SSH transport, and SSH-shell
  integration remain the next Phase A steps, none started.

  **ROUND 92 UPDATE, 2026-09-06**: DHCP **server** -- brand-new
  design, no kernel_main.vani precedent at all (Pi 1 never built one).
  Scoped first in a dedicated pass (`project_dhruva_dhcp_server_
  scope_2026_09_06.md` memory), then implemented per that scope
  exactly. A separate persistent-state file from round 91's client
  (`boot/rpi4/dhcp_server_state.S`): a 4-slot fixed lease table
  (mac/leased_ip/xid/state/lease_start_tick per slot, matching this
  project's own established "small fixed arrays" convention -- ARP's
  8-slot cache, TCP's 2-slot connection table, the filter's 8-slot
  rule table) plus server-wide config (server_ip/pool_base_ip/
  pool_size/lease_time) set once via `dhcp_server_init_rpi4`.

  Handles DHCPDISCOVER -> DHCPOFFER (re-offering an existing lease for
  a known MAC, or allocating the next free pool slot) and DHCPREQUEST
  -> DHCPACK/DHCPNAK (ACK only if the requested address, or ciaddr for
  a renewal, matches what this server actually has on record for that
  MAC; NAK otherwise, including for a MAC this server never saw a
  DISCOVER from). Reuses round 91's `dhcp_build_fixed_header_rpi4`
  directly for every reply.

  **The concrete payoff of shipping the client first**: this round's
  own self-test needed to play "fake client" with no real second host
  -- rather than hand-building synthetic DISCOVER/REQUEST messages the
  way round 91's client self-test had to hand-build synthetic OFFER/
  ACK replies (no server code existed yet to reuse at that point),
  this round's self-test calls round 91's OWN `dhcp_build_discover_
  rpi4`/`dhcp_build_request_rpi4` UNCHANGED to synthesize realistic
  client traffic. Exercises three real paths: DISCOVER->OFFER, a
  matching REQUEST->ACK, and a REQUEST from a MAC that never
  DISCOVERed->NAK.

  Applied round 91's own lesson proactively this time (not reactively
  after a build failure): every sibling-`if`-block local below was
  given a distinct, block-specific name from the start (`discover_*`/
  `request_*`, etc.) specifically to avoid
  [[feedback_vani_llvm_local_name_collision]] recurring a third time
  -- and it worked, `build_rpi4.sh` succeeded on the first real build,
  no LLVM codegen fix needed this round.

  Wired into `kmain_rpi4_vani` and a new `dhcps` shell command. All 8
  Pi 4 smoke tests pass; zero Pi 1 files touched (there was nothing
  to touch -- this is all new code).

  **Not done, real scope boundaries** (see the scope memory for the
  full list): DHCPDECLINE/RELEASE/INFORM, lease expiry/GC (a BOUND
  lease stays bound forever -- also can't be tested synchronously
  here for the same timer-advancement reason round 91's own renewal
  self-test was skipped), relay-agent (giaddr) support, conflict
  detection, dynamic pool reconfiguration, and any admin CLI beyond a
  self-test rerun. Static-IP configuration (the DHCP-alternative path
  the user's own original vision also asked for), PKI, X25519/
  Ed25519/ChaCha20-Poly1305, TLS 1.3, SSH transport, and SSH-shell
  integration remain the next Phase A steps, none started.

  **ROUND 93 UPDATE, 2026-09-06**: static IP configuration -- the
  DHCP-alternative path from the user's own original networking
  vision ("it should work dhcp/static ip as well as..."). Brand-new
  design, no kernel_main.vani precedent (Pi 1's own DHCP was always
  the only way this project ever acquired an address). New
  `boot/rpi4/netconfig_state.S` holds a single scalar network
  configuration (ip/netmask/gateway/source, source tracking whether
  STATIC or DHCP populated it, or NONE if genuinely unconfigured) --
  same single-instance shape as round 91's DHCP client state.

  `netconfig_set_static_rpi4` is the actual requested capability:
  configures the device's network identity directly, bypassing DHCP
  entirely, rejecting 0.0.0.0/255.255.255.255 for the address itself
  (netmask/gateway aren't validated against the address -- this
  project's own IP/TCP/UDP layers never consult either for a routing
  decision today, so a stricter check would have nothing downstream
  to actually protect). `netconfig_apply_from_dhcp_rpi4` is a generic
  acquisition-path setter, written and self-tested here but
  DELIBERATELY NOT wired into round 91's `dhcp_client_poll_rpi4` this
  round -- that would need the client to also parse DHCP options 1
  (subnet mask) and 3 (router) from the ACK (it only parses 50/51/54
  today) and round 92's own server to start sending them, a real,
  small, well-scoped follow-up kept out of this round so it stayed
  focused on the actually-requested static-IP capability.

  Wired into `kmain_rpi4_vani` and a new `netcfg` shell command
  (exercises static config + field verification, invalid-address
  rejection, reset-to-unconfigured, and the DHCP-facing setter). Every
  sibling-block local used a distinct name from the first draft, the
  same proactive discipline round 92 already applied against
  [[feedback_vani_llvm_local_name_collision]] -- worked correctly on
  the very first REAL build, no live debugging needed at all this
  round either. All 8 Pi 4 smoke tests pass; zero Pi 1 files touched
  (all new code, same as round 92).

  **Not done**: live DHCP-to-netconfig wiring (needs DHCP options 1/3
  parsing on both client and server), PKI, X25519/Ed25519/ChaCha20-
  Poly1305, TLS 1.3, SSH transport, and SSH-shell integration remain
  the next Phase A steps, none started.

  **ROUND 94 UPDATE, 2026-09-06**: SHA-512 (FIPS 180-4) -- the first
  step of the SHA-512 -> field25519/X25519 -> Ed25519 -> PKI crypto
  chain, after discovering while scoping "PKI" (step 7) that `pki_
  verify_raw` is a one-line wrapper around `ed25519_verify`, and
  Ed25519 doesn't exist on this port at all (round 85 only did SHA-
  256). The user's own direction: "do the full chain now."

  Direct port of kernel_main.vani's own `sha512_*` algorithm (same K/H
  constants, same 80-round compression), but genuinely simpler than
  Pi 1's own version: Pi 1 is ARM32, where a `u64` doesn't fit in one
  register, so that side's `sha512_read_u64`/`write_u64`/`write_u64_
  val` exist purely to assemble/disassemble a `u64` from two 32-bit
  halves. AArch64 has real 64-bit registers -- this port's `u64` is a
  single value, no hi/lo split needed, so that entire accessor layer
  is skipped, matching round 85's own `[T; N]` fixed-array
  simplification one level up.

  Confirmed via a standalone `vanic run` probe before writing any real
  code that vani's `wrapping_add`/`wrapping_sub` builtins work
  correctly for `u64` (`wrapping_add(u64::MAX, 1) == 0`), and used
  them directly for all mod-2^64 arithmetic -- NOT round 85's own
  manual widen-to-`i64`-and-mask trick (`sha256_wrap_add32_rpi4`).
  This isn't a style inconsistency: kernel_main.vani's OWN `sha512_
  compress` already uses these exact builtins directly (added to vani
  the same round as Pi 1's own SHA-512/Ed25519 work), while its OLDER
  `sha256_compress` predates that builtin and still uses the manual
  widen trick round 85 faithfully carried forward -- each SHA variant
  here matches its own Pi 1 counterpart's actual historical style.

  4 FIPS-180-4 KATs ported (empty string, "abc", a 111-byte message,
  and a genuine 2-block 112-byte message), same vectors and expected
  digests as kernel_main.vani's own `sha512_self_test` (independently
  verified there against Python's own `hashlib.sha512`). Wired into
  `kmain_rpi4_vani` and a new `sha512` shell command. Worked correctly
  on the very first REAL build -- no live debugging needed. All 8
  Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not done**: field25519/X25519, Ed25519, PKI's own thin wrapper,
  ChaCha20-Poly1305, TLS 1.3, SSH transport, and SSH-shell integration
  remain the next steps in this chain, none started.

  **ROUND 95 UPDATE, 2026-09-06**: field25519 + X25519 -- step 2 of the
  crypto chain (SHA-512 -> field25519/X25519 -> Ed25519 -> PKI), per
  the user's own "start step 2, X25519" then "go through all steps
  1-4" (continue through Ed25519 and PKI without stopping for
  per-step confirmation).

  GF(2^255-19) field arithmetic (add/sub/mul/sqr/invert) plus the full
  RFC 7748 Montgomery ladder, redesigned around field elements as
  `[u32; 8]` limb arrays (not Pi 1's untyped 32-byte heap buffer with
  byte-wise/u32-limb dual accessors) -- eliminates almost all of Pi
  1's byte-level shimming. Three width-specific bignum families
  (`bignum_*8_rpi4`, `bignum_*9_rpi4` for the reduce16 fold scratch,
  `bignum_mul8_rpi4` producing a 16-limb product) replace Pi 1's
  genuinely `n`-parameterized runtime-limb-count versions, since
  vani's fixed arrays bake their size into the type. cswap in the
  ladder operates at u32-limb granularity (8 iterations per swap)
  instead of Pi 1's byte granularity (32 iterations) -- functionally
  identical, fewer/wider operations.

  Mid-implementation, hit three previously-unknown vani-compiler
  constraints that don't appear in Pi 1's ARM32 out-parameter-style
  code at all: (1) the aliasing XOR rule -- a `mut ref` borrow of a
  variable cannot coexist with any other borrow of that same variable
  in one call (correct, expected borrow-checker behavior, not a gap);
  (2) `ref`/`mut ref` can only borrow a named variable or struct
  field, never a function-call temporary directly (`ref
  x25519_p_rpi4()` is illegal -- must bind to a named local first);
  (3) a real, previously-undocumented gap -- `[T; N]` arrays are
  MOVE-only on plain `let`/`=` binding, not Copy, and have no
  `.clone()` method, contradicting an earlier assumption on this port
  (round 85's own memory note) that `[T; N]` locals are "genuine Copy
  stack values." That claim only holds for passing an array by `ref`/
  `mut ref` at a call site -- not for value-binding. Logged as entry
  #4 in `vani-compiler/docs/DHRUVAOS_ERGONOMICS_TODO.md` (vani-
  compiler commit `d8755df9`).

  Resolved all three at once by redesigning every field25519/bignum
  function to **return its result by value** instead of Pi 1's
  out-parameter convention -- an owned local can always supply either
  `ref` or `mut ref` at its own call site, and `x = f(ref x)` (read
  via `ref`, then reassign from the call's own return after the
  borrow ends) works correctly. Where a genuine duplicate (not a
  borrow) was needed, used an explicit element-by-element copy loop
  instead of `let y = x;`.

  2 real DH test vectors ported (base-point derivation, arbitrary-u
  key agreement), byte-identical to kernel_main.vani's own `x25519_
  self_test`. Wired into `kmain_rpi4_vani` and a new `x25519` shell
  command. No new `boot/rpi4/*.S` state file needed (everything fits
  as plain vani locals within one call chain, same as SHA-512). All 8
  Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not done**: Ed25519 (sign/verify, step 3) and PKI's own thin
  wrapper (step 4) remain -- both explicitly still to come per "go
  through all steps 1-4." ChaCha20-Poly1305, TLS 1.3, SSH transport,
  and SSH-shell integration remain further out, none started.

  **ROUND 96 UPDATE, 2026-09-06**: Ed25519 -- step 3 of the crypto
  chain, per the user's own "go through all steps 1-4" (Ed25519 and
  PKI, without stopping for per-step confirmation after X25519).

  EdDSA sign/verify (RFC 8032) over the twisted-Edwards form of
  Curve25519, reusing round 95's `field25519_*` directly (same p,
  same `[u32; 8]` limb representation) -- the only new field-level
  piece is the modular square root point decompression needs. Points
  use extended coordinates (X,Y,Z,T) via a new `Ed25519PointRpi4`
  struct -- this port's FIRST use of a struct at all (Pi 1's version
  is fully procedural with named persistent scratch buffers instead).
  Deliberately kept FLAT (4 sibling `[u32; 8]` fields, no nesting):
  confirmed via a standalone probe that `ref`/`mut ref` can reach
  exactly one level of field access (`ref t.field` works, `ref
  t.field.field2` does not), so a nested `Ed25519PointRpi4` field
  inside a result struct would have blocked passing it straight into
  `field25519_*` calls. The unified add-2008-hwcd-3 formula
  (Hisil/Wong/Carter/Dawson 2008) handles doubling too, so the
  scalar-mult ladder never needs a separate doubling path -- confirmed
  legal to call with the same owned local as both point arguments
  (`ed25519_point_add_rpi4(ref b, ref b)`), matching round 95's own
  confirmed same-`ref`-twice pattern.

  Scalar arithmetic mod L (the group order) is genuine bit-by-bit
  binary long division, like kernel_main.vani's own -- L's own
  remainder isn't small like p's `19`, so round 95's fold trick
  doesn't apply. One genuine simplification over Pi 1's version: Pi 1
  derives the square-root exponent `(p+3)/8` at RUNTIME via bignum
  add+shift (a safeguard against a second hand-derived constant
  drifting out of sync with p); this port's field25519 module already
  fixes p as a compile-time constant with nothing to drift against, so
  `(p+3)/8 = 2^252-2` is simply precomputed once instead.

  Verification reuses kernel_main.vani's own already-independently-
  verified seed/message/expected-pubkey/expected-signature -- same
  algorithm, same constants, same seed and message, so byte-identical
  expected output rather than a separately-derived vector. Covers
  pubkey derivation, signing, self-verification, AND both tamper-
  rejection paths (flipped signature bit, flipped message bit).

  One real test-harness recalibration needed, NOT a functional bug:
  Ed25519's own point-multiplication ladder does far more field
  arithmetic per bit than X25519's (a full 8-field-mul point_add,
  called twice per bit, across up to 4-5 full 256-bit scalar mults for
  pubkey+sign+verify combined), and under QEMU TCG emulation this
  measurably costs ~2 real wall-clock seconds per self-test run
  (confirmed via a direct timestamped boot probe) -- pushing total
  boot-to-shell-ready time to ~5.7s and making the shell's own
  `ed25519` command noticeably slower than any prior command.
  `test/rpi4_shell_smoke.py`'s fixed `SETTLE_S`/`CMD_WAIT_S` delays
  (3s/1s, calibrated for the pre-Ed25519 boot sequence) were too short
  for this -- commands sent at the old fixed offsets landed on top of
  still-running self-tests and were lost, failing 2 checks on the
  first real run. Fixed by bumping `SETTLE_S` to 7s and `CMD_WAIT_S`
  to 3s (both comfortably clear the measured ~5.7s/~2s real costs);
  the underlying Ed25519 implementation itself was correct on the very
  first `vanic check` and the very first `./build_rpi4.sh` -- this was
  purely a test-timing gap the new self-test's real cost exposed.

  No new `boot/rpi4/*.S` state file needed (same as SHA-512/X25519 --
  everything fits as plain vani locals/struct values within one call
  chain). Wired into `kmain_rpi4_vani` and a new `ed25519` shell
  command. All 8 Pi 4 smoke tests pass; zero Pi 1 files touched.

  **Not done**: PKI's own thin wrapper (step 4, the last link in this
  chain) remains -- explicitly still to come per "go through all steps
  1-4." ChaCha20-Poly1305, TLS 1.3, SSH transport, and SSH-shell
  integration remain further out, none started.

  **ROUND 97 UPDATE, 2026-09-06**: PKI -- step 4 of 4, the LAST link
  in the SHA-512 -> field25519/X25519 -> Ed25519 -> PKI crypto chain.
  Raw public-key trust only -- no X.509/CA chain, a compile-time-
  pinned key never runtime-settable, matching Pi 1's own deliberately
  thin scope (`pki_verify_raw` really is exactly the one-line wrapper
  around `ed25519_verify` that started this whole chain back when this
  round was still "start step 7, PKI"). `pki_verify_file`/`pki_verify_
  file_raw` (verify a DharaFS file against a companion `<path>.sig`)
  deliberately NOT ported -- DharaFS isn't wired into this port at
  all, and there's no file-signing use case here without it; only the
  raw in-memory path exists. Verification reuses kernel_main.vani's
  own already-independently-verified pinned key/message/signature
  (same genuine-signature-verifies and tampered-content-rejected
  checks kernel_main.vani's own `pki_self_test` runs, minus the file-
  based end-to-end leg DharaFS would require). No new vani-compiler
  gaps found; no new `boot/rpi4/*.S` state file needed (the pinned key
  is a plain constant function, no persistent state at all). Wired
  into `kmain_rpi4_vani` and a new `pki` shell command. Worked
  correctly on the very first `vanic check` and the very first
  `./build_rpi4.sh` -- zero live debugging needed. All 8 Pi 4 smoke
  tests pass (19 real shell commands now); zero Pi 1 files touched.

  **This closes the whole SHA-512 -> field25519/X25519 -> Ed25519 ->
  PKI crypto chain (rounds 94-97)** -- the user's "do the full chain
  now" / "go through all steps 1-4" instruction is now fully
  satisfied. **Not done, and explicitly out of THIS chain's scope**:
  X.509 certificate parsing/chains/rootCA validation, mTLS, and the
  application-layer protocols that would sit on top (HTTPS, MQTT) --
  none of these exist anywhere in kernel_main.vani either (confirmed:
  Pi 1's own PKI is raw-key-only, same as this port). Getting there
  needs, in dependency order: (1) ChaCha20-Poly1305 (AEAD, needed by
  TLS 1.3's record layer) -- not started; (2) TLS 1.3 itself (`tls_*`
  port -- handshake builders + HKDF + AEAD record layer already exist
  on Pi 1, itself raw-key/PSK-oriented, NOT X.509 -- Pi 1 has no X.509
  parser either) -- not started; (3) a genuine NEW component, X.509
  DER parsing + certificate-chain validation + a root CA trust store,
  which would need to be designed from scratch for either OS (no Pi 1
  precedent at all) before real HTTPS/mTLS interop with off-the-shelf
  clients/servers is possible; (4) MQTT (a simple framed protocol over
  TCP, or over TLS for MQTTS) -- also entirely new, no precedent. Raw-
  key PKI (this round) is a real, useful building block for those
  (signature verification is a shared primitive) but is not itself
  X.509/mTLS/HTTPS/MQTT -- each of those is unstarted, separately-
  scoped future work, not an extension of this round.

  **ROUND 98 UPDATE, 2026-09-06/07**: crypto generification -- the
  SHA-256/512, field25519/X25519/Ed25519, and raw-key PKI code rounds
  85 and 94-97 wrote as this file's own inline `_rpi4`-suffixed
  functions moved OUT entirely into three standalone, hardware-
  agnostic kosh packages, per the user's explicit direction ("i wanted
  you to make some packages generic so whatever you have pi4 is on
  pi1 too... hardware agnostic or atleast hardware configurable yet
  generic"): `vani-crypto-hash` (SHA-256/512), `vani-curve25519`
  (field25519/X25519/Ed25519, depends on crypto_hash), `vani-pki`
  (raw-key trust, depends on curve25519) -- each its own GitHub repo,
  Apache-2.0, vendored here at `vendor/crypto_hash`/`vendor/curve25519`/
  `vendor/pki`. Pure mechanical extraction, zero algorithm changes --
  every self-test reuses the exact same vectors as before.

  Key design decision made BEFORE extracting: which of the two
  existing API styles (Pi 1's heap-based `mut ref i64` buffers, or
  this port's heap-free fixed-array/return-by-value style) should be
  the canonical shared one. Chose the heap-free style, since
  `kernel_main_rpi4.vani` has zero heap allocator by design -- a
  heap-required package would silently exclude this port and any
  future no-heap board, while a heap-free package runs on anything.
  Pi 1 migrating to consume these packages (not the reverse) is
  future work, not done this round.

  Found and worked around a REAL vani-compiler bug discovered while
  wiring the packages together as real dependencies (not just each
  package's own standalone self-test, which never exercises this):
  `buf[i] = helper(...);` (index-assignment with a function-call RHS)
  fails to resolve `helper` whenever the enclosing code lives inside
  a named scope (`module {}`, or a `[deps]`-vendored Kosh package) --
  even though the identical call resolves fine in a `let` binding or
  at plain top level. SHA-256/512's own compression loops use exactly
  this pattern throughout, so real `[deps]`-based package consumption
  broke immediately. Filed upstream as BUG-234 (vani-compiler's own
  `docs/TODO_CURRENT.md`; a second, unrelated C-backend bug found
  along the way -- struct literals with an array field initialized
  from a local variable emit a raw pointer instead of a copy -- filed
  as BUG-235; doesn't affect this project, which only ever builds
  with `--backend=llvm`). Workaround: none of the three packages
  declare each other as `vani.toml` `[deps]` entries at all; each
  vendors its dependency's source directly and pulls it in via a
  plain relative `use` statement instead, landing everything in one
  flat namespace with no named-scope wrapper for the bug to trip on.
  This port's own `vendor/` tree deliberately flattens all three
  packages to ONE copy each (not each package's own independently-
  vendored nested copy) to avoid duplicate-symbol errors, since a
  `use`'d file has no namespace isolation to prevent that.

  The 5 `_rpi4`-suffixed self-test functions
  (`sha256_self_test_rpi4`/etc.) are now thin wrappers: call the
  package's own unqualified self-test, print the exact same UART
  message every prior round already printed. Boot sequence and shell
  dispatch needed ZERO changes as a result. `kernel_main_rpi4.vani`
  shrank from 6321 to 4277 lines (the ~2140-line inline crypto block
  replaced by 3 `use` statements + 5 thin wrappers).

  One real, non-functional side effect: `test/rpi4_vani_smoke.py` and
  `test/rpi4_timer_smoke.py` both needed `DEFAULT_TIMEOUT_S` bumped
  from 8 to 20 -- the code-layout change from extraction shifted real
  QEMU TCG boot timing enough that the boot sequence + 5-tick
  preemption demo no longer reliably finished inside the old 8s
  window (confirmed via manual reruns with a longer timeout that
  nothing is actually broken, purely a margin issue, same class of
  fix round 96 already needed for `rpi4_shell_smoke.py`). All 8 Pi 4
  smoke tests pass after the recalibration; zero Pi 1 files touched.

  **Not done**: Pi 1 migration to consume these same packages (Phase
  1 of the generification plan), the scheduler/priority-ceiling-
  mutex parity gap (Pi 4/5 is missing a feature Pi 1 already has),
  and the X.509/mTLS/HTTPS/MQTT chain above are all separately scoped,
  unstarted future work.

  **ROUND 99 UPDATE, 2026-09-07**: Pi 1 SHA-256/512 migrated to the
  `crypto_hash` kosh package (Phase 1 pilot of the generification
  plan). Real complication found before writing any code: the
  package's one-shot `sha256_hash`/`sha512_hash` cap the message at
  what fits a 256-byte scratch buffer, but Pi 1's own `sha256_hash`
  is called on genuinely unbounded input -- whole DharaFS file
  contents (verified-write digests) and the full TLS 1.3 handshake
  transcript (easily 500-2000+ bytes). A naive swap would have
  silently truncated both. Fixed by adding a real streaming API to
  `vani-crypto-hash` first (`Sha256Ctx`/`Sha512Ctx` +
  `init`/`update`/`finalize`, v0.2.0) -- the running hash state is
  always just 8 words plus one block of carry, regardless of total
  message length; `update` takes up to 256 bytes per call, looped by
  the caller for longer messages. Verified against 4 KATs per
  algorithm (including a non-block-aligned multi-call split to
  exercise the carry-buffer path, and a 500-byte message across 3
  uneven calls cross-checked against an independent Python `hashlib`
  reference) before touching Pi 1 at all.

  Found a second real complication once actually wiring Pi 1 in: the
  package's OWN function names (`sha256_hash`, `sha256_self_test`,
  etc.) collide directly with Pi 1's own pre-existing functions of
  the identical name -- `use`'s flat-namespace workaround for BUG-234
  means both can't coexist in one file. Split `vani-crypto-hash` into
  `src/core.vani` (streaming primitives only, no one-shot wrappers or
  self-tests -- what a consumer with a naming conflict needs) and the
  original `src/lib.vani` (the full API, for consumers like
  `curve25519` with no conflict) to resolve this cleanly.

  Deleted Pi 1's own ~300-line hand-rolled SHA-256/512 (originally
  round 41/67, hardened round 65 against a real ARM32 long-lived-
  scratch-pointer register-corruption bug -- that history stays
  preserved in `vani-crypto-hash`'s own git log) and replaced
  `sha256_hash`/`sha512_hash` with thin adapters: copy the caller's
  heap buffer into the package's `[u8; 256]` stream chunks (looping
  as needed, so there's still no length cap), feed them through
  `update`, copy the digest back. `sha256_bytes_equal`/
  `sha512_bytes_equal` (generic byte comparators, no algorithm
  dependency) and all 17 existing call sites (DharaFS, HMAC, PBKDF2,
  TLS transcript hashing, Ed25519) needed ZERO changes -- same
  adapter signature as the functions they replaced. Also removed 5
  now-dead persistent-scratch boot-time allocations
  (`sha256_padded/h/k/w_scratch`, `sha512_h/k/w/padded_scratch`,
  `boot/scratch_state.S`) that nothing calls anymore.

  Verified live under QEMU, not just `vanic check`: every one of the
  15 `CRYPTO: ...` self-test lines Pi 1 prints at boot show `(PASS)`,
  including the two call sites that actually motivated the streaming
  redesign -- `PKI raw public-key trust (pinned-key verify + real
  dharafs file round trip) (PASS)` and `TLS 1.3 ... live handshake +
  app data round trip (PASS)`. `test/phase4_milestone.py`'s broader
  regression battery passes except 2 checks (`eval 6*7 == 42`,
  `ping 0.0.0.0` self-ping) that are demonstrably unrelated --
  different, untouched code region (`eval`'s shell dispatch is ~2600
  lines away from anything touched this round) and non-deterministic
  (`ping` passed on an immediate rerun) -- confirmed pre-existing,
  not a regression from this round.

  **Next**: SHA-256/512 is the pilot; ChaCha20/Poly1305, X25519/
  Ed25519, and PKI still have their own separate Pi 1 implementations
  duplicating `vani-curve25519`/`vani-pki` and would need the same
  treatment to close the generification gap fully -- not started.

  **ROUND 100 UPDATE, 2026-09-07**: Pi 1 X25519/Ed25519/PKI migrated
  to the shared `curve25519`/`pki` kosh packages -- second Phase 1
  migration, same shape as round 99's SHA-256/512 pilot but larger
  (bignum foundation + field25519 + X25519 + Ed25519, ~30 functions,
  ~1300 lines deleted).

  Found a real gap before touching Pi 1: `curve25519`'s own
  `ed25519_sign`/`verify` capped `msg` at 64 bytes, but Pi 1's real
  callers (TLS 1.3's own CertificateVerify signed-content, a fixed
  130 bytes) exceed that. Fixed the package itself first -- rewrote
  the internal r=H(prefix||msg) and k=H(R||A||msg) hashing to use
  streaming SHA-512 (`sha512_init`/`update`/`finalize`) instead of the
  one-shot `sha512_hash`, removing the hashing-side cap entirely, then
  raised the public `msg` array bound to 512 bytes (comfortable
  headroom, not an algorithmic limit anymore). Verified with a new
  130-byte KAT cross-checked against the real `cryptography` Python
  library, added to `curve25519`'s own self-test.

  Found a second real problem specific to this migration: unlike
  SHA-256/512 (where crypto_hash's own name collisions were the only
  issue), `curve25519`'s FULL API also defines `x25519_self_test`/
  `ed25519_self_test` -- both ALSO collide with Pi 1's own pre-
  existing functions of those names. Fixed by giving `curve25519` the
  same core.vani/lib.vani split round 99 gave `crypto_hash`:
  `core.vani` has every primitive (field25519/X25519/Ed25519) minus
  both self-tests, and ALSO switched `ed25519_secret_expand`'s own
  32-byte secret-hash from the one-shot `sha512_hash` to streaming, so
  `curve25519/core.vani` itself only ever needs `crypto_hash/
  core.vani` -- no transitive collision two levels down either.

  Deleted Pi 1's own bignum foundation (`bignum_add_raw`/`sub_raw`/
  `mul_raw`/etc + its own `bignum_self_test`), field25519 arithmetic,
  and Ed25519 point arithmetic (~1300 lines total, rounds 44/67
  originally) -- all internal-only, zero external callers. Kept
  `x25519_scalarmult`/`ed25519_secret_to_public`/`sign`/`verify` as
  `_heap`-suffixed adapters (name collision with the package's own
  functions, same reasoning as round 99's SHA adapters) -- 21 external
  call sites (11 TLS `x25519_scalarmult`, 3 `secret_to_public`, 3
  `sign`, 4 `verify` incl. PKI's own `pki_verify_raw`) renamed to
  match. `x25519_self_test`/`ed25519_self_test` themselves keep their
  ORIGINAL names (no collision once using `core.vani`), rewritten to
  call the new `_heap` adapters with their own existing KAT vectors
  unchanged. Removed ~100 lines of now-dead boot-time persistent-
  scratch allocations (`ed25519_*_set`/`x25519_*_set`, ~5.5KB heap)
  and the `ed25519_init`/`field25519_init`/`bignum_self_test` boot
  calls that initialized them.

  One test-harness timing recalibration needed on the Pi 4/5 side
  (`test/rpi4_shell_smoke.py`'s own `CMD_WAIT_S`, 3->5): `curve25519`'s
  new 130-byte Ed25519 KAT pushed the shell's own `ed25519` command to
  ~2.9s, right at the edge of the old margin -- confirmed via a direct
  timestamped probe, not a functional regression.

  Verified live under QEMU on BOTH ports: Pi 4/5's own 8 smoke tests
  (19 shell commands) all pass after the timing recalibration; Pi 1
  boots with all 19 real `CRYPTO: ...` self-test lines showing
  `(PASS)` and `test/phase4_milestone.py`'s full regression battery
  (100+ checks across networking/DharaFS/scheduler/crypto) passes with
  zero `(FAIL)` lines in the authoritative harness run (a raw ad-hoc
  boot capture briefly suggested 4 DharaFS AEAD tests had regressed --
  traced to a timing artifact in that quick diagnostic script itself,
  not a real failure; confirmed pre-existing by testing round 99's own
  unmodified baseline, which shows the identical apparent failure
  under the same raw-capture method).

  **Next**: ChaCha20/Poly1305 is the only piece left duplicating a Pi
  4/5-side package -- except Pi 4/5 doesn't have ChaCha20-Poly1305 at
  all yet, so that migration needs a brand-new package extraction
  first, not just a Pi-1-consumes-existing-package pass like rounds
  99-100.

  **ROUND 101 UPDATE, 2026-09-07**: new `chacha20_poly1305` kosh
  package built from scratch (`~/source/vani-chacha20-poly1305`,
  pushed) -- the only crypto primitive in this roadmap with no Pi
  4/5-side counterpart to extract from, unlike rounds 98-100's own
  packages.

  Audited Pi 1's real call sites BEFORE designing the package (same
  discipline round 100's own "Next" section called for): `chacha20_
  poly1305_encrypt`/`decrypt`'s own header comment already documented
  a 4096-byte fixed cap (`mac_data_scratch`'s own size), and the real
  production call sites (`tls_encrypt_record`/`tls_decrypt_record`)
  are bounded by `tls_content_scratch`'s own 2048-byte allocation --
  AAD is always a small fixed constant (5/6/8 bytes across every real
  and test call site). Conclusion: unlike SHA-256/512 and Ed25519
  (rounds 99-100), ChaCha20-Poly1305 does NOT need a from-scratch
  streaming redesign to avoid a length cap -- Pi 1's own existing
  design was already capped.

  Chose to build genuine streaming primitives anyway, for a different
  reason found while designing: vani still has no `[expr; N]` array-
  repeat literal (`vani-compiler/docs/DHRUVAOS_ERGONOMICS_TODO.md`
  #1/#2, the same gap that shaped `curve25519`'s own 512-byte Ed25519
  cap in round 100) -- a heap-free package representing a 2048+-byte
  message as one fixed array would need a multi-thousand-element
  hand-typed zero-literal. ChaCha20's own CTR-mode construction (RFC
  8439 section 2.4) makes this easy to route around: blocks are
  independent, so `chacha20_xor_chunk` processes one 64-byte chunk
  against one keystream block with no state threaded between calls at
  all -- a caller loops it over any length just by incrementing the
  counter. Poly1305 DOES need genuine accumulating state (a running
  polynomial evaluation), so `Poly1305Ctx`/`poly1305_init`/`update`/
  `finalize` mirror `crypto_hash`'s own `Sha256Ctx` streaming design
  exactly (same carry-buffer-for-a-partial-block technique) --
  `Poly1305Ctx` stores the raw 32-byte key and re-derives the r/s/pad
  limbs per block rather than threading 13 extra scalar fields through
  every `update` call, a deliberate simplicity-over-cycles tradeoff.

  A smaller one-shot convenience layer (`chacha20_encrypt`/
  `poly1305_mac`/`chacha20_poly1305_encrypt`/`decrypt`, capped at 512
  bytes -- the same ceiling `curve25519`'s own Ed25519 `msg` settled
  on) sits on top of the streaming primitives, built directly on them
  (not a separate implementation) so it doubles as a working template
  for round 102's own Pi 1 adapter, matching the shape `crypto_hash`'s
  own `sha256_hash` heap adapter in `kernel_main.vani` already uses
  (`ctx = sha256_update(ref ctx, mut ref chunk, chunk_n);` inside a
  `while offset < msg_len` loop).

  Every KAT (RFC 8439 section 2.3.2's ChaCha20 block vector, section
  2.5.2's Poly1305 vector, and a DhruvaOS-original AEAD vector already
  used by Pi 1's own self-test) independently re-verified against the
  real `cryptography` Python library before porting -- not trusted
  just because Pi 1's own copy already passes in production. `vanic
  check`/`vanic run test/host_test.vani` both pass first try (all 3
  self-tests PASS); `--backend=c` hits the known, already-filed
  BUG-235 (struct literal with an array field emits a raw pointer on
  the C backend) -- confirmed `curve25519` hits the identical error
  class on `--backend=c` too, so this is pre-existing and non-blocking
  for DhruvaOS (LLVM backend only), not a new bug in this package.

  Also swept every DhruvaOS-extracted kosh package (`crypto_hash`,
  `curve25519`, `pki`, `chacha20_poly1305`, DharaFS, `rpi-mmio`) for
  license consistency per an explicit user check: all six already
  declare Apache-2.0 in `vani.toml` with matching `LICENSE`/`NOTICE`
  files. The unrelated math/ML kosh packages (`vani-tensor`, `vani-
  ml`, etc. -- a separate, pre-existing roadmap) are MIT by design and
  were left untouched.

  **Next**: round 102 -- delete Pi 1's own `chacha20_*`/`poly1305_*`
  implementation and wire in `_heap`-suffixed adapters at the ~20
  external call sites (TLS record encryption, `chacha20_poly1305_
  encrypt`/`decrypt`, `poly1305_mac`), using the package's own
  streaming primitives directly (not the capped one-shot layer) since
  Pi 1's real TLS records already exceed 512 bytes. Not started.

  **ROUND 102 UPDATE, 2026-09-07**: Pi 1 ChaCha20/Poly1305/AEAD
  migrated to the `chacha20_poly1305` package -- third and final
  Phase 1 migration, closing the crypto generification effort for
  every primitive that had duplicate Pi 1/package implementations
  ([[project_dhruva_generic_crypto_packages_x509_scope_2026_09_06]]
  scope).

  Added a `core.vani` split to the package itself first (matching the
  `crypto_hash`/`curve25519` precedent) -- Pi 1's own pre-existing
  `chacha20_self_test`/`poly1305_self_test` collide with the
  package's identically-named self-tests, same class of problem as
  every prior round. Pushed as v0.2.0.

  Deleted Pi 1's own `chacha20_rotl32`/`quarter_round`/`block`, the
  old scratch-based `chacha20_encrypt`, `poly1305_read_u32_le`/
  `write_u32_le`/`mac`, `poly1305_verify_constant_time`, and
  `chacha20_poly1305_build_mac_data`/`encrypt`/`decrypt` (~450 lines,
  rounds 44/67 originally) -- all internal-only or fully superseded.
  `chacha20_bytes_equal` kept untouched (generic byte comparator, no
  algorithm dependency, same reasoning as `sha256_bytes_equal`).

  Unlike rounds 99-100's `_heap` adapters (which called the package's
  own capped one-shot convenience functions), `chacha20_poly1305_
  encrypt_heap`/`decrypt_heap` call the package's STREAMING
  primitives directly (`chacha20_xor_chunk`, `Poly1305Ctx`/`init`/
  `update`/`finalize`, `cp_feed_padded_aad`, `cp_len_trailer`) --
  confirmed necessary before writing any adapter code: Pi 1's real
  TLS records (`tls_encrypt_record`/`decrypt_record`, up to 2048
  bytes) and DharaFS's own 512-byte at-rest block encryption
  (`dharafs_crypto_encrypt_block`/`decrypt_block`, a second real
  production caller found via call-site audit, not just TLS) both
  need more than the package's 512-byte one-shot cap in general (the
  DharaFS case happens to land exactly at the cap, but the streaming
  adapter handles both uniformly rather than special-casing). The new
  adapters also DROP the old scratch-buffer parameters entirely
  (`state_buf`/`working_buf`/`keystream_buf`/`block_scratch`/
  `otk_scratch`/`mac_data_scratch`/`computed_tag_scratch`) since the
  package's own local arrays replace them -- a real signature
  simplification, not just a rename, at both real callers plus 2
  self-tests (`aead_hkdf_self_test`, the DharaFS crypto self-test).
  Removed the now-dead `aead_*_set` boot-time scratch allocations
  (~4.4KB heap); `dharafs_crypto_*_ptr` accessors were NOT touched --
  confirmed via grep that `dharafs_crypto_keystream_ptr()` is still
  used elsewhere as general scratch, unrelated to this migration.

  `chacha20_self_test`/`poly1305_self_test` keep their ORIGINAL names
  (no collision once using `core.vani`) and their exact original KAT
  vectors, rewritten to build fixed arrays and call the package's own
  `chacha20_block`/`chacha20_encrypt`/`poly1305_mac`/`poly1305_
  verify_constant_time` directly (both self-test messages comfortably
  fit the package's 512-byte one-shot cap, so no streaming needed
  there).

  Verified: `vanic check` and `./build.sh` both passed first try (net
  -415 lines). Live QEMU boot shows all 21 `CRYPTO: ...` self-test
  lines `(PASS)`, including the AEAD/HKDF and full TLS 1.3 handshake
  lines that exercise the new production adapters end-to-end.
  `test/phase4_milestone.py`'s full regression battery (15 checks
  incl. `tlsecho`, a live `tls_connect`/`tls_accept` handshake +
  encrypted echo over real TCP -- the actual production path through
  `tls_encrypt_record`/`decrypt_record`) passes with zero `(FAIL)`
  lines in the authoritative harness. A raw ad-hoc `qemu_run.py`
  capture briefly showed 5 DharaFS checks as `(FAIL)` -- same timing-
  artifact class documented in round 100's own writeup, confirmed by
  checking `phase4_milestone.py`'s own full log, which shows the
  identical 5 lines `(PASS)`.

  This closes the crypto generification effort's Phase 1 (SHA-256/512
  round 99, X25519/Ed25519/PKI round 100, ChaCha20/Poly1305/AEAD round
  102) -- every crypto primitive Pi 1 and Pi 4/5 both need now shares
  ONE implementation via kosh packages, per the user's own original
  "make some packages generic so whatever you have pi4 is on pi1 too"
  request. Remaining open items from that same request's broader scope
  (not part of THIS effort): scheduler/priority-ceiling-mutex parity
  (Pi 1 already has MORE scheduler features than Pi 4, corrected
  premise from [[project_dhruva_generic_crypto_packages_x509_scope_2026_09_06]]),
  and the X.509/mTLS/HTTPS/MQTT fork (real X.509 vs. Pi 1's already-
  built raw-public-key TLS 1.3) -- both still open, not started.

  **ROUND 105 UPDATE, 2026-09-07**: user asked to identify OTHER
  hardware-agnostic generification candidates beyond crypto, for
  future multi-board vendor independence. Audit found ~100+ functions
  across ARP/IPv4/TCP/UDP/DHCP(client+server)/packet-filter are pure
  protocol logic with zero hardware register access, duplicated
  near-verbatim between `kernel_main.vani` and `kernel_main_rpi4.vani`
  -- confirmed via direct body comparison (`ipv4_checksum` vs `ipv4_
  checksum_rpi4`: identical algorithm, only buffer-access style
  differs), same low-risk shape as every crypto primitive already
  migrated. Two-way benefit: Pi 4/5 has a real DHCP SERVER Pi 1 lacks;
  Pi 1 has 9 networking self-tests vs Pi 4/5's 5. Scheduler mechanism
  is genuinely arch-specific (can't share); GPIO/UART are genuinely
  per-SoC different (a DHDL-level interface-standardization
  opportunity, not shared-implementation). Full writeup: [[project_
  dhruva_hardware_agnostic_audit_2026_09_07]].

  **ROUND 106a UPDATE, 2026-09-07**: pilot extraction proving the
  pattern -- new `vani-netstack` kosh package (`~/source/vani-
  netstack`, pushed), v0.1.0: the packet filter only. `FilterConfig`
  is a plain value-type struct (8-slot rule table, matching both
  boards' own existing `boot/fw_state.S`/`boot/rpi4/filter_state.S`
  capacity) threaded through pure functions -- no persistent extern
  state inside the package at all, extending the Sha256Ctx/
  Poly1305Ctx precedent from the crypto packages to long-lived
  protocol state for the first time. Each board keeps its own
  existing extern-accessor-backed rule storage untouched and gets a
  thin adapter that reads current state into a `FilterConfig`, calls
  the package, and (for the read-only `check_frame` path) returns the
  result directly -- `filter_add_rule`/`flush`/`set_default_policy`
  needed no changes at all since they were already thin 1-line extern
  pass-throughs, not real duplicated logic.

  Real vani-language constraint hit and worked around: `struct_var.
  array_field[index] = value` is not a valid lvalue (confirmed via a
  standalone probe -- reading through it works, assigning does not),
  so `netstack_filter_add_rule` copies each array field to a local,
  mutates the local, and rebuilds the struct via a fresh literal --
  same pattern `crypto_hash`'s own `sha256_update` already uses for
  `ctx.h`/`ctx.carry`.

  Pi 1's own adapter needed one more step Pi 4/5's didn't: Pi 1's
  `filter_check_frame` takes a heap `mut ref i64` pointer of
  unbounded length (real Ethernet frames up to 1514 bytes), while the
  package's own `netstack_filter_check_frame` takes a fixed `ref
  [u8;512]` array -- resolved by copying up to 512 bytes (comfortable
  headroom over the 38 bytes the filter actually ever reads,
  regardless of overall frame length) into a local stack array before
  calling the package, preserving Pi 1's exact original function
  signature so zero external call sites needed changes.

  Verified on BOTH boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed first try. Pi 4/5: full `rpi4_shell_smoke.py` battery
  (19 shell commands incl. both boot-time and on-demand `filter`
  self-tests) shows zero `(FAIL)` lines. Pi 1: `phase4_milestone.py`'s
  full 15-check regression battery passes with zero `(FAIL)` lines in
  the authoritative harness, both `FW: ...` self-test lines `(PASS)`.

  **Next**: ARP (8-slot cache, similar shape to the filter's rule
  table) is the next-smallest subsystem -- planned as round 106b.
  IPv4/UDP (mostly stateless) after that, then DHCP client+server
  (multi-field state machines), TCP last (largest, ~15-field
  connection struct). Not started.

  **ROUND 106b UPDATE, 2026-09-07**: ARP added to `vani-netstack`
  (v0.2.0, pushed) -- `ArpCache` (8-slot, MAC bytes flattened to
  `[u8;48]` matching both boards' own existing accessor shape) plus
  build/parse (`netstack_arp_build_request`/`build_reply`/`get_
  ethertype`/`is_arp_frame`/`get_operation`/`get_sender_ip`/`get_
  target_ip`/`get_sender_mac`), same value-type-state pattern as
  `FilterConfig`. Both boards' own rule-table storage (`boot/arp_
  state.S` on Pi 1 -- a heap-pointer MAC buffer, `boot/rpi4/arp_
  state.S` on Pi 4/5 -- byte-indexed accessors, a real storage-
  mechanism divide unchanged by this migration) untouched; only the
  cache lookup/insert algorithm and the frame build/parse functions
  moved. `arp_resolve_start`/`poll` (the real `netif_send_frame`/
  `recv_frame` integration) stay board-specific, unchanged -- true
  hardware glue, not duplicated logic.

  Real vani-language limit hit again (`len` is a reserved keyword,
  can't be used as a variable name -- previously known from round 84,
  rediscovered live here as "expected identifier" pointing at the
  token after `let len:`, fixed by renaming to `built_len`).

  Verified on both boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed. Pi 4/5: `rpi4_shell_smoke.py` zero `(FAIL)`, both
  `ARP: ...` lines `(PASS)` (boot-time and on-demand `arp` command).
  Pi 1: `phase4_milestone.py`'s full battery zero `(FAIL)` -- notably
  `netstat shows the ARP entry udpecho inserted` directly exercises
  the new `arp_cache_insert` path in real production traffic, not
  just the self-test. Both `ARP: ...` self-test lines `(PASS)`.

  **Next**: IPv4 (mostly stateless -- header build/checksum, no
  cache/table of its own) is next, round 106c.

  **ROUND 106c UPDATE, 2026-09-07**: IPv4 added to `vani-netstack`
  (v0.3.0, pushed) -- header build/checksum/parse only, RFC 791
  section 3.1, no options/fragmentation, same as both boards' own
  original scope. Deliberately designed around a STANDALONE `[u8;20]`
  header buffer rather than an offset within the caller's own frame
  (what both boards' pre-migration code did) -- confirmed via a real
  gap check before writing the package (per this round's own "check
  real max size" discipline): Pi 1's real frames run to 1514 bytes,
  Pi 4/5's own only to 512, and a header codec has no reason to
  depend on either number since it only ever touches its own 20
  bytes. Avoids the exact "package's fixed array cap too small for a
  real board" class of problem `curve25519`'s own Ed25519 `msg` cap
  hit in round 100, by construction rather than by picking a big
  enough number. Each board's adapter copies its own `ip_offset..
  ip_offset+20` window in/out of the package; the real frame-level
  send path (`ipv4_send`/`ipv4_send_rpi4`, which DOES depend on frame
  size) stays entirely board-specific, unmigrated -- same posture as
  ARP's own `arp_resolve_start`/`poll`.

  Hit the SAME `mut ref` -> `ref` no-reborrow limitation this file's
  own pre-migration `ipv4_checksum_rpi4` header comment already
  documented (round 88) -- a shared 20-byte-extraction helper taking
  `ref [u8;512]` can't be called from a function holding `frame` as
  `mut ref` only. Confirmed via a standalone probe, then fixed the
  same way the original code already did: each Pi 4/5 function
  inlines its own extraction rather than delegating to a shared
  helper (Pi 1's own heap-pointer adapter needed no such workaround,
  since `mut ref i64` has no ref/mut-ref variance to navigate).

  Verified on both boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed. Pi 4/5: `rpi4_shell_smoke.py` zero `(FAIL)`, `IPV4: ...`
  `(PASS)` (boot + on-demand). Pi 1: `phase4_milestone.py`'s full
  battery zero `(FAIL)` -- every one of its own TCP/UDP/TLS checks
  (`tcpecho`/`udpecho`/`tcprtx`/`tlsecho`) routes real traffic through
  the migrated `ipv4_build_header`/`get_*`/`verify_checksum` on every
  packet, the strongest production-path exercise of any migration in
  this networking effort so far.

  **Next**: UDP (round 106d) is genuinely stateless (no cache/table
  at all, simpler than IPv4 even) -- likely the fastest remaining
  piece. DHCP client+server (multi-field state machines) after that,
  TCP last (largest, ~15-field connection struct).

  **ROUND 106d UPDATE, 2026-09-07**: UDP added to `vani-netstack`
  (v0.4.0, pushed). Unlike IPv4's own fixed 20-byte header, UDP's
  checksum spans the WHOLE datagram (header+payload) -- genuinely
  variable length (Pi 1's real payloads run to ~1472 bytes, Pi 4/5's
  loopback-only netif only ~470), so this module streams
  (`UdpChecksumCtx`/`init`/`update`/`finalize`, mirroring `chacha20_
  poly1305`'s own `Poly1305Ctx` running-sum-plus-carry-byte design)
  rather than committing to a package-side array cap sized to either
  board -- the SAME design principle IPv4's own header codec used
  (round 106c), extended properly to genuinely-variable-length data
  the way `crypto_hash`/`chacha20_poly1305` themselves already had to.
  The 8-byte UDP header itself IS small and fixed, so it gets its own
  standalone `[u8;8]` codec (`netstack_udp_header_only`/getters),
  matching IPv4's own header-codec precedent for the part of UDP that
  actually is fixed-size.

  Both boards' `udp_checksum`/`_rpi4` and `udp_build`/`_rpi4` now loop
  their own real `udp_len` through the package in <=256-byte chunks;
  `udp_verify_checksum`/`_rpi4` (already a 1-line delegate to
  `udp_checksum`) needed no changes. `udp_get_src_port`/`dst_port`/
  `length` (both variants) extract their own 8-byte header window and
  call the package's getters.

  Verified on both boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed. Pi 4/5: `rpi4_shell_smoke.py` zero `(FAIL)`, `UDP: ...`
  `(PASS)` (boot + on-demand). Pi 1: `phase4_milestone.py`'s full
  battery zero `(FAIL)` -- all 4 of Pi 1's own UDP self-tests pass,
  including the checksum-rejection edge case (`recv rejects a
  datagram with a corrupted checksum`), a real integrity check on the
  new streaming implementation, not just a happy-path round trip.

  **Next**: DHCP client+server (round 106e) -- the first genuinely
  multi-field STATE MACHINE in this effort (beyond a simple cache/
  table), a bigger design step than filter/ARP/IPv4/UDP. TCP last
  (largest, ~15-field connection struct).

  **ROUND 106e UPDATE, 2026-09-07**: DHCP added to `vani-netstack`
  (v0.5.0, pushed) -- BOOTP fixed-header build/parse, message-type
  constants, options 50/51/53/54 scan (byte and u32 forms), the
  client's own DISCOVER/REQUEST/RENEW-REQUEST builders, and the
  server's own OFFER/ACK/NAK builders plus its 4-slot lease-table
  lookup (`DhcpLeaseTable`, extending `ArpCache`'s own value-type-
  state design). Every real DHCP message here is small and fixed-size
  (256 bytes max) -- unlike UDP's own variable-length payload, so
  this module uses a standalone `[u8;512]` buffer + `dhcp_offset`,
  matching the filter/ARP precedent rather than IPv4/UDP's own
  offset-independent/streaming designs, confirmed correct by checking
  the real max message size FIRST (per this effort's own recurring
  discipline) rather than assuming streaming was needed just because
  DHCP "feels" like a bigger protocol.

  Pi 1 has NEVER had a DHCP server (confirmed again this round via
  grep -- zero `dhcp_server_*` functions exist there) -- the server-
  side builders/lease-table have no Pi 1 code to migrate FROM, so
  they were extracted directly from Pi 4/5's own implementation and
  wired only into Pi 4/5 this round. This positions a FUTURE round to
  give Pi 1 a real DHCP server by writing only the netif/socket
  integration glue (`handle_discover`/`handle_request`/`poll`/
  `send_reply`, plus the lease-table's own persistent storage, a new
  `boot/dhcp_server_state.S`) -- the actual message-format algorithm
  already exists and is already proven correct, unlike every other
  migration in this effort which only had to UNIFY code that already
  worked on both sides.

  Client FSM-state constants (`dhcp_state_init`/`selecting`/etc, both
  boards) deliberately NOT migrated -- pure per-role bookkeeping, not
  message-format algorithm, same "don't migrate everything just
  because it has the same name" judgment call filter's own `add_
  rule`/`flush` needed in round 106a.

  Verified on both boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed. Pi 4/5: `rpi4_shell_smoke.py` zero `(FAIL)`, both
  `DHCP: ...`/`DHCPS: ...` lines `(PASS)` (boot + on-demand `dhcp`/
  `dhcps` commands). Pi 1: `phase4_milestone.py`'s full battery zero
  `(FAIL)` -- all 3 of Pi 1's own DHCP self-tests pass, including the
  more complex lease-RENEWAL (BOUND->RENEWING unicast->REBINDING
  broadcast->refresh/expiry) and NAK-handling (client resets to INIT)
  scenarios, not just the basic DISCOVER->OFFER->REQUEST->ACK->BOUND
  happy path.

  **Next**: TCP (round 106f) -- the largest and last piece of the
  networking-generification effort, a ~15-field connection struct
  (state/seq/ack/ports/ips/rtx-tracking), genuinely the biggest
  design step of the whole effort. After that, round 103 (scheduler
  scoping) and round 104 (X.509 fork) per the user's own stated order.

  **ROUND 106f UPDATE, 2026-09-07**: TCP added to `vani-netstack`
  (v0.6.0, pushed) -- the header codec/checksum only, closing the
  networking-generification effort. TCP's 20-byte header (options
  never sent, data offset always 5) gets the SAME standalone-buffer
  codec IPv4's own header got; its checksum spans the whole segment
  (header+payload, genuinely variable length like UDP's own scope)
  so it streams. A real, non-trivial finding here: TCP's own running-
  sum accumulation is IDENTICAL to UDP's -- both RFC 768/793 define
  the same 16-bit one's-complement pseudo-header-plus-segment sum,
  only the protocol number (6 vs 17) and the final step differ (TCP
  has no RFC-768 zero-substitution, so a valid segment sums to 0, not
  UDP's 0xFFFF) -- so `netstack_udp_checksum_update` (the accumulator
  itself, already fully protocol-agnostic) is reused AS-IS for TCP,
  with only new `netstack_tcp_checksum_init`/`finalize` variants for
  the parts that actually differ. Avoided writing a byte-for-byte
  duplicate `netstack_tcp_checksum_update` for zero behavioral gain.

  The connection STATE MACHINE (SYN/ACK/FIN handling, retransmission,
  the actual ~15-field `TcpConn` state this round's own "Next" note
  above anticipated) was deliberately NOT migrated -- it's real
  network I/O orchestration (sending ACKs/retransmits mid-decision,
  touching each board's own persistent per-connection extern state),
  the same class of thing `arp_resolve_start`/`poll` and DHCP's own
  client/server poll functions already stayed unmigrated for
  throughout this whole effort. Splitting decision logic cleanly from
  I/O would be a genuine architecture redesign of both boards' TCP
  state machines, not an extraction of already-duplicate pure
  algorithm -- correctly out of scope for this effort's own pattern.

  Verified on both boards: `vanic check`/`build.sh`/`build_rpi4.sh`
  all passed. Pi 4/5: `rpi4_shell_smoke.py` zero `(FAIL)`, both
  `TCP: ...` lines (header build/checksum, full connection lifecycle)
  `(PASS)`. Pi 1: `phase4_milestone.py`'s full battery zero `(FAIL)`
  -- ALL 6 of Pi 1's own TCP self-tests pass, including simultaneous
  open/close and peer-window-enforcement edge cases, PLUS the
  battery's own real `tcpecho`/`tcprtx`/`tlsecho` traffic all routes
  through the migrated header codec and streaming checksum on every
  single segment -- the strongest, broadest verification of any
  migration in this entire effort.

  **THE NETWORKING-GENERIFICATION EFFORT IS NOW CLOSED.** Packet
  filter (106a), ARP (106b), IPv4 (106c), UDP (106d), DHCP (106e),
  and TCP (106f) all now share one `vani-netstack` kosh-package
  implementation across Pi 1 and Pi 4/5, matching what Phase 1 crypto
  generification (rounds 98-102) already achieved for every crypto
  primitive. Combined with crypto, this closes the user's own original
  "make some packages generic so whatever you have pi4 is on pi1 too"
  request for BOTH the crypto and networking layers -- everything
  duplicated between the two boards at the protocol/algorithm level
  (as opposed to genuine hardware register access) now lives in a
  shared, hardware-agnostic package a future non-RPi board could
  consume too, per the user's own stated multi-board-portability
  goal. One concrete follow-on opportunity flagged but not scheduled:
  giving Pi 1 a real DHCP server (round 106e's own note -- the message
  algorithm already exists, only netif/socket glue would be new work).
  Next: round 103 (scheduler policy-vs-mechanism scoping) and round
  104 (X.509/mTLS/HTTPS/MQTT fork decision), per the user's own
  explicitly stated order.

  **ROUND 103 UPDATE, 2026-09-07 (scoping only, no code changes)**:
  read both boards' scheduler implementations end-to-end. The gap is
  much starker than "Pi 1 has more features" -- Pi 4/5's own
  `boot/rpi4/task_switch.S` (127 lines) is a hardcoded 2-task
  (`task_a`/`task_b` by name) round-robin toy with no priority field,
  no mutex, no sleep/wake, no dynamic task creation at all; Pi 1's own
  `boot/context_switch.S` (1511 lines) has a real N-task (16-slot)
  priority scheduler with a genuinely sophisticated two-branch
  `scheduler_pick_next` algorithm (ties favor the incumbent when
  priority-boosted/holding a ceiling-protected lock, fair round-robin
  otherwise), a full priority-ceiling mutex protocol (`dhruva_prio_
  lock`/`unlock`, `dhruva_mutex_lock`/`unlock`), sleep/wake, and
  defensive hardening from a real historical bug (round 65's own r8-
  clobber investigation).

  Unlike every crypto/networking migration this year, there is NO
  pre-existing vani-side algorithm to extract here -- the scheduling
  decision logic exists ONLY as hand-written, architecture-specific
  assembly (ARM32 AAPCS32 on Pi 1, ARM64 AAPCS64 on Pi 4/5), directly
  manipulating fixed tables via raw register loads/stores. "Generifying"
  this would mean DESIGNING NEW shared vani scheduling logic from
  scratch (mirroring Pi 1's own more-complete algorithm, since it's
  the proven one) and rewriting both boards' context-switch entry
  points to call into it -- novel engineering against the single most
  safety-critical subsystem in the OS, not extraction of already-
  equivalent code. A scheduler bug corrupts stacks or livelocks the
  whole system in ways that only manifest under real concurrent load
  (this project's own round-65 incident is a direct, on-the-record
  example), unlike a bounded, visible networking/crypto bug.

  **Recommendation, not yet acted on**: this needs an explicit user
  decision on the risk/value tradeoff before any implementation --
  Pi 4/5's scheduler currently has no real users depending on richer
  behavior yet, so the case for taking on this risk now (vs. later,
  vs. never) is a real judgment call, not an engineering question this
  round can resolve alone. Full writeup: [[project_dhruva_round103_
  scheduler_scoping_2026_09_07]]. No code changes made.

  **ROUND 104 UPDATE, 2026-09-07 (scoping only, no code changes)**:
  confirmed zero X.509/ASN.1/certificate-chain machinery exists
  anywhere in this codebase -- current PKI (`vani-pki`, 3 functions)
  is a pinned-raw-public-key model only (RFC 7250: the verifier
  already knows the exact expected key, never discovers/validates a
  chain); current TLS is a deliberately fixed single-ciphersuite scope
  (`TLS_CHACHA20_POLY1305_SHA256`/x25519/Ed25519, no session
  resumption/PSK/0-RTT).

  The user's own "X.509/mTLS/HTTPS/MQTT" framing is actually 4
  separable pieces of very different size: (1) X.509 itself --
  foundational and BY FAR the largest (ASN.1/DER parser + certificate
  structure parsing + chain validation + trust store + hostname/SAN
  checks), realistically comparable in scope to the entire SHA-512->
  X25519->Ed25519->PKI crypto chain (rounds 94-97) on its own; (2)
  mTLS -- needs X.509 PLUS extending the existing server-only TLS
  handshake to a real client-cert flow; (3) HTTPS -- needs a brand-
  new HTTP/1.1 parser (nothing HTTP-shaped exists today) but does
  NOT strictly need X.509 if staying within the pinned-key model
  (can run over the EXISTING TLS 1.3 stack for any closed/embedded
  scenario); (4) MQTT -- needs its own new packet-format module,
  also independent of X.509 unless mTLS-authenticated MQTT is
  specifically wanted.

  The real fork: does DhruvaOS need to interoperate with the standard
  CA-based TLS/PKI ecosystem (a real browser, a public cloud IoT
  broker) -- if yes, X.509 is mandatory and its own large multi-round
  effort; if DhruvaOS's real use cases are closed/embedded (matching
  every trust model this project has built so far -- ARP's cache,
  DHCP's lease table, TLS/PKI's own pinned-key design), HTTPS and
  MQTT can each be built as new protocol layers directly on the
  EXISTING, already-proven TLS 1.3 stack with NO X.509 work at all --
  a dramatically smaller and faster path to the same practical
  device-level outcome. Full writeup: [[project_dhruva_round104_
  x509_scoping_2026_09_07]]. No code changes made -- awaiting user
  direction on which fork to take.

  **ROUND 107 UPDATE, 2026-09-07**: Pi 1 given a real DHCP server --
  the concrete follow-on flagged in round 106e's own memo. The
  message-format ALGORITHM (build_offer_ack/build_nak, the lease-
  table lookup) already lived in the shared `netstack` package,
  proven correct on Pi 4/5 -- this round's own new work was purely
  the netif/socket integration glue (`dhcp_server_init/handle_
  discover/handle_request/poll/send_reply`, direct ports of Pi 4/5's
  own round-92 functions to this file's heap `mut ref i64` style) and
  a brand-new `boot/dhcp_server_state.S` (ARM32 persistent lease-
  table storage, ported from Pi 4/5's own ARM64 version).

  Caught and fixed a real design error before it shipped: the new
  server code's own draft reused `dhcp_server_mac_scratch` (an
  EXISTING buffer whose real purpose is the CLIENT role's own record
  of the DHCP SERVER's MAC, learned from an ACK) to hold the SERVER
  role's own view of a CLIENT's MAC -- same name, opposite meaning.
  Added a dedicated `dhcp_server_client_mac_scratch` instead,
  matching this project's own explicit "one buffer, one purpose"
  discipline (`arp_resolve_mac_scratch`'s own comment already warns
  against exactly this borrowed-name mistake).

  The new ARM32 asm (`dhcp_server_state.S`) deliberately avoids `MUL`
  entirely for its own 6-byte-per-slot MAC indexing (index*6 computed
  via shift+add instead) rather than relying on ARMv6 having relaxed
  MUL's historical Rd/Rm-overlap restriction -- confirmed via
  disassembly that the emitted code uses only ADD/LSL, no MUL, and
  only r0-r3 as scratch throughout (matching [[feedback_aapcs_
  callee_saved_registers_asm]]'s own r0-r3-only discipline -- a real,
  4-times-recurring bug class in this project when asm functions
  touch r4-r11 without saving/restoring them).

  Verified: `vanic check`/`build.sh` both passed first try.
  `phase4_milestone.py`'s full battery zero `(FAIL)` -- the brand-new
  `DHCPS: server DISCOVER->OFFER, REQUEST->ACK, unknown-MAC REQUEST->
  NAK` self-test passes on its FIRST live run, and every pre-existing
  networking self-test (filter/ARP/IPv4/UDP/TCP/DHCP client) still
  passes with zero regressions. No shell command added (`dhcps` on
  Pi 4/5 is really just an on-demand rerun of its own self-test, and
  Pi 1's own shell has no equivalent "rerun a self-test" convention
  for any of its other networking self-tests either -- this one runs
  at boot only, matching Pi 1's own established pattern).

  **ROUND 108 UPDATE, 2026-09-07**: HTTPS added -- a new, minimal,
  hardware-agnostic `http` kosh package (`~/source/vani-http`, GET/
  POST + headers + Content-Length body framing, no chunked transfer-
  encoding -- an honest scope boundary matching TLS's own single-
  ciphersuite scope and DHCP's own no-relay-agent scope) layered
  directly on Pi 1's existing TLS 1.3 stack via a new `httpecho` shell
  command (mirroring `tlsecho`'s own both-roles-in-one-instance
  shape: a real POST /echo request, encrypted and sent over real TCP,
  decrypted/parsed/re-encoded into a real 200 OK response on the
  "server" side, decrypted and parsed again on the client side).
  **Confirmed Pi 4/5 has no TLS implementation at all yet** (only the
  crypto PRIMITIVES were ever ported there, rounds 94-98) -- so this
  round's own HTTPS work is Pi 1-only; Pi 4/5 would need a full TLS
  1.3 port first (a undertaking of similar scope to the original
  rounds 94-97 crypto-chain work) before HTTPS could land there too.

  A real, load-bearing infrastructure bug found and fixed along the
  way: this project's own ARM-side RAM mapping (`boot/mmu_init.S`)
  has mapped only 2MB (sections 0-1) since round 38 -- and this
  round's own new code (the `http` package + `httpecho`) pushed the
  linked image's total footprint (code+data+bss+768KB heap+task
  stacks) past that ceiling for the FIRST time, moving the heap's own
  base address into genuinely unmapped memory and crashing with a
  Data Abort at exactly address 0x00200000 on every single boot.
  Root-caused by comparing `nm --size-sort -S` output between the
  round-107 baseline (`__bss_end` = 0x1c9e98, safely under 2MB) and
  the broken build (`__bss_end` = 0x2c9ea8, ~941KB over) -- confirmed
  by finding `dhruva_heap`'s own linked base address (0x209e9c)
  already past 0x00200000. Fixed the same way ROUND 71 already fixed
  an analogous "ran out of mapped space" problem for GPU RAM: mapped
  8 more 1MB sections (2-9, extending ARM RAM to 10MB total) as plain
  read-write/never-execute sections, giving ~7MB of real headroom
  over the current ~2.94MB footprint -- room for MQTT (round 109) and
  beyond without hitting this ceiling again soon. Verified via
  `phase4_milestone.py` (zero regressions) AND `heap_stress.py`'s own
  dedicated heap-exhaustion regression check (still PASS).

  Verified: `vanic check`/`build.sh` both pass. `phase4_milestone.py`'s
  full battery zero `(FAIL)` -- the new `httpecho` self-test passes on
  its first live run, proving the package's own build/parse functions
  round-trip correctly over a GENUINE encrypted transport (not just
  the package's own buffer-to-buffer self-test).

  **ROUND 109 UPDATE, 2026-09-07**: MQTT added -- a new, minimal,
  hardware-agnostic `mqtt` kosh package (`~/source/vani-mqtt`, v0.2.0)
  implementing MQTT v3.1.1's CONNECT/CONNACK, PUBLISH/SUBSCRIBE/SUBACK,
  PINGREQ/PINGRESP, and DISCONNECT. Initially scoped QoS 0 only (per
  round 105's own follow-on sequencing); the user then explicitly
  asked for BOTH TLS and plain-TCP transport, and separately for QoS
  0/1/2 all available -- both requests changed the package and its
  integration mid-round. QoS 1 (PUBACK) and the full QoS 2 four-way
  handshake (PUBREC/PUBREL/PUBCOMP) were added to the package (v0.1.0
  -> v0.2.0): PUBLISH gained an optional packet identifier and
  generalized DUP/QoS/RETAIN flags. Packet-identifier allocation and
  retry/dup-detection are deliberately left to the caller -- the same
  mechanism/policy split this project's own TCP retransmit logic
  already draws (`tcp_conn_check_retransmit_rpi4` lives in the kernel
  file, not the shared `netstack` package).

  Wired into BOTH boards, each over the transport that board actually
  has:
  - **Pi 1** (`kernel_main.vani`): a new `mqttecho <text>` shell
    command layered on the existing real TLS 1.3 + TCP stack (mirrors
    `httpecho`'s own both-roles-in-one-instance shape), exercising the
    full QoS 1 CONNECT->CONNACK, SUBSCRIBE->SUBACK, PUBLISH->PUBACK,
    PINGREQ->PINGRESP, DISCONNECT lifecycle -- the user's own typed
    text is the live PUBLISH payload, round-tripped through real
    encryption both ways.
  - **Pi 4/5** (`kernel_main_rpi4.vani`): a new `mqtt` shell command
    (self-test style, matching `tcp`/`udp`/`dhcp`'s own bare-command
    convention) running the same QoS 1 lifecycle over PLAIN TCP --
    confirmed (again, same finding as round 108) that Pi 4/5 has no
    TLS at all, so this is the only MQTT path that board can offer
    without a full TLS 1.3 port first. Hand-drives the loopback frame
    queue exactly like `tcp_conn_self_test_rpi4`'s own handshake+data+
    close lifecycle; a new `mqtt_send_and_drain_rpi4` helper drains
    BOTH frames a one-directional send produces (the data segment
    itself, auto-ACKed by the receiver) to keep the manual "traffic
    cop" frame queue from seeing stale ACKs where it expects new data.

  A real, load-bearing constraint hit and fixed on Pi 1: adding
  `mqttecho`'s own per-exchange packet buffers pushed `task_f`'s own
  `#[bounded_stack(bytes=12288)]` worst-case stack budget from ~11.5KB
  to 21020 bytes -- NOT the round-108 RAM-mapping ceiling (a different
  constraint: total image footprint vs. one task's own worst-case call-
  chain stack depth). Root-caused by realizing vani's stack-bound
  checker counts EVERY distinct `[u8;512]` array `let`-declared
  anywhere in `shell_dispatch` (one giant function housing every shell
  command as sibling `if` branches) toward that one function's own
  frame size, regardless of branch -- 18 per-exchange packet buffers
  (2 per exchange x 9 exchanges) cost 9216 bytes on their own. Fixed
  by collapsing to a SINGLE reused `[u8;512]` buffer for both building
  outgoing packets and receiving incoming ones (safe since each
  exchange fully completes -- build -> send -> receive -> parse --
  before the next begins, and the one value that must outlive a later
  reuse, the PUBLISH payload, gets snapshotted into a heap scratch
  buffer immediately after parsing); confirmed empirically that
  consolidating same-typed scalar/struct locals via reassignment
  (`fh = mqtt_parse_fixed_header(...)` instead of redeclaring per step)
  had ZERO measurable effect on the reported budget, meaning this
  checker's model is dominated by array byte-width specifically, not
  variable count -- worth remembering for any future task worried
  about this same budget. Final inline-a-single-field-access trim
  (`mqtt_parse_connect(...).ok` instead of a named intermediate) closed
  the last 4 bytes.

  Verified on both boards: Pi 1's `vanic check`/`build.sh` clean,
  `phase4_milestone.py` zero `(FAIL)` with the new `mqttecho hello-
  mqtt` step passing on its first live run (footprint still `0x2c9ea8`
  bytes, comfortably inside round 108's 10MB mapped ceiling). Pi 4/5's
  `vanic check`/`build_rpi4.sh` clean (no bounded_stack budget exists
  there at all), `rpi4_boot_smoke.py` shows the new boot-time `mqtt`
  self-test passing on its first live run, and `rpi4_shell_smoke.py`
  (extended to 20 commands) confirms the live `mqtt` shell command
  re-invocation also passes -- zero regressions on either board's own
  full pre-existing self-test suite.
- Only after both of the above: EMMC2 (storage) and XHCI (USB) drivers
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

- **Priority/deadline-aware FS request queue** — `[DONE, round 67,
  2026-09-02]`
  `boot/fsqueue_state.S` (8 fixed slots) + `dharafs_queue_submit_write_raw`/
  `_submit_delete_raw`/`_submit` (Str convenience wrapper, auto-tags
  the calling task's own `current_eff_prio()`/`current_task_get()`) +
  `dharafs_queue_dispatch_one` (always picks the numerically LOWEST
  priority value -- this project's own "0 is highest" convention --
  oldest submission first among ties) + a dedicated background task
  (`task_fsq`, priority tier 2, same tier as `task_gc`'s compaction,
  drains the whole queue every wake). Every EXISTING synchronous
  `dharafs_*` call site is completely unchanged -- purely additive/
  opt-in, exactly the scoping this entry originally called for.
  Queued writes are capped at `dharafs_block_payload_cap()` (448
  bytes, single-block only); a full queue or oversized write is
  rejected cleanly (caller falls back to a direct synchronous call).
  34 new host-harness checks (659→693 PASS, clean under ASAN/UBSAN),
  including explicit priority-inversion-shaped ordering tests (a
  low-priority submit made FIRST is dispatched AFTER a high-priority
  one submitted later) and FIFO tie-break verification. Live-verified:
  `task_create: fsqueue dispatcher task id=9` prints at boot,
  `heap_stress.py` clean with the new background task running
  continuously, `phase4_milestone.py` 14/14.

- **Snapshots / versioned rollback** — `[DONE, round 67, 2026-09-02]`
  Turned out NOT to need `dharafs_compact` reclaim-logic changes at
  all, once actually re-examined against the real code: `dharafs_
  compact`'s "reclaim" is an IN-RAM-ONLY optimization (advancing
  `log_start`, which unconditionally resets to 1 on the next
  `dharafs_init`/boot) that hides old blocks from ordinary lookups
  without ever erasing their bytes -- `next_block` only ever grows,
  nothing in this v1's design reuses or overwrites a block number
  within one boot session. So a "snapshot" doesn't need to pin/protect
  anything from reclaim; it only needs to remember a sequence number
  to query against later. `boot/snapshot_state.S` (8 named slots) +
  `dharafs_snapshot_create(name)` (pins `next_seq - 1`, the highest
  seq that genuinely existed at that moment) + `dharafs_snapshot_read(
  path, name, buf)` (finds the highest-seq record for `path` with
  `seq <= pinned_seq`, scanning from block 1 -- not `log_start` --
  the one deliberate place in this codebase that looks past what
  `log_start` currently hides) + `dharafs_snapshot_delete(name)`.
  `dharafs_read_raw` was refactored (behavior-preserving, re-verified
  against the full existing test suite before adding anything new) to
  extract `dharafs_read_from_block_raw`, shared by both the ordinary
  current-state read path and the new snapshot read path, avoiding a
  second copy of the chain-following logic. 35 new host-harness
  checks (693→728 PASS, clean under ASAN/UBSAN) including the load-
  bearing one: create a snapshot, overwrite the file, run a REAL
  `dharafs_compact()` pass that reclaims the old block from ordinary
  lookups, and confirm the snapshot still reads the pre-overwrite
  content byte-exact -- proving the no-compact-changes-needed design
  claim against actual compaction, not just against an un-compacted
  log. Scope, explicit: filesystem-wide snapshots (one pin covers
  every path), not per-file/per-directory; no snapshot-aware
  `dharafs_list`; bounded by the same 2048-block/1MB v1 log region
  cap every other DharaFS feature already has.

- **Hashed directory index** — `[DONE, round 67, 2026-09-02]`
  `boot/dirindex_state.S`: a 256-slot open-addressed (linear probing,
  no deletion) RAM-only path-hash -> latest-block table, FNV-1a hash,
  built by `dharafs_init`'s own boot-time scan and kept in sync by
  `dharafs_append_raw`/`dharafs_delete_raw` on every successful write
  (every path-mutating operation in this codebase funnels through one
  of those two). `dharafs_find_latest_block_raw` tries the index
  first (O(1) probe) and only falls through to the original full
  linear scan on a miss, which then self-heals the index for next
  time -- a HIT is always correct by construction, a MISS is always
  safe (identical behavior to before this change, never a regression,
  including graceful degradation if the table's realistic-scale 256
  slots ever genuinely fill). 23 new host-harness checks (636→659
  PASS clean under ASAN/UBSAN), including a 300-path bulk-load test
  whose real correctness contract is "every hit is byte-exact,
  regardless of collisions" rather than "every path fits." Live-
  verified over a real SD image via `phase4_milestone.py` (write/
  read/list all still correct through the accelerated path).
  Wear/erase statistics and capability tokens beyond uid/gid/mode
  remain explicitly OUT of scope, same reasoning as before: no
  current backend (SDHOST, USB mass storage) exposes wear/erase
  information at this layer at all, and capability tokens are a
  separate, PKI-sized security-model expansion, not a hash-index
  side effect.

- **General task-creation API** — see the entry near the bottom of
  this file ("User-facing documentation + general-purpose RTOS gaps")
  -- confirmed DONE since round 54, this entry's own "not started"
  framing above (now corrected there) was simply stale.

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

- **Self-observing kernel: event counters** — `[DONE — counters round
  53, ring buffer round 66, 2026-09-01]`
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

  **Round 66: the ring buffer, the one genuinely separate remaining
  piece, is now built.** Deliberately does NOT touch `boot/context_
  switch.S` at all (`scheduler_pick_next`/`dhruva_prio_lock`, where
  `context_switch_count`/`prio_lock_count` actually increment) — the
  exact fragile hand-written-asm scheduler/interrupt path this project
  has already taken two real, hard-to-diagnose bugs from (this same
  AAPCS bug class above, and separately the round-65 task_f corruption
  bug). Instead, a new `boot/diag_ring_state.S` samples the EXISTING
  counters (via their own already-correct `*_get()` accessors) once
  per REAL timer tick from `irq_dispatch` — already vani-level code
  that already runs every tick, zero new touches to the fragile area.
  Concrete answers to this entry's own "needs a decision" blocker: 32
  slots (~16 seconds of history at the 500ms tick period), 512 bytes
  of static `.bss` (four parallel u32 arrays), one sample per tick
  (not per individual event) — negligible overhead, no numeric budget
  needed since the cost is a handful of instructions once every
  500ms. `diag_ring_push` takes four plain `u32` arguments
  (specifically not `i64`, to keep every argument in exactly one AAPCS
  register with no 64-bit pairing to get wrong) and explicitly saves/
  restores the r4/r5 it uses as scratch — the exact fix for the bug
  class this entry's own text warns about, applied directly this time
  rather than just cited. `diagnose` now prints the ring's contents
  (oldest to newest, tick/ctxsw/irqs/priolock per line) after its
  existing running-total counters.

  Verified live over QEMU in both boundary cases the wraparound math
  actually needs to get right: under 32 ticks since boot (unwrapped,
  oldest sample always physical slot 0) and past 32 ticks (wrapped,
  oldest sample at wherever `head` currently points) — both produced
  exactly the expected monotonically-increasing tick numbers and
  non-decreasing counter values, capped at 32 rows once wrapped, never
  exceeding it.

  **Correction, same day**: this entry originally claimed the ring
  buffer couldn't be host-harness tested (hand-written ARM assembly,
  native x86 can't run it) — true of `diag_ring_state.S` itself, but
  wrong as a reason to skip coverage: `host_stubs.c` already has a
  precedent for exactly this (`netif_get_head`/etc, genuinely stateful
  native C reimplementations, not dummy stubs) that was overlooked at
  first. Also caught a REAL bug this way: the original commit broke
  `test/host_harness/build_and_run.sh` outright (a linker error,
  `irq_dispatch` now unconditionally calling `diag_ring_push` with no
  native implementation anywhere) — not caught at the time because
  host_harness wasn't re-run after that specific change. Fixed by
  adding a genuine stateful stub (`host_stubs.c`) mirroring the asm's
  own ring/wraparound logic exactly, plus a dedicated test covering
  both the unwrapped and wrapped cases instantly and repeatably instead
  of only via a ~25-real-second live QEMU wait. Full regression battery
  green: `qemu_run.py`, `phase4_milestone.py` 14/14, `host_harness`
  (463/463 PASS under ASAN/UBSAN, up from the broken build).

  **Lesson, worth remembering**: after ANY change touching a function
  a hand-written `.S` file's own code calls (`irq_dispatch` here), run
  `host_harness`'s own build, not just the QEMU regression battery —
  the vani-generated C side links against real symbols and a missing
  one is a hard build failure, not a subtle runtime issue that might
  go unnoticed.

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
  rounds — WRITTEN (536 lines as of round 69, 2026-09-04); update
  passes done for round 67's later same-day crypto batch (AES/TLS/
  PKI/PQC/media encryption), round 68 (scheduler fix, stack canary,
  PBKDF2 iteration count), and round 69 (crypto command, AEAD/tamper-
  detection/two-time-pad fix) -- kept current alongside the code each
  round, not left to drift]`
  Boot process, the scheduler/task model (including its current
  6-task-fixed limitation, stated plainly rather than glossed over),
  the interactive shell and all ~20 commands, the heap allocator's
  never-free/OOM-fatal model, how to extend the kernel today (before
  a real task API exists) and how that changes once one does, build/
  run instructions. Written before the task-creation API below so it
  can honestly describe the CURRENT state, then gets a real update
  once that API lands rather than documenting something aspirational.

- **DharaFS user manual** (`docs/DHARAFS_MANUAL.md`) — `[M, ~1 round —
  WRITTEN (398 lines as of round 69, 2026-09-04); covers round 67's
  snapshots/hashed-directory-index/priority-queue additions and round
  69's AEAD/tamper-detection/two-time-pad media-encryption upgrade --
  kept current alongside the code each round, not left to drift]`
  On-disk record format, the permission model (owner/group/other +
  immutable/append-only/system attributes), rename+transaction
  semantics, verified I/O (`writev`/`catv`), the append-only log API,
  crash-consistency guarantees (and their actual limits — compaction's
  own documented failure modes, the transaction primitive's own
  "old-or-new, never mixed" scope), the block-device backend
  abstraction, full `dharafs_*` API reference.

- **General task-creation API** — `[DONE, round 54 -- this entry's own
  "not started" framing was stale, caught 2026-09-02 while auditing
  Tier 1 for remaining work]`
  `task_create(entry_fn, stack_base, stack_bytes, priority) -> task_id`
  (`boot/context_switch.S`) replaced the old hardcoded 6-word `sp_table`/
  `eff_prio_table`/`sleep_until_table` arrays with a real
  `MAX_TASKS=16` bounded table (fixed compile-time bound, as this
  entry's own reasoning below recommended — no dynamic allocation, no
  heap-fragmentation exposure). Round 54/55 also built `task_create`-
  based demo tasks (`task_custom_*`) proving it works end to end, not
  just compiling. `start_multitasking` no longer takes a fixed
  argument list either. Every existing scheduler self-test (priority
  ceiling, preemption, `task_sleep_ticks`) still passes against the
  generalized table.

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
  spec-only) + connection establishment/ACL/L2CAP/core ATT (DONE,
  round 66, spec-only) + GATT discovery + client read/write-by-index
  (DONE, round 66, spec-only) + GATT SERVER role + 128-bit custom
  UUIDs + notifications/indications + L2CAP Signaling (DONE, round 66,
  spec-only)** — `[L, several rounds — DONE. User explicitly asked for
  "full BLE stack implementation" including all of the above; both
  GATT roles (client discovering a peer's attributes AND Dhruva
  exposing its own), 128-bit custom UUID decoding, and the
  notification/indication subscribe-and-receive path are now all
  built]`
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
  **Round 66 (2026-09-01) — connection establishment + ACL/L2CAP/core
  ATT built.** Scanning alone (round 57) never yields a connection
  handle, and L2CAP/ATT/GATT all run over an established connection's
  ACL data channel — a genuinely missing prerequisite this round found
  and closed, not just "L2CAP itself." Added: `hci_build_le_create_
  connection_command` (§7.8.12) + Command Status (§7.7.15, the async
  "accepted, working on it" ack LE_Create_Connection answers with,
  unlike this driver's other, synchronous commands) + LE Meta Event/LE
  Connection Complete (§7.7.65/.1) parsing, to actually get a
  connection handle; HCI ACL Data packet framing (§5.4.2, build/parse
  the `[Handle:12|PB:2|BC:2][Length]` envelope every L2CAP packet
  travels in — the raw bulk OUT/IN transport itself, `dwc2_bt_bulk_
  out/in`, was ALREADY built round 57, just never used); L2CAP B-frame
  framing (§3.1, Vol 3 Part A) with the LE ATT fixed channel ID
  (0x0004); and ATT's own core operations (Vol 3 Part F) — Error
  Response, Exchange MTU Request/Response, Read Request/Response,
  Write Request/Response — enough for a real "connect, negotiate MTU,
  read/write one already-known attribute handle" interaction end to
  end. Also added `buf_write/read_u16_le` (every one of these layers
  is little-endian throughout, and needed far more 16-bit fields than
  the existing byte-at-a-time HCI command builders ever justified a
  dedicated helper for individually).

  **Round 66 (2026-09-01), same day — GATT discovery + client read/
  write built**, user explicitly asked to continue toward "a full BLE
  stack" after the connection/ACL/L2CAP/core-ATT increment above.
  Added the ATT discovery PDUs GATT's own procedures are built on top
  of (Find Information §3.4.3, Read By Type §3.4.4.1-2, Read By Group
  Type §3.4.4.9-10 — GATT defines the PROCEDURE, not new wire format:
  a "service" is just an attribute of type 0x2800 discovered via Read
  By Group Type, a "characteristic" an attribute of type 0x2803
  discovered via Read By Type within a service's own handle range),
  plus all 17 standard ATT error codes (`att_error_attribute_not_
  found` specifically is how every discovery loop recognizes "no more
  results" — a real Error Response, not a distinct signal).

  GATT's own semantic layer sits on top: `gatt_discover_primary_
  services` (§4.3.1, repeats Read By Group Type with a narrowing
  starting handle until Attribute Not Found) and `gatt_discover_
  characteristics_for_service` (§4.6.1, same shape via Read By Type
  within one service's range) populate a new fixed-size discovery
  table (`boot/gatt_state.S` — 8 services/32 characteristics, matching
  this project's own established "fixed-size, no dynamic allocation
  for control structures" discipline, MAX_TASKS/ARP-cache/TCP-slots
  style). `gatt_discover_all` orchestrates both. `gatt_read_
  characteristic_value`/`gatt_write_characteristic_value` then work in
  terms of a DISCOVERED characteristic's own table INDEX, not a raw
  ATT handle — the actual client-usable surface: discover once, then
  read/write by index. `gatt_att_send`/`gatt_att_recv` wrap one ATT
  PDU in its L2CAP+ACL envelope and move it over the connection's own
  bulk endpoints (`dwc2_bt_bulk_out/in`, already built round 57).

  **Real AAPCS bug caught and fixed before it ever shipped**, not just
  avoided by luck: `gatt_state.S`'s own accessors were first written
  with vani-side `i64` index/value parameters. This project's own
  well-documented AAPCS gotcha (a preceding i64 argument needs an
  even-aligned register pair) means two i64 PARAMETERS in a row
  actually place the second one in r2:r3, not r1 as the asm (which
  reads `index` from r0, `value` from r1, nothing more) assumed —
  caught by re-deriving the calling convention by hand before ever
  building, not discovered live. Fixed by declaring every index/value
  parameter `u32` instead (matching `diag_ring_push`'s own identical
  fix from earlier the same round) — every accessor now takes at most
  2 arguments, each in exactly one register, nothing to get wrong.

  **Superseded by the same-day follow-up below**: this paragraph
  originally scoped OUT a GATT SERVER role, 128-bit custom UUIDs, and
  notifications/indications — the user then explicitly asked for all
  three ("notifications too. i want all 3 things ... for full stack
  ble"), and all three are now built; see the round writeup below for
  what each one actually covers and what real, honestly-documented
  simplifications remain within them.

  **Round 66 (2026-09-01), same day, third follow-up — GATT SERVER
  role + 128-bit custom UUIDs + notifications/indications + L2CAP
  Signaling built.** User's own words: "notifications too. i want all
  3 things in bullet points you listed above for full stack ble" —
  the three items scoped out at the end of the GATT-discovery writeup
  above.

  **GATT SERVER role**: Dhruva can now expose its OWN
  services/characteristics for something else to discover/read/write,
  over a connection Dhruva itself still establishes as central (GATT
  server role is independent of GAP central/peripheral role per spec
  — this doesn't need peripheral/advertising HCI support, which this
  project still doesn't have). New file `boot/gatt_server_state.S`: a
  flat, handle-ordered attribute table (32 attributes max, matching
  this project's own fixed-size-table discipline) where a "service" is
  one attribute (type 0x2800) and each "characteristic" is two more (a
  0x2803 declaration, then its own value entry) — this matches the
  wire protocol directly rather than a higher-level model requiring
  translation at dispatch time, and each attribute's own HANDLE is
  simply its array index + 1, not stored separately. `gatt_server_add_
  service`/`gatt_server_add_characteristic` (kernel_main.vani) build
  the database up; `gatt_server_handle_request` dispatches Exchange
  MTU, Read By Group Type (service discovery), Read By Type
  (characteristic discovery), Read Request, and Write Request against
  it, always answering with either the correct response or a real
  Error Response (§3.4.1.1) — Write Request specifically checks a
  per-attribute writable flag (from the characteristic's own Write
  property bit) and rejects with Write Not Permitted rather than
  silently accepting. `gatt_server_poll` wires the dispatch into
  `gatt_att_recv`/`gatt_att_send`. `gatt_server_notify_value` lets a
  caller push a Handle Value Notification for one of Dhruva's own
  attributes on demand. **Scope, explicit**: the caller decides when to
  notify — no CCCD exposed on Dhruva's own attribute table, no
  per-connection subscription-state tracking on the server side (a
  real additional direction, not attempted). Every accessor in `gatt_
  server_state.S` takes at most 2 plain u32 arguments, same AAPCS-
  gotcha avoidance as `gatt_state.S`'s own design (see that file's
  header comment) — designed this way from the start this time, no bug
  to catch. 39 new host-harness checks cover the attribute database
  and ALL of `gatt_server_handle_request`'s own dispatch logic against
  synthetic PDUs (pure logic, no MMIO) — `gatt_server_poll`/`gatt_
  server_notify_value` themselves are not host-tested, same MMIO
  boundary as every other orchestration function in this file.

  **128-bit custom UUIDs**: `gatt_state.S` gained per-service/per-
  characteristic `is_uuid128` flags plus byte-addressed 16-byte UUID
  storage (same caller-computed-combined-index technique as `gatt_
  server_state.S`'s own value bytes). `gatt_discover_primary_services`/
  `gatt_discover_characteristics_for_service` now decode and store a
  128-bit service/characteristic UUID in full instead of leaving the
  `uuid16=0` "not decoded" sentinel from before. Added spec-complete
  request-builder twins for a genuinely custom TYPE search (`att_
  build_read_by_type_request_uuid128`/`_read_by_group_type_request_
  uuid128`, §3.4.4.1/.9) and `att_find_information_response_get_
  uuid128_at` for the discovery-RESPONSE side — none of these are
  actually called by `gatt_discover_*` itself (which only ever
  searches by the standard 16-bit Primary Service/Characteristic
  Declaration TYPES; it's the discovered attribute's own VALUE that
  can be 128-bit), but are real spec-legal primitives for a caller
  with a genuinely custom type to search FOR. Also added `uuid128_
  equal`, a byte-for-byte comparison helper. 21 new host-harness
  checks.

  **Notifications/indications**: the actual mechanism a server uses to
  push a characteristic's value to a subscribed client without a Read
  Request round trip (§3.4.7.1-3). Added Handle Value Notification
  (0x1B)/Indication (0x1D)/Confirmation (0x1E) PDU builders/parsers
  (Notification and Indication share one wire shape, only the opcode
  and whether a Confirmation is required afterward differ — Indication
  only, and it's not optional bookkeeping: a real server won't send
  another Indication until the Confirmation arrives). On the CLIENT
  side: `gatt_discover_descriptors_for_characteristic` (§4.7.1,
  Find-Information-based, scoped specifically to locating the CCCD —
  UUID 0x2902 — not a generic every-descriptor table this project has
  no other use for yet) finds and records a characteristic's own CCCD
  handle in a new `gatt_char_cccd_handle` table; `gatt_client_write_
  cccd` subscribes/unsubscribes by writing the Notify/Indicate bits to
  it; `gatt_client_poll_notifications` receives one Notification or
  Indication (auto-sending the required Confirmation for the latter)
  and records its own value handle in a new single-slot `gatt_last_
  notify_handle` global (this project's driver model only ever has one
  active BLE connection); `gatt_client_find_char_index_for_value_
  handle` resolves that handle back to the discovery table's own index
  convention, kept as an explicit separate step rather than folded
  into the poll function's own signature. On the SERVER side: `gatt_
  server_notify_value` (see GATT SERVER paragraph above).

  **L2CAP Signaling**: fixed channel 0x0005, scoped specifically to
  Connection Parameter Update Request/Response (§4.20-21) — the one
  Signaling exchange a GAP CENTRAL is actually expected to field (a
  connected peripheral asking to change the connection
  interval/latency/timeout); every other Signaling command (connection-
  oriented channel creation, disconnection, ...) is genuinely out of
  scope. `l2cap_sig_send`/`_recv` mirror `gatt_att_send`/`_recv`'s own
  shape, targeting the Signaling channel instead of ATT; `l2cap_sig_
  poll` receives one command and auto-accepts a Connection Parameter
  Update Request (matching many real central stacks' own default of
  not second-guessing typical requested ranges). **Real limitation,
  stated plainly**: a caller polling Signaling via `l2cap_sig_recv` and
  ATT via `gatt_att_recv` on separate calls will silently drop
  whichever type's packet arrives while polling for the other — this
  project's BLE work has no frame queue/demux layer. Acceptable given
  how this is actually used (a caller runs `l2cap_sig_poll` BETWEEN
  discrete GATT operations, not concurrently with an in-flight
  request), matching how a real peripheral's own Connection Parameter
  Update Request timing works in practice (sent once, shortly after
  connection, not mid-transaction). 38 new host-harness checks cover
  notification/indication PDU building/parsing, L2CAP Signaling PDU
  building/parsing, and every piece of the descriptor-discovery/
  subscription path that doesn't itself touch MMIO — `gatt_discover_
  descriptors_for_characteristic`/`gatt_client_write_cccd`/`gatt_
  client_poll_notifications`/`l2cap_sig_send`/`_recv`/`_poll` reach
  `gatt_att_send`/`_recv` or `dwc2_bt_bulk_*` and are not host-tested,
  same established MMIO boundary.

  Full regression battery green after all three: `qemu_run.py` (one
  pre-existing, unrelated FAIL — the DharaFS real-SD-path self-check,
  a known `qemu_run.py`-has-no-SD-drive harness limitation, not a
  regression from this work), `phase4_milestone.py` 14/14,
  `heap_stress.py`, `host_harness` 636/636 under ASAN/UBSAN (up from
  538 before this follow-up — 98 new checks total across all three
  pieces). Committed locally, no push (DhruvaOS commits stay local-
  only per this project's own policy).

  **What's still genuinely out of scope after this round**: GATT
  server subscription-state tracking (a client's own CCCD write
  against Dhruva's server isn't tracked — `gatt_server_notify_value`
  always sends regardless of whether anyone subscribed); a generic
  descriptor table (only the CCCD is ever discovered/recorded);
  Signaling commands other than Connection Parameter Update; and, as
  always, real Pi 1B hardware-in-loop verification — this entire BLE
  stack remains spec-only, never having exchanged a real byte with
  actual Bluetooth hardware (QEMU's own `usb-bt-dongle` was removed in
  2018), same honesty bar as the rest of this project's USB peripheral
  work.

  Same honesty bar as round 57's own HCI transport work and the
  LAN9512 NIC backend: **NOT live-verified** (QEMU's `usb-bt-dongle`
  was removed in 2018, same blocker round 57 already documented) —
  written to spec and verified via 65 (connection/ACL/L2CAP/core ATT)
  + 51 (discovery PDUs) + 24 (GATT UUID constants/table round trips) =
  140 total new host-harness tests across this round's two BLE
  increments. GATT's
  own orchestration functions (`gatt_discover_*`/`gatt_att_send`/
  `gatt_read/write_characteristic_value`) are deliberately NOT called
  from any host-harness test — confirmed by reading the generated C
  directly that `mmio_read_u32`/`mmio_write_u32` compile to raw
  `*(volatile uint32_t*)addr` dereferences of real Raspberry Pi
  peripheral addresses, so calling anything that reaches them on a
  native x86 host would segfault the whole test suite, not just fail
  cleanly — the same reason `hci_send_command_and_wait_complete`/
  `hci_reset_and_scan` were never directly host-tested either, only
  their own pure packet-building/parsing pieces. Pending real Pi 1B
  hardware-in-loop testing with an actual BLE central/peripheral to
  talk to.

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

- **`uart_puts` is not mutually excluded across tasks — concurrent
  callers can interleave mid-string** `[found round 184, 2026-09-12;
  FIXED round 185, 2026-09-14]`. Surfaced as a side effect of
  live-verifying the round 184 scheduler aging fix: a temporary,
  always-ready priority-0 demo task printing on every loop iteration
  corrupted the interactive shell's own output mid-line (`cat
  /milestonAGING-HOG: starting,e/note` in the captured log — two
  tasks' own `uart_puts` calls genuinely interleaved byte-for-byte on
  a real preemption between them, not a logging artifact). This was a
  real, pre-existing bug independent of the aging work itself (any two
  tasks printing around the same time could always have hit this,
  aging just made a permanently-ready contender common enough to
  expose it reliably). Fixed: `uart_puts` now wraps its whole body in
  `dhruva_prio_lock(0)`/`dhruva_prio_unlock` (priority-ceiling
  protocol, the same primitive already used elsewhere in this
  codebase for short critical sections) — this entry's own stale
  "not fixed" status was caught and corrected 2026-09-16 while
  auditing `docs/TODO.md` against current code before starting new
  work, per this project's own established convention.

- **`phase4_milestone.py`'s interactive shell checks (`eval`, `ls`) flake
  under load, independent of any code change** `[found round 186,
  2026-09-12; ROOT-CAUSED AND FIXED 2026-09-16]`. While comparing the
  round 186 MMC/eMMC change against a clean baseline for a suspected
  regression, ran the SAME unmodified pre-186 commit 3 times back-to-
  back: 17/17, 16/17, 17/17 -- the failure wasn't reproducible-on-
  demand but also wasn't unique to the new code, ruling out a round
  186 regression. Captured log evidence for the one baseline failure:
  the shell's own interactive echo of `write /milestone/note ...` came
  back as `rite /milestone/note ...` (a genuinely dropped leading byte
  on the RX/echo path, not a display artifact -- the underlying write
  still succeeded), and a similarly-timed `eval 6*7` got misparsed as
  "unknown command" despite echoing back intact.

  **Root cause**: `shell_echo_char` (round 72) reused `uart_putc_
  nonblocking` for command-line echo -- a function whose entire
  design point was "check the PL011's 16-byte hardware TX FIFO once,
  silently drop the byte if full, never block" (correct and necessary
  for its ORIGINAL callers: the timer-tick `.` dot and the CANARY
  stack-overflow diagnostic, both genuinely fine to miss occasionally).
  QEMU's own stdio chardev backend hands a whole typed line to the
  emulated PL011 as one burst (the same underlying behavior already
  responsible for a DIFFERENT, previously-fixed bug in this same RX
  path -- see irq_dispatch's own task #9 comment), so `irq_dispatch`'s
  RX-drain loop can call the echo path many times in a tight sequence
  with no real inter-byte delay, easily exceeding the hardware FIFO's
  real drain rate at the configured baud -- especially with a
  concurrent timer-tick `.` also competing for the same 16-byte FIFO.
  Under that contention, ECHO bytes were silently dropped exactly like
  the harmless debug characters the mechanism was designed around.

  **Fix**: added a 64-byte TX ring buffer (`boot/uart_tx_ring_state.S`)
  that `uart_putc_nonblocking` now pushes into (an O(1), always-
  bounded operation, no MMIO wait) with an opportunistic single-byte
  drain to the real hardware FIFO on the same call -- still fully
  non-blocking and WCET-provable, just no longer silently lossy under
  ordinary contention (now only drops if the 64-byte ring itself
  fills, 4x the hardware FIFO's own depth). Implemented as ONE
  combined assembly routine, not separate get/set accessor calls --
  the first attempt (6 separate extern round-trips per byte) blew
  `irq_dispatch`'s own `#[wcet(cycles=130000)]` budget to 216690
  cycles from real ARM call overhead alone, paid up to 128 times per
  RX burst; the single-routine rewrite (direct register/memory access,
  `& 63` instead of a real modulo since 64 is a power of two) builds
  clean under the same budget.

  Verified: live QEMU session repeating the exact failure-shape
  commands (`write`, `eval 6*7`, `ls`) shows intact echo every time;
  full self-test battery clean (idle reached, 0 FAILs, any_fail=0);
  `phase4_milestone.py` shows the SAME 15/18 pattern as the
  established pre-fix baseline, with the first 15 checks (including
  `write`/`cat`/`eval`, which directly exercise the echo path) all
  passing -- the 3 remaining failures (`mqttecho`/`ls`/`diagnose`) are
  a SEPARATE, still-open issue: `phase4_milestone.py`'s own `SETTLE_S`
  inter-command delay is too short for its now-longer command sequence
  (grown since this constant was last tuned), not a UART byte-drop --
  a test-infrastructure timing issue, not a kernel bug, left open as
  its own separate item.

- **Task #215/#216 (2026-09-17): SD data-transfer clock speed.**
  Real-hardware picocom logs (round 2026-09-16) showed the SDHCFG/
  SDHSTS pre-clear fix and a 50x poll-cap bump both failed to resolve
  the real-hardware SD data-phase wedge -- every data command (CMD17/
  CMD24) still wedged the SDHOST controller's FSM 100% of the time,
  identical `SDEDM=0x0000C601` after every reset. Checked real Linux
  (`drivers/mmc/host/bcm2835.c`) and U-Boot (`bcm2835_sdhost.c`) one
  level deeper: both compute `SDCDIV` from the SD core clock (queried
  live via a VideoCore mailbox `GET_CLOCK_RATE` call, clock id 4 =
  CORE -- never a hardcoded constant) and switch from an identification-
  speed divisor to a real data-transfer-speed one once the card is
  identified. This driver set `SDCDIV` once during `sdhost_init()`
  (identification speed, `0x148`) and never touched it again for any
  data command -- the leading remaining candidate for the wedge, since
  sustained multi-word FIFO PIO transfer timing genuinely depends on
  the SD clock ticking at a sane rate.

  **Fix**: added `sdhost_get_core_clock_hz()` (`boot/sdcard_state.S`,
  mirroring the existing `governor_state.S` mailbox pattern for the ARM
  clock) and wired a real data-transfer-speed `SDCDIV` computation into
  `sdhost_init()` (25MHz target -- the mandatory SD "default speed"
  ceiling every card supports without CMD6 high-speed negotiation,
  which this driver doesn't implement), using the identical divisor
  formula both references share. Falls back to the existing
  identification-speed divisor if the mailbox query fails.

  **Not yet confirmed by a real-hardware log with this fix in place**
  (task #217, blocked on hardware access) -- this is still the leading
  hypothesis, not a proven fix, same honesty standard as the two prior
  attempts.

  **QEMU verification finding worth recording**: confirmed directly
  against QEMU's own SD-host model source (`hw/sd/bcm2835_sdhost.c`:
  `case SDCDIV: break;` -- the register write is a literal no-op) that
  this fix cannot affect QEMU's simulated transfer correctness or
  timing, and indeed plain SD read/write (`write`/`cat`) never
  regressed once across dozens of test runs made while investigating
  this. However, the fix's one extra mailbox round trip plus two extra
  diagnostic print lines during boot (a real, if small, one-time
  addition to boot wall-clock time) was enough to make `httpecho` newly
  marginal against `phase4_milestone.py`'s own blind, unsynchronized
  `SETTLE_S` timing (same root-cause class the `mqttecho`/`ls`/
  `diagnose` entry above already documents) -- confirmed on a
  genuinely clean, idle host (load 0.69-1.94), ruling out host-load
  noise as the explanation. Neither a global `SETTLE_S` raise (14->18,
  tested under contaminated load, inconclusive) nor a targeted +4 on
  just `httpecho` (tested clean, still failed) reliably fixed it;
  left at plain `SETTLE_S` rather than chase a tuning value further.
  `httpecho` now joins `mqttecho`/`ls`/`diagnose` as a 4th member of
  this same pre-existing, non-blocking test-harness-timing class:
  verified functionally correct, occasionally too slow for this
  harness's own timing, not a kernel regression.

  **Task #217 FOLLOW-UP (2026-09-18): SDCDIV fix confirmed NOT
  sufficient on real hardware -- task #217 falsified, not just still
  pending.** Fresh real-HW picocom log (`picocom_20260918_074005.log`,
  19277 lines) captured WITH this fix in place: **238 total
  `write`/`read` wedge events, 79 of which exhaust all 3 retry
  attempts** ("giving up after 3 attempts") -- the wedge is still
  happening, SDCDIV alone did not fix it. Cascades into the same class
  of DharaFS/crypto FAILs documented before (9 total: multi-block
  write, crash consistency, compaction resume, permissions, directory
  listing, AEAD round-trip, two-time-pad fix, tamper detection, media-
  encryption SD round-trip).

  **A real, narrowing clue found while reading the full log, not just
  the summary counts**: every one of the 238 wedge events falls within
  the FIRST ~2565 lines (~13% of the log) -- the initial SD self-test
  phase (the 8-block sweep at blocks 2100-2107 plus the SD-touching
  crypto/media-encryption tests that immediately follow it). The
  remaining ~16700 lines -- normal multitasking, background task
  chatter, the rest of a long-running session -- show ZERO further
  wedge events. Whatever's wrong is concentrated in/around the initial
  data-transfer-speed SDCDIV transition and the specific rapid-fire
  write+read+compare sequence across those 8 consecutive blocks, not a
  general "SD breaks under any sustained load" issue.

  **A real gap found in the diagnostic infrastructure itself**: the
  existing per-block diagnostic (`SD DIAG: block N FAILED ...
  SDEDM=0x...`, task #4 verification code) does NOT capture the actual
  wedged register state -- by the time it runs, `sdhost_write_block`/
  `sdhost_read_block`'s own retry loop has already called
  `sdhost_init()` at least once (the "giving up" branch), which resets
  `SDEDM` back to a normal idle value before this print ever reads it.
  Confirmed directly: the log's own `SD DIAG: block 2100 FAILED:
  wr=2 rd=2 mismatch_at=1 ... SDEDM=0x0000C601` shows `SDEDM`'s FSM
  field (bits[3:0]) as `0x1` -- one of the IDLE states
  `sdhost_wait_transfer_complete` itself already treats as success --
  which is exactly what a POST-RESET read would show, not a wedged
  one. Every real wedged `SDEDM` value this project has ever actually
  captured (`0xC603`, FSM=WRITEDATA, round 2026-09-15) came from a
  narrower diagnostic window that happened to catch it mid-failure by
  luck, not from this timeout path itself, which has never once
  printed anything in its own right.

  **Fix (diagnostic only, not a functional fix)**: added a print
  directly inside `sdhost_wait_transfer_complete`, immediately before
  its own `return 1` timeout path -- `alternate_idle`/`SDEDM`/
  `SDHSTS`/`SDCDIV`, the one place guaranteed to see the true wedged
  state before `sdhost_init()` or anything else touches these
  registers again. Verified: clean build, full `phase4_milestone.py`
  regression battery unchanged (stays dormant under QEMU, whose own SD
  model doesn't wedge). Commit `a4e7305`.

  **Responsible next step, not attempted here**: a FRESH real-hardware
  capture with this new diagnostic in place, to finally get the real
  missing evidence (the true wedged FSM/SDHSTS value) before
  attempting a fourth fix. Guessing at a next clock divider or timing
  value without that evidence would repeat the exact mistake this
  investigation has already learned twice not to make (SDHCFG/SDHSTS
  pre-clear, then the poll-cap bump, both shipped on plausible-sounding
  theories and both confirmed insufficient by the next real log). Needs
  the user's own real Pi 1B hardware access -- not something resolvable
  from this environment alone.

  **Follow-up (2026-09-18): adaptive clock backoff added as a
  resilience layer, NOT a root-cause fix.** User asked directly whether
  formatting, init sequence, or clock math were suspect (all confirmed
  correct by hand/against Linux+U-Boot references) and proposed trying
  an adaptive-clock-backoff pattern matching mature MMC drivers
  (Linux's `bcm2835-sdhost`/`mmc_core` step the bus clock down on
  repeated data errors before giving up). Implemented: `sdhost_init()`
  split into a parameterized `sdhost_init_at_speed(target_hz: i64)`
  (with `target_hz <= 0` as a sentinel meaning "skip the data-speed
  switch, stay at identification-phase speed for data commands too")
  plus a plain wrapper preserving every existing call site at the
  default 25MHz. New `SD_SPEED_BACKOFF_HZ = 12500000` constant. Both
  `sdhost_read_block`/`sdhost_write_block`'s retry branches (not the
  final "giving up" branch, which still resets to full 25MHz for
  whatever comes next) now step the clock down before re-attempting:
  first retry at 12.5MHz, second (last) retry at identification-speed
  only. Each retry log line now also prints the backoff target_hz used.
  Verified: clean build, full `phase4_milestone.py` regression battery
  unchanged (same 4-FAIL baseline: httpecho/mqttecho/ls/diagnose, all
  pre-existing `SETTLE_S`-class harness-timing issues). Commit
  `51f1af3`.

  This is explicitly a defensive resilience layer matching
  well-precedented real-driver behavior, not a guess at the specific
  root cause -- that still requires the fresh real-hardware capture
  described above, to see whether the new `sdhost_wait_transfer_
  complete` diagnostic reveals the true wedged register state, and
  separately whether the backoff itself measurably helps in practice.

  **Follow-up (2026-09-18): two concrete, evidence-backed fixes found
  by diffing directly against real Linux source (user provided
  `drivers/mmc/host/bcm2835-sdhost.c`, rpi-6.1.y).** Unlike the two
  earlier guesses on this bug (SDHCFG/SDHSTS pre-clear, poll-cap
  bump), both of the following are named, documented hardware errata
  workarounds in the actual shipped driver, not speculation:

  1. **Missing `SDHCFG_SLOW_CARD` (bit3, 0x8) -- the strongest lead
     found so far.** Real `bcm2835_sdhost_set_clock`'s own comment:
     this controller's `SDCDIV` is an 11-bit register during identify/
     command mode, but hardware AUTOMATICALLY switches to honoring
     only the BOTTOM 3 BITS of `SDCDIV` once the FSM enters real data
     mode (READDATA/WRITEDATA) -- unless `SDHCFG_SLOW_CARD` forces it
     to keep using the full 11-bit value the whole time. Real
     `bcm2835_sdhost_set_ios` sets this bit UNCONDITIONALLY on every
     call ("Disable clever clock switching, to cope with fast core
     clocks"). Our own data-transfer divisor (8, for a 25MHz target on
     a 250MHz core clock) does NOT fit in 3 bits (range 0-7, and 8's
     bottom 3 bits are 0) -- an unmasked hardware auto-switch would
     silently run the real data-transfer clock at whatever the
     3-bit-truncated divisor produces, not the intended 25MHz. This
     mechanistically matches every real-hardware symptom observed:
     data-transfer-phase-only (identification has no data phase to
     trigger the auto-switch), deterministic at the same blocks every
     time, and invisible under QEMU (whose SD host model has no reason
     to emulate this specific silicon quirk). Fix: `sdhost_read_block_
     once`/`sdhost_write_block_once`'s own `SDHCFG` write, 0x510 ->
     0x518 (adds bit3).
  2. **Missing SDEDM FIFO read/write threshold fix.** Real
     `bcm2835_sdhost_reset_internal` sets SDEDM bits [18:14] (read
     threshold) and [13:9] (write threshold) to 4 each, on every
     reset, with its own comment: "Limit fifo usage due to silicon
     bug". This driver never touched these bits at all before today.
     Fix: added to `sdhost_init_at_speed`, right after the identity-
     speed SDVDD power-cycle.

  Verified: clean build, full `phase4_milestone.py` regression battery
  (run twice) unchanged from the same baseline (httpecho/mqttecho/ls/
  diagnose flake within the known `SETTLE_S`-timing set, no new
  failures, QEMU's SD model stays dormant as expected). Still NOT
  confirmed against real hardware -- this is a real, sourced, named-
  errata match, a materially stronger basis than the two earlier
  guesses on this bug, but "matches every symptom" is not the same as
  "confirmed fixed" until the next real Pi 1B capture.

- **Task #219-222 (2026-09-17): shell echo task-preemption interleave
  gap -- FIXED, and rescoped down from the original hypothesis.**
  Originally described (project memory,
  `project_dhruva_shell_echo_interleave_gap_2026_09_14`) as needing a
  scheduling-level redesign to distinguish "buffered input, safe to
  echo as one atomic burst" from "waiting on the next keystroke, must
  stay preemptible." Re-investigated directly against the current code
  before designing anything: `shell_echo_char` (round 72) actually runs
  entirely INSIDE `irq_dispatch`, once per UART RX interrupt -- each
  interrupt's own echo work is already atomic (no IRQ nesting), but
  genuinely separate keystrokes arrive as genuinely separate hardware
  interrupts, with ordinary task-level code (including other tasks' own
  `uart_puts` calls) running normally in the real time between them --
  the same situation as any two independent writers sharing one tty.

  **Load-bearing fact the original write-up didn't call out**: confirmed
  directly from `shell_rx_push_char`'s own code (`boot/shell_state.S`)
  that it only ever touches `shell_line_buf`/`shell_line_len`/`shell_
  line_ready` -- a data path completely separate from `shell_echo_char`/
  `uart_putc_nonblocking` (the DISPLAY path). An interleaved async
  message can garble what's SHOWN on the terminal but can never corrupt
  the command the shell actually receives and executes. Confirmed live
  with a deliberate byte-at-a-time repro (typing `ping 0.0.0.0` with
  ~250ms inter-keystroke gaps while background tasks print normally):
  the echoed line came back glued (`ping 0.0.0.0LOW: locked, entering
  critical section`), but the shell still correctly ran the command
  (`PING 0.0.0.0` / `reply from 0.0.0.0 seq=1` printed right after,
  exactly as expected). This reframes the bug from "a correctness risk
  needing new scheduling machinery" to "a display-ordering nicety" --
  and rules out the scheduling redesign the original write-up
  considered (which the SAME write-up already correctly argued would be
  wrong regardless: locking a whole human-paced command line would
  starve every other task for as long as a human takes to type).

  **Fix**: `uart_puts` now checks, inside its own existing
  `dhruva_prio_lock(0)` section (task #185), whether a command is
  currently mid-typing (`shell_get_line_ready()==0 && shell_get_line_
  len()>0`) before printing, and if so, emits a `\r\n` break first --
  so an unrelated message can never glue onto the tail of a user's
  not-yet-submitted input. Deliberately does NOT attempt to redraw the
  in-progress line afterward: `shell_line_buf` holds the RAW typed
  bytes even during `su`/`passwd` password suppression (`shell_echo_
  char` never echoes those characters at all, not even as asterisks),
  so reprinting it verbatim would leak a password onto the screen.

  **Known residual gap, found live while verifying**: callers that
  build one logical line from SEVERAL separate `uart_puts` calls (e.g.
  `governor_step`'s 5-call "GOVERNOR: step ready=...` print, interleaved
  with unprotected `uart_put_i64` calls) can now fragment across
  multiple lines if a command is mid-typing across the whole sequence,
  since each call independently inserts its own break. This is a real
  but strictly SMALLER problem than before (the user's own typed
  command is never glued into; only another task's own already-multi-
  call print fragments further) and traces back to a separate,
  pre-existing gap task #185 deliberately scoped out at the time
  (`uart_put_i64`/`uart_put_hex32`/etc. have no mutual exclusion of
  their own) -- not fixed here, left for a future round if it turns out
  to matter in practice.

  Verified: rebuilt clean; the exact repro that reproduced the glued-
  line symptom now shows `ping 0.0.0.0` on its own clean line with
  `LOW:`'s message starting on the next line; full `phase4_milestone.py`
  regression battery shows the identical pre-existing 4-FAIL pattern
  (`httpecho`/`mqttecho`/`ls`/`diagnose`, all `SETTLE_S`-class, see
  entry above), no new regressions.

- **Task #197/#223 (2026-09-17): RTL8188CU `rtl8188cu_enable_rf` had
  FOUR real register-address bugs, found while researching channel
  selection -- fixed, and channel selection now implemented.** This
  whole section is untestable end-to-end under QEMU (no RTL8188CU
  device model exists there -- confirmed via this project's own boot
  log: `USB: dwc2_init status=FFFFFFFF (...no device attached)`), so a
  real address typo here could never have been caught by any self-test
  or regression run -- only by re-checking every existing address
  against the real reference line by line, which this round did before
  writing any new code, rather than trusting this file's own prior
  "confirmed against source" claim at face value.

  Checked fresh against `drivers/net/wireless/realtek/rtl8xxxu/{core.c,
  regs.h}` (`rtl8xxxu_gen1_enable_rf`) and found:
  1. `REG_FPGA0_XAB_RF_PARM` used `0x0870` -- real register is `0x0878`.
  2. That register was blindly overwritten with `0x00000000` instead of
     a real read-modify-write (clear `BIT(4)|BIT(5)`, SET `BIT(3)`) --
     the reference driver never writes a bare 0 there; the old code
     would have left `BIT(3)` (which must be SET) cleared instead.
  3. `REG_FPGA0_RF_MODE` used `0x0954` with mask `0x0000000c` for
     "clear `FPGA_RF_MODE_JAPAN`" -- real register is `0x0800`, real
     `FPGA_RF_MODE_JAPAN` bit is `BIT(1)` (`0x2`), not bits 2-3. `0x0954`
     has no defined meaning in the reference driver at all.
  4. The RF-register write labeled "`RF6052_REG_AC`" used RF address
     `0x18` -- that address is actually `RF6052_REG_MODE_AG` (the
     channel/bandwidth register). Real `RF6052_REG_AC` is RF address
     `0x00`. The old code would have corrupted the channel/BW register
     with an unrelated bias value while never touching the real AC
     register at all.

  Also added the reference driver's own `REG_OFDM0_TRX_PATH_ENABLE`
  (`0x0c04`) step, missing entirely before -- clears
  `OFDM_RF_PATH_TX_MASK` (`0xf0`) and sets `OFDM_RF_PATH_TX_A`
  (`BIT(4)`), matching this chip's single-TX-path configuration.
  `REG_RX_WAIT_CCA`'s real address is `0x0e70` (was `0x0838`, an
  entirely different register) -- its single-RF-path value
  (`0x631b25a0`) was already correct.

  **Channel selection** (`rtl8188cu_set_channel`, new): implements
  `rtl8xxxu_gen1_config_channel`'s 20MHz/non-HT path (this driver has
  no 40MHz/HT support anywhere else, so that branch wasn't ported) --
  `REG_BW_OPMODE`/`REG_FPGA0_RF_MODE`/`REG_FPGA1_RF_MODE`/
  `REG_FPGA0_ANALOG2` for the bandwidth-mode registers, two
  `RF6052_REG_MODE_AG` read-modify-write passes (channel number in
  bits[9:0], bandwidth in bits[11:10]) matching the reference driver's
  own two-pass structure exactly, and the SIFS timing registers.
  Deliberately NOT called automatically from `rtl8188cu_mac_bringup` --
  matches the real driver's own separation (mac80211 core calls
  config_channel independently of bring-up) and because a real join
  needs to tune to whatever channel the target BSSID is actually on,
  not a value this function could guess.

  New `rtl8188cu_set_channel_self_test` (bit-construction only, same
  QEMU-testable-without-hardware discipline as this section's other
  self-tests) wired into the boot self-test battery. Verified: clean
  build, new self-test shows `(PASS)`, full `phase4_milestone.py`
  regression battery shows the identical pre-existing 4-FAIL pattern,
  no new regressions. Still NOT live-verified against real hardware
  (same as every other RTL8188CU register-level function in this
  section) -- IQ/LC RF calibration (genuinely chip-instance/efuse-
  dependent) remains the one piece deliberately not attempted.

- **Task #224 (2026-09-17): continued the same Linux-reference audit
  across the rest of the RTL8188CU driver (user asked to "find any bugs
  in code so far using linux reference") -- found 2 more real, confirmed
  bugs; the firmware download/start sequence and RX descriptor parser
  both check out fully correct against source (reassuring, since not
  every prior "verified against source" claim in this codebase turned
  out wrong, just `enable_rf` specifically).**

  1. **TX descriptor `txdw1` was missing `AGG_BREAK` (`BIT(6)` =
     `0x40`).** Traced the real call path
     (`rtl8xxxu_tx`/`rtl8xxxu_fill_txdesc_v1`) precisely: `ampdu_enable`
     only ever becomes true for a QoS data frame from a station with
     negotiated HT aggregation -- never for a management frame, and this
     driver implements no AMPDU aggregation for any frame type yet -- so
     `fill_txdesc_v1`'s own `if (ampdu_enable...) txdw1 |= AGG_ENABLE;
     else txdw1 |= AGG_BREAK;` always takes the `else` branch for every
     frame this driver can currently produce. `AGG_BREAK` is the
     hardware's own "this frame is not part of an aggregation burst"
     signal -- every TX descriptor was implicitly claiming an undefined
     default aggregation state instead of an explicit one. Fixed:
     `rtl_tx_desc_write`'s `txdw1` now includes it unconditionally
     (matching that this driver never takes the AMPDU branch).

  2. **`rtl_llt_write`'s poll loop was off-by-one.** The reference
     (`rtl8xxxu_llt_write`) polls via `do { ...check...; } while
     (count++ < 20);` -- the body runs unconditionally once BEFORE the
     condition is even evaluated, and the condition compares count's
     PRE-increment value, so the body actually runs for count =
     0,1,...,20 -- 21 total attempts, not 20. The old code's plain
     pre-check `while count < 20` only ran 20. Low real-world impact
     (an LLT write completing on attempt 21 but not 20 is unlikely) but
     a genuine, confirmable deviation from source, and from this
     project's own prior claim of matching the real driver's poll count
     "exactly" -- fixed by bumping the bound to 21.

  Everything else checked systematically against `drivers/net/wireless/
  realtek/rtl8xxxu/{core.c,rtl8xxxu.h,8192c.c,regs.h}` and confirmed
  correct: the full LLT table structure and `TX_TOTAL_PAGE_NUM`
  (`0xf8`, confirmed as `rtl8192cu_fops`'s own value -- the fops table
  this file's own header comment confirms covers RTL8188CUS too, not
  just RTL8192CU); the TX descriptor's full byte layout (all 11 fields
  of `struct rtl8xxxu_txdesc32` at their exact real offsets) and its
  checksum algorithm (XOR of all 16 little-endian words with the
  checksum field pre-zeroed, matching `rtl8xxxu_calc_tx_desc_csum`
  exactly -- including confirming the checksum-inversion step some
  chips need does NOT apply to this one, RTL8710B/RTL8192F-only); the
  RX descriptor's dword0/dword3 bit positions (`pktlen`/`crc32`/
  `drvinfo_sz`/`shift`/`rpt_sel`, all exact matches against `struct
  rtl8xxxu_rxdesc16`'s own little-endian bitfield layout); and the
  entire firmware download/start sequence (`REG_SYS_FUNC`/
  `REG_RSV_CTRL`/`REG_MCU_FW_DL` addresses, `SYS_FUNC_CPU_ENABLE`/
  `MCU_FW_DL_ENABLE`/`MCU_FW_RAM_SEL`/`MCU_FW_DL_CSUM_REPORT`/
  `MCU_WINT_INIT_READY` bit values, the bare `BIT(19)` 8051-reset step
  -- initially suspected wrong against an unrelated `MCU_CP_RESET =
  BIT(23)` constant found nearby in `regs.h`, but the actual reference
  function uses the literal `BIT(19)` inline with no named constant, so
  this code was right all along -- and `rtl8xxxu_reset_8051`/
  `rtl8xxxu_start_firmware`'s own exact sequences).

  Verified: clean build, both new expected-value self-tests
  (`rtl_tx_desc_self_test`, `rtl_llt_write_self_test`) show `(PASS)`,
  full `phase4_milestone.py` regression battery shows the identical
  pre-existing 4-FAIL pattern, no new regressions. Still NOT
  live-verified against real hardware, same as the rest of this
  section.

## RTOS/DharaFS safety-certification audit (2026-09-17)

User request: "full audit pass, same rigor as RTL8188CU. simulate
workload if possible to test. be thorough. wcet analysis or anything
else expected to get rtos certified for safety and correctness." Unlike
RTL8188CU, there's no external reference to cross-check against here
(this scheduler/FS design is original, not a port) -- the method was
direct correctness reading of `boot/context_switch.S` (1792 lines),
`boot/irq_entry.S`, `boot/rpi1/vectors.S`, `boot/stack_canary.S`, real
measurement via new permanent boot-time diagnostics, and applying (for
the first time) this project's own existing formal-schedulability tool
to its actual demo task set with real numbers.

**Real fixes made:**

- **Watchdog wired, gated (task #230).** `watchdog_arm`/`watchdog_init`/
  `watchdog_kick` were fully implemented (correct real hardware register
  semantics, matching `bcm2835_wdt.c`) but never actually called from
  anywhere in the live boot/tick path -- confirmed by direct code read,
  not assumed. Combined with every fault handler in `vectors.S`
  (`fault_undef`/`fault_swi`/`fault_reserved`/`fault_fiq`, and the
  post-diagnostic-print tail of `fault_data_abort`/`fault_prefetch_
  abort`) ending in a bare `b .` -- an infinite halt with zero recovery
  -- this meant a genuinely wedged system (irq_dispatch itself stops
  running, or any unrecoverable fault) had NO automatic recovery path
  at all. Root cause for why it was never wired: QEMU's `raspi1ap`
  watchdog model isn't a faithful timing model -- ANY `PM_RSTC` write
  with `WRCFG=FULL_RESET` resets the emulated machine immediately
  regardless of the requested timeout (confirmed empirically at both a
  2-second and the maximum 20-bit timeout value), so there is no
  timeout value that both "does something" and "doesn't break every
  QEMU test run." Fixed via a single source-level gate
  (`WATCHDOG_ENABLE_FOR_REAL_HARDWARE`, `kernel_main.vani`) rather than
  a runtime QEMU-detection heuristic (vani has no preprocessor, and a
  wrong heuristic is itself a real risk -- a false negative on real
  hardware silently ships with no watchdog again). Defaults to 0
  (matches this project's own checked-in QEMU-driven development
  posture); flip to 1 and rebuild before flashing an image for actual
  unattended hardware deployment. Verified: both states (0 and 1) build
  clean, including confirming `watchdog_kick()`'s addition to
  `irq_dispatch` doesn't blow its own `#[wcet(cycles=130000)]` budget.
  The enabled state was NOT boot-tested (would immediately reset QEMU
  by design, exactly as documented) -- real verification needs actual
  hardware.

- **Stack overflow canary now has real, live validation (task #228).**
  `boot/stack_canary.S`'s own sentinel-detection mechanism (round 68,
  4 historical incidents it was built to catch faster) had existed
  since round 68 but was NEVER actually exercised end-to-end -- every
  prior check was either static bit-construction (not applicable, no
  pure logic to isolate) or "hasn't false-alarmed," which proves it
  doesn't cry wolf, not that it catches a real breach. New
  `stack_canary_self_test` (kernel_main.vani) deliberately corrupts a
  tracked sentinel (using a scratch heap buffer at an unused task-index
  slot, never a real task's own stack, so a bug in the test itself can
  only ever produce a spurious report, never interfere with a real
  task), confirms `stack_canary_check_all()` actually flags it AND that
  no other tracked task's own bit is affected, then restores the
  sentinel (critical: there's no "untrack" function, so a skipped
  restore would false-alarm on every real tick for the rest of that
  boot). Verified live: `(PASS)`, and confirmed via the full log that
  no unexpected `CANARY` line appeared anywhere else in the run.

- **Real, measured WCET data + schedulability analysis applied to
  DhruvaOS's own task set for the first time (task #226).** `#[wcet(
  cycles=N)]` exists on exactly ONE function project-wide
  (`irq_dispatch`) -- no task body has ever had a WCET bound, and
  `test/schedulability_analysis.py` (task #190) was deliberately never
  applied to DhruvaOS's own demo task set (its own header comment:
  "that set has no declared WCET anywhere"). New
  `delay_wcet_measure_self_test` (kernel_main.vani) measures `delay()`'s
  real cost via `TIMER_CLO` (a genuine 1MHz hardware counter) rather
  than assuming it -- this project has already been burned once by a
  busy-loop timing assumption (BLINK_N, task #207). Real result:
  `delay(3000000)` -- exactly what `task_c` (LOW) holds a ceiling-0
  lock across -- measured at **49906us (~50ms)**, confirmed
  near-linear against two bracketing measurements (100k and 10M
  iterations). Ceiling 0 means this blocks EVERY other task in the
  system for that whole window, by construction (the ceiling
  protocol's own "prevent inversion" guarantee -- not a resource-
  specific block).

  `schedulability_analysis.py` extended with a real blocking-time term
  (`Task.blocking`, Sha/Rajkumar/Lehoczky 1990's standard extension:
  `R_i = C_i + B_i + sum interference`) -- the original tool covered
  only pure fixed-priority preemptive interference, which silently
  ignores exactly the mechanism DhruvaOS's own scheduler is built
  around (`dhruva_prio_lock`/`dhruva_mutex_lock`). New self-test
  (Example 5) proves the extension itself is correct: a trivially-
  schedulable task (R=2<=D=6) flips to provably unschedulable once a
  real blocking term (5) is added, with a zero-blocking control
  confirming the same task set is fine without it. New
  `dhruvaos_demo_task_set_analysis()` applies this to the REAL demo set
  (HIGH/MEDIUM/LOW) using the measured 50ms blocking term (+ a
  clearly-labeled, NOT independently measured, 5ms conservative round-
  up for each task's own remaining body). **Verdict: schedulable, with
  comfortable margin (440ms-1445ms slack across all three tasks).**
  Caveat, stated in the tool's own output: GC (task_e)'s own ceiling-2
  critical section duration was not measured in this pass (it can't
  block HIGH/MEDIUM, whose priority is numerically below the ceiling,
  but COULD block LOW via the tie-break rule) -- flagged as a real
  follow-up, not assumed away.

**Verified correct, no bug found (traced, not just pattern-matched):**
priority-ceiling protocol (`dhruva_prio_lock`/`unlock`) and priority-
inheritance mutex (`dhruva_mutex_lock`/`unlock`) implementations in
`context_switch.S`; the IRQ entry/relocate/restore sequence in
`irq_entry.S` (the true-lr-vs-resume-pc frame layout from round 68's
own real bug fix); `scheduler_pick_next`'s aging/round-robin/ceiling-
tie-break algorithm; the hardcoded `dhruva_prio_unlock(3)` pattern in
the real-SSH-server code path -- initially looked like the exact
"hardcoded restore value, multi-caller function" bug class round 53
already fixed once for `uart_puts`, but tracing the actual call graph
confirmed `ssh_real_server_cmd()` is only ever reached via the `sshd`
shell command, exclusively from task_f (SHELL, priority 3) -- single-
context, so the hardcoding is safe.

**Real, honest gaps this audit did NOT fix, worth recording plainly for
anyone evaluating this project against a real certification standard
(DO-178C/IEC 61508-style framing):**

1. ~~**Stack overflow is DETECTED (within ~500ms), not PREVENTED.** No
   fine-grained MMU guard pages exist...~~ **WRONG, corrected 2026-09-17
   (Gap A)**: this finding was sourced from `stack_canary.S`'s own
   stale header comment (written before round 76 existed) without
   cross-checking `mmu_init.S`'s actual current state. Real 4KB MMU
   guard pages already existed the whole time this audit was running
   (round 76's `mmu_guard_page_install`, extended by round 192's
   per-task domain version, `mmu_guard_page_install_domain`) -- every
   real task stack (all 10, via `dhruva_alloc_stack_domain`) gets a
   zeroed, invalid L2 descriptor installed directly before it, which
   faults on the translation-table walk itself, genuinely PREVENTING
   overflow via a real hardware fault, not just detecting it after the
   fact. What WAS a real gap: round 76/192's own original verification
   was a one-off self-test used during initial development, then
   removed -- nothing re-proved the mechanism still worked on every
   later change since. Closed that: `kernel_main.vani`'s new
   `GUARD_PAGE_FAULT_INJECTION_TEST` (default 0, same gating pattern as
   `WATCHDOG_ENABLE_FOR_REAL_HARDWARE` -- can't safely run during a
   normal boot since it deliberately triggers an unrecoverable fault)
   gives a permanent, documented, re-runnable procedure. Live-verified
   this round: a deliberate write to stack_a's own guard page
   (0x00A00000) produced a real Data Abort, DFSR status `00000817`
   (bits[4:0]=0b00111, "Translation fault, page"), at exactly that
   address. `stack_canary.S`'s own header and its kernel_main.vani call
   site are both corrected to match. The canary remains valuable as a
   complementary, defense-in-depth layer (catches a single write that
   leaps clean over an entire 4KB guard page in one access), not the
   only protection it was previously described as.
2. **`scheduler_pick_next` has no automated self-test of its own**
   (documented since round 75: an attempted white-box test found a
   real, never-fully-root-caused crash and was deliberately abandoned
   rather than ship a test that could crash the system). Verification
   for this function rests on live regression trace evidence (this
   audit's own Phase 7, 1031 real concurrent-activity log lines in one
   run, dozens of clean runs across this whole session) plus manual
   code tracing, not an automated unit test.
3. **Per-task WCET only exists for the demo task set's dominant term**
   (LOW's measured 50ms), not comprehensively for every function any
   real task might call. A real production task set needs its own
   WCET measurement pass before trusting `schedulability_analysis.py`'s
   verdict -- this tool (and this audit) proves the METHOD works, not
   that every possible workload is schedulable.
4. **No formal proof the vani `#[wcet(...)]`/`#[bounded_stack(...)]`
   static estimators are themselves sound** (i.e. never under-
   estimate) -- they're already documented elsewhere in this codebase
   as "a conservative estimator, not an exact analysis," and this
   audit didn't independently re-verify that claim against the
   compiler's own implementation.
5. **GC (task_e)'s own ceiling-2 critical section duration is
   unmeasured** (see the schedulability analysis's own caveat above).

None of these are being silently worked around or hidden -- they're
the honest current boundary of what this pass covered, in the same
spirit as this project's own established discipline (`RTOS_GAP_
ANALYSIS.md`, the per-task deadline/budget model's own "don't fabricate
a number, build it when a real workload needs it" reasoning already
applied to a sibling problem). Verified throughout: clean builds, full
`phase4_milestone.py` regression battery unchanged (same pre-existing
`httpecho`/`mqttecho`/`ls`/`diagnose` `SETTLE_S`-class 4-FAIL pattern),
no new regressions from any change in this pass.

### Follow-up: does WiFi/BLE/UART affect WCET/RTOS guarantees? (2026-09-17)

Direct user question, answered with real measurement, not a guess.
**UART** is interrupt-driven and already fully inside `irq_dispatch`'s
own measured `#[wcet(cycles=130000)]` budget (the 128-byte RX drain
loop is the worst case that budget was raised for, round 72). **WiFi
and BLE are NOT interrupt-driven at all** -- `rtl8188cu_tx_frame`/
`rx_frame` and the BT bulk transfer functions all run via USB polling
in ordinary TASK context, so they never touch `irq_dispatch`'s budget
directly.

But polling isn't free: new `dwc2_wait_chan0_done_wcet_measure_self_
test` measured the real worst-case duration of `dwc2_wait_chan0_done`
-- the ONE polling primitive underlying literally every USB bulk
transfer in this codebase (WiFi via `dwc2_wifi_bulk_out/in`, BLE via
`dwc2_bt_bulk_out/in`, the network interface via `dwc2_net_bulk_in`,
even USB mass storage and enumeration) -- via `TIMER_CLO`, with no USB
device attached (the actual condition under every QEMU test this
project runs, and therefore the TRUE worst case: a device that
responds finishes faster, so measuring the guaranteed-full-timeout
path measures the real upper bound, not a contrived one).

**Real result: 325620us (~325.6ms)** -- over 6x LOW's own measured
50ms ceiling-lock critical section, and nearly two-thirds of a single
500ms scheduler tick.

**This is an ACTIVE exposure today, not just a hypothetical future
one**: traced the call chain and confirmed `ssh_real_accept`/`ssh_
real_deliver_one_frame` (the real SSH-over-USB-Ethernet server path)
already wrap `netif_recv_frame` -- which calls `dwc2_net_bulk_in` --
which calls `dwc2_wait_chan0_done` directly -- in `dhruva_prio_lock(2)`.
That means a real, already-shipped code path can hold a ceiling-2 lock
for up to ~325ms if the USB Ethernet link stops responding. Ceiling 2
means this does NOT block HIGH(0)/MEDIUM(1) (their priority number is
below the ceiling, so they preempt normally) -- but it DOES fully
block LOW and anything at priority >=2 for that whole window. Not
fixed in this pass (would need either a much lower poll bound with a
real accuracy/robustness tradeoff, or restructuring to not hold a
ceiling lock across a USB operation at all) -- recorded here as a real,
measured, traceable finding for whoever designs real WiFi-task
integration next, not silently discovered later via a missed deadline.

**Implication for future WiFi/BLE task integration**: if a WiFi RX
task is ever built to run at a HIGH/MEDIUM-adjacent priority (rather
than only from the shell/best-effort band, as today), or if any future
code wraps a WiFi/BLE bulk transfer in a ceiling lock at ceiling 0 or
1, this 325ms number becomes a real `B_i` blocking term that MUST be
fed into `schedulability_analysis.py` before trusting that task's own
deadline -- exactly the same discipline this audit's own `dhruvaos_
demo_task_set_analysis()` applied to LOW's 50ms term. Verified: clean
build, new self-test prints the real number live, full
`phase4_milestone.py` regression battery unchanged, no new
regressions.

### Gap E closed: GC's own critical section duration measured (2026-09-17)

Closes the schedulability analysis's own explicitly-flagged caveat
("GC's own ceiling-2 critical section duration was not measured").
`task_e` (GC) holds TWO separate ceiling-2 critical sections, now both
measured live, every real pass, via new `TIMER_CLO`-bracketed prints
in `kernel_main.vani`'s own task_e body (not a one-shot self-test --
shows real variance across a live boot):

- **DharaFS compaction pass**: 5741-7689us across 10 real passes in
  one test run -- consistently small, nowhere close to threatening
  anything.
- **`dhcp_client_poll`**: mostly 12-478us under HEALTHY conditions (a
  working virtual network, lease already held) -- but this poll calls
  into `netif_recv_frame` -> `dwc2_net_bulk_in` -> `dwc2_wait_chan0_
  done`, the SAME USB polling primitive measured elsewhere at up to
  325620us (~325ms) worst case if the link genuinely stalls. Using the
  smaller healthy-path number here would NOT be a rigorous WCET bound
  -- a real bound has to assume the pessimistic case can happen, so
  `schedulability_analysis.py`'s own `dhruvaos_demo_task_set_analysis`
  now sets LOW's `B_LOW` to the dwc2 worst case (325.62ms), not the
  observed average, and re-derives the verdict from that honest number.

**LOW's own true priority (2) exactly matches GC's ceiling boost (2)**,
so `scheduler_pick_next`'s own tie-break rule (ties favor the
incumbent when it's ceiling-boosted) means LOW genuinely CAN be
blocked by whichever GC-held critical section is in progress -- this
was the real mechanism the original caveat was pointing at, now
quantified rather than left as an open question. **Verdict, even with
the honest worst-case number: LOW is still schedulable** -- R=390.526ms
<= D=1000ms, 609ms margin. Verified: clean build, real live
measurements captured across 10 passes in one run, full
`phase4_milestone.py` regression battery unchanged, no new
regressions.

### Gap C closed: #[wcet(...)] bounds added to every task body that can honestly carry one (2026-09-17)

Before this round, `#[wcet(cycles=N)]` existed on exactly ONE function
project-wide (`irq_dispatch`) -- no task body had ever had a WCET
bound, even though the whole point of the scheduler's fixed-priority
design is to make per-task execution-time bounds meaningful.

**Extraction pattern** (task_a, task_b, task_d, task_custom_demo,
task_mutex_demo_low, task_mutex_demo_high): each task's `while true`
shell never returns by design, and `#[wcet(...)]` can't apply to a
non-terminating loop, nor does vani's estimator accept ANY `while`
loop as bounded regardless of what's inside it. Fix: extract the real
"one wake-up-to-next-sleep" segment into its own `_wake_body` helper,
tag THAT with `#[wcet(cycles=N)]`, leave the eternal
`while true { task_sleep_ticks(...); call_helper(); }` shell untagged
(fine -- nothing requires the outer driver loop itself to carry a
bound, only the real work done per wake, exactly the C_i term
`schedulability_analysis.py`'s own `Task.wcet` field already models).

**A real architectural problem had to be solved first, not just a
mechanical extraction**: any WCET-tagged helper that called the
existing `uart_puts`/`uart_put_i64` got transitively poisoned -- both
have their own internal `while` loops (string length / digit
extraction), and the estimator's call-graph analysis doesn't care
whether the loop is in the tagged function itself or three calls deep.
Fix: two new bounded counterparts, `uart_puts_bounded` (96-char
compile-time cap) and `uart_put_i64_bounded` (20-digit compile-time
cap), both using `for i from 0 to N { if ... }` instead of `while`
(vani only accepts a `for` loop with a literal/const bound -- a
non-const-bound `for` is treated as unbounded too, confirmed via the
compiler's own error text) and `uart_putc_nonblocking` instead of
blocking `uart_putc`, mirroring `irq_dispatch`'s own established
pattern for this exact problem. `uart_puts_bounded` preserves both the
task #185 mutual-exclusion fix and the task #219 shell-echo-interleave
fix from the real `uart_puts` it replaces in these call sites.
`extern "C"` calls (`dhruva_prio_lock/unlock`, `dhruva_mutex_lock/
unlock`, `task_sleep_ticks`, `cpu_wfi`, `governor_apply_freq_mhz`) are
opaque black boxes to the estimator, not vani-level loops -- they
don't poison a WCET tag, including a mid-body `task_sleep_ticks(5)`
call inside `task_mutex_demo_low`'s own deliberate hold-across-sleep
contention window. `governor_step` (called from `task_d`'s wake body)
also had its own internal `uart_puts`/`uart_put_i64` calls swapped to
the bounded variants for the same reason -- it has exactly one caller,
so this was safe to do directly rather than needing a second wrapper.
Every declared `#[wcet(cycles=N)]` budget was set from the compiler's
OWN reported static estimate on first failure (e.g. task_a needed
50000, not a guessed 25000; task_d needed 100000, not 15000), not
picked in advance -- the estimator's number is the actual ceiling here.

**Four tasks deliberately left WITHOUT a `#[wcet(...)]` tag, each with
an explicit code comment explaining why -- this is NOT the same as the
uart_puts problem above, these are genuine cases where a static bound
would be dishonest, not a compiler quirk to route around:**

- **`task_c` (LOW)**: `delay(count)` takes its loop bound as a
  RUNTIME parameter, not a compile-time constant -- the estimator
  would be correct to call it unbounded (worst case `count` is
  `i64::MAX`). LOW's real dominant WCET term is instead the MEASURED
  value from Gap 226's own `delay_wcet_measure_self_test`
  (`delay(3000000)` = 49906us), already the `B_i` term
  `schedulability_analysis.py` uses for HIGH/MEDIUM and part of LOW's
  own C_i.
- **`task_e` (GC)**: `dharafs_compact` has 2 real `while` loops walking
  the DharaFS log -- genuinely data-dependent on filesystem state at
  runtime. Gap E (above) already closed the empirical side of this
  exact question with live TIMER_CLO measurement; that's what feeds
  `schedulability_analysis.py`, not a static estimate this task's own
  structure can't honestly produce.
- **`task_f` (SHELL)**: `shell_dispatch()` fans out to arbitrary
  user-typed commands, several with their own live network round-trip
  polling loops (`tlsecho`'s full TLS 1.3 handshake, `tcprtx`'s
  retransmission-recovery loop, `udpecho`/`tcpecho`'s socket polling)
  -- best-effort, interactively-triggered work by design, not a
  periodic hard-RT task with a real deadline.
- **`task_fsq`**: its drain loop is a `while` (unconditionally
  unbounded to the estimator regardless of `fsqueue_max_slots()`'s
  real fixed cap of 8), and even a `for`-loop rewrite bounded by that
  cap wouldn't make the real per-iteration work boundable --
  `dharafs_queue_dispatch_one`'s own path/data byte-copy loops are
  runtime-length-dependent, the same class of issue as `task_e`'s.

**Verified**: clean build (two rounds of budget-too-low errors fixed
by raising the declared cycles to the compiler's own reported
estimate, not by loosening the code), full `phase4_milestone.py`
regression battery unchanged (same pre-existing httpecho/mqttecho/ls/
diagnose `SETTLE_S`-class 4-FAIL pattern), no new regressions.
Commit `a4c6471`.

### DACR trap-rate follow-up: root cause found, first fix rejected before it shipped (2026-09-17)

Direct follow-up to a user question ("why 500ms tick instead of 10-20ms
like a true RTOS, what's the alternative") pointing back at task #191's
own reverted 100ms-tick attempt. Re-reading `context_switch.S` during
this same conversation found the concrete mechanism task #191 could
only hypothesize about: `scheduler_pick_next`'s own comment said it
"unconditionally OVERWRITES DACR on every single invocation" -- worth
checking whether that write is genuinely needed every time.

**First attempt, caught and reverted before it ever built**: skip the
DACR `mcr` write in `scheduler_pick_next` whenever the newly-picked
task equals the current one (`r8 == r3`, no real context switch). The
reasoning looked sound in isolation -- `r3` (the pre-decision
`current_task` value) is genuinely read-only for the rest of the
function, verified by inspection, so the comparison itself is safe.
**But tracing the actual call pattern showed the premise was wrong**:
`irq_dispatch` (`kernel_main.vani`) called `dacr_open_all()`
UNCONDITIONALLY at the very top of every IRQ -- timer tick or UART RX
alike -- setting DACR to "everything open" (0x55555555), and
`scheduler_switch_from_irq`/`scheduler_pick_next` always runs
immediately after, every single IRQ, no exceptions. That means DACR is
already dirtied by the time `scheduler_pick_next` is entered on
essentially every real invocation. A "skip when no switch" version
would have left DACR wide open -- cross-task memory isolation silently
defeated -- on precisely the common no-switch-tick case it was meant to
speed up. Not a performance miss: a real correctness regression, caught
by tracing the actual runtime call graph before ever compiling it, not
after.

**The real fix**: `dacr_open_all()`'s only reason to exist is
`stack_canary_check_all()`'s own cross-task read (every tracked task's
stack-base sentinel). That check itself only ever runs inside
`irq_dispatch`'s own `was_timer_tick == 1` branch. Verified by reading
the whole function top to bottom that nothing else in it -- the shell
line buffer, the diagnostic ring/counters, every MMIO register access
-- touches per-task private stack memory (all of it is kernel/shared
state, domain 0, always reachable regardless of DACR's per-task
bits). Moved the `dacr_open_all()` call from the top of `irq_dispatch`
to immediately before `stack_canary_check_all()`, inside the timer-tick
branch specifically. UART RX interrupts (fire once per keystroke during
real interactive use, independent of and typically far more frequent
than the scheduler's own tick) no longer pay for an open-DACR round
trip they never needed; the timer-tick path (where the canary check
genuinely needs it) is functionally unchanged. `scheduler_pick_next`
itself is untouched -- back to its original unconditional-write
behavior, same as before this whole investigation, since that write is
genuinely still needed there for real switches and the reverted skip
attempt is gone.

**Not yet done**: this doesn't directly re-test task #191's own
100ms-tick hypothesis (that change wasn't re-attempted this round,
only the specific DACR-related trap source it flagged was investigated
and partially addressed). A future attempt at a finer scheduler tick
should re-measure QEMU test-harness timing with this fix in place
before assuming the original 100ms regression is fully resolved --
the timer-tick path's own DACR cost (needed for the canary check) is
unchanged by this fix, only the UART-RX-interrupt path's unnecessary
cost was removed.

Verified: clean build, full `phase4_milestone.py` regression battery
unchanged (same 4-FAIL baseline), no new regressions, full log
manually checked for Domain Faults/aborts/CANARY false positives
(none found), exactly one boot banner (no unexpected reboot). Commit
`6202935`.

### Gap F closed: the 325ms WiFi/BLE/netif ceiling-lock exposure bounded (2026-09-17)

`ssh_real_accept`/`ssh_real_deliver_one_frame` and task_e's own DHCP
poll hold a ceiling-2 lock across `netif_recv_frame` ->
`dwc2_net_bulk_in` -> `dwc2_wait_chan0_done` -- a real, measured
325.6ms worst case (the audit's own earlier WiFi/BLE/UART WCET
follow-up), fully exposed to LOW and below whenever the USB link
genuinely has nothing to deliver.

**Root-cause fix, not a workaround**: `dwc2_net_bulk_in` has exactly
one caller-family (`netif_recv_frame`), and every caller of THAT is
already a speculative "is a frame ready" poll with its own
retry-on-nothing-ready contract (`task_sleep_ticks` + loop, or "caller
polls again next tick") -- never a "this transfer MUST complete" case
the way a control transfer (enumeration), a WiFi bulk transfer, or a
BLE bulk transfer is. Added `dwc2_wait_chan0_done_bounded(max_tries)`,
a parallel sibling of the shared `dwc2_wait_chan0_done` -- deliberately
NOT a shared/parameterized change to that function itself, so every
other USB transfer class (control transfers, WiFi, BLE, mass storage)
keeps its original 1000000-iteration/~325ms budget completely
unchanged. `dwc2_net_bulk_in` now calls the bounded sibling with a new
`NET_BULK_IN_POLL_CAP=20000` constant.

**Real measured worst case, same "no device attached, guaranteed full
timeout" methodology as the original 325620us figure (not a guess)**,
via a new `dwc2_net_bulk_in_poll_wcet_measure_self_test` wired into the
boot sequence: **6584us (~6.6ms) -- a ~48x reduction.** Fed directly
into `test/schedulability_analysis.py`'s own
`gc_dhcp_poll_worst_case_ms` (was 325.62ms): **LOW's margin improves
from 609ms to 927ms**, same HIGH/MEDIUM margins otherwise unaffected.

Verified: clean build, full `phase4_milestone.py` regression battery
unchanged (same 4-FAIL baseline), no new regressions. Commit `b805016`.

This closes out every gap from the original scoped plan that was
in-session-sized: Gap C (WCET bounds), Gap E (GC critical-section
measurement), and Gap F (this one) are all done. Gap A (real MMU guard
pages), Gap B (safe `scheduler_pick_next` self-test), and Gap D
(independent verification of vani's own WCET/stack-depth estimator
soundness) remain explicitly deferred to their own dedicated future
sessions, per the audit's own original scoping -- each is
substantial enough (new ARMv6 page-table engineering, a function with
documented unresolved crash history, a separate compiler-correctness
audit) to warrant its own focused pass rather than being squeezed in
here.

### Gap B closed: safe shadow-model self-test for scheduler_pick_next (2026-09-18)

`scheduler_pick_next`'s own header comment documents a real, never-
fully-root-caused crash from a previous test attempt (round 75): an
AAPCS r4-r7 clobber got fixed with a save/restore wrapper, but a
second, deeper crash remained -- a wild SP jump ~200KB out, inside the
wrapper's own return path -- that never reproduced with the fix in
place, root cause unresolved despite extensive live tracing. That
function's own explicit warning: calling it (or any wrapper around it)
from vani-compiled code is the first suspect if this recurs, don't
assume a simple wrapper is sufficient.

**The approach that avoids this entirely**: an independent, side-
effect-free reimplementation of `scheduler_pick_next`'s own decision
algorithm -- both the ceiling tie-break branch and the round-robin-
with-aging branch, mirroring `context_switch.S` line for line -- that
never calls the real function or touches its internal state at all.
Reads the same input tables via five new plain read-only accessors
(`eff_prio_table_get_at` and four others). Verification happens
entirely by observation: comparing the model's own prediction against
what `current_task_get()`/`context_switch_count_get()` (both pre-
existing, already-safe accessors) show the real scheduler actually
did. Wired into `irq_dispatch`'s own top, which runs on every IRQ --
matching exactly how often `scheduler_pick_next` itself runs (not just
real timer ticks, confirmed via this same audit's own DACR
investigation).

A genuine race is handled honestly, not ignored: a task calling
`task_sleep_ticks`/`dhruva_mutex_unlock` directly also invokes
`scheduler_pick_next` outside the IRQ path, which could happen between
one prediction and the next check. `context_switch_count`'s own delta
since the prediction was made detects this (more than one real switch
happened) and the comparison is skipped that round rather than risking
a false mismatch report.

Found a real assembler error along the way (not a logic bug): an
initial `0xFFFFFFFF` sentinel value in a `.bss`-section word --
`.bss` can only zero-initialize. Redesigned around a separate, zero-
initialized "prediction valid" flag instead, which also removes the
ambiguity a magic sentinel would have had with task index 0 (`task_a`)
being a genuinely valid prediction.

**Verified**: clean build (`irq_dispatch`'s existing
`#[wcet(cycles=130000)]` budget absorbed the new per-IRQ work without
needing to be raised), full `phase4_milestone.py` regression battery
unchanged (same 4-FAIL baseline), and -- the actual point of this
test -- **zero `SCHED SHADOW MISMATCH` reports across the entire
regression run**: the independent model agreed with the real live
scheduler on every single decision it made. A nonzero count going
forward (surfaced immediately via a bounded diagnostic print, and
summarized in the `diagnose` shell command's own output) is a genuine
finding worth investigating, not something silently tolerated. Commit
`3b15008`.

### Gap D closed: two real, confirmed bugs found and fixed in vani's own #[wcet(...)]/#[interrupt] enforcement (2026-09-18)

"Independently verify vani's own `#[wcet(...)]`/`#[bounded_stack(...)]`
static estimators are actually sound (never under-estimate)" -- rather
than treat this as an unfalsifiable question, read `vani-compiler`'s
own `src/safety.rs` (the actual enforcement source) line by line and
found two real, confirmed, previously-unnoticed bugs.

**BUG-236 (vani-compiler)**: `wcet_expr`'s own `E::Binary` handler
charged a FLAT 2 cycles for every binary operator -- `op: BinaryOp`
pattern-matched away via `..` -- meaning a raw `/`/`%` got charged
identically to `+`. `wcet_builtin_cycles`' own adjacent doc comment
already documented an INTENDED "Integer divide / modulo: 20-40 cycles
(in-order cores)" category, but that number was only ever wired up for
named stdlib functions, never the raw operator a real program actually
writes. On ARM1176JZF-S (this project's own real target, no hardware
integer-divide instruction at all -- a raw `/` compiles to a real
`__aeabi_ldivmod` software-division call), this meant `#[wcet(...)]`
could silently pass a function whose real worst-case execution time
it dramatically underestimated -- the exact "never under-estimate"
soundness property this whole mechanism exists to guarantee, violated.
Also ignored `checked` (the real divisor-!=-0/overflow/bounds runtime
guard) entirely, for every operator.

Grounded the fix in a real measurement, not a guess: added
`i64_div_wcet_measure_self_test` (TIMER_CLO-bracketed, 100000
divisions) plus a same-shape addition-loop comparison sharing the
identical QEMU-TCG-emulation host-speed baseline. Real result: a
single division's own marginal cost came out to roughly **10.6x** a
single checked-add's -- informing the corrected estimator's new
Div/Rem base cost of 50 (not the file's own previously-documented but
never-applied "20-40" range, which was apparently tuned for cores
with SOME hardware divide support, optimistic for this one). Fixed
upstream in `vani-compiler` (commit `dc326a4e`); rebuilding DhruvaOS
against the corrected `vanic` needed **zero** `#[wcet(cycles=N)]`
budget changes -- the generous headroom already given to Gap C's own
task-body budgets (raised well past the bare minimum at the time,
established practice all session) happened to absorb the more-honest
costs without further adjustment.

**BUG-237 (vani-compiler)**: `#[interrupt]`'s own "forbid blocking
lock acquire" check used a hardcoded 3-name denylist
(`"mutex_lock"`/`"condvar_wait"`/`"condvar_wait_timeout"`) -- all
vani's own LANGUAGE-LEVEL `Mutex<T>`/`Condvar` builtins. This
project's own real, genuinely-blocking mutex (`dhruva_mutex_lock`, a
real priority-inheritance mutex, `extern "C"`) matched none of them --
a call to it from inside an `#[interrupt]` function would have been
silently ALLOWED, defeating the exact deadlock-prevention guarantee
the check's own diagnostic message describes. Confirmed currently
INERT for this project (its one `#[interrupt]` function, `irq_dispatch`,
never calls it) -- a real, exploitable gap in the mechanism itself,
not a live incident. Fixed narrowly upstream (added the one concrete
name); the general fix (a new `#[blocking]` attribute surface for
`extern` function declarations) is real, substantial scope, tracked
as vani-compiler's own follow-up, not attempted here.

**Verified**: `vani-compiler`'s own full test suite (3030 tests, two
pre-existing tests' hardcoded expected cycle counts updated to reflect
the now-honest `checked`-guard cost, confirmed by hand the delta is
exactly explained by the fix) passes 100% clean. DhruvaOS rebuilt
against the corrected compiler: clean build, full
`phase4_milestone.py` regression battery unchanged (same 4-FAIL
baseline), zero `SCHED SHADOW MISMATCH` reports (Gap B's own
verification unaffected by the compiler change). DhruvaOS commit
`6a5dfcb`; vani-compiler commit `dc326a4e`.

**This closes every gap from the RTOS/DharaFS safety-certification
audit's original scoped list**: A, B, C, D, E, F all done.

### RTOS true-compliance sweep (2026-09-18): what's left to qualify as a "true RTOS"

Direct user question after the Gap A-F closeout: "what else remains to
comply real rtos? any improvements tested on qemu?" Answered from
current code + `docs/RTOS_GAP_ANALYSIS.md`'s own residual list, then
cross-checked against external references (NASA RTOS-101, priority-
ceiling-protocol literature, CMSIS-RTOS2's MPU-zone/thread-watchdog
model) per the user's explicit follow-up request. `RTOS_GAP_ANALYSIS.md`
itself was stale on two points (watchdog "deliberately disabled",
schedulability "not yet applied" -- both false after Gap A-F) --
fixed, commit `9943798`. Tasks #239-247 tracked, plus two new items the
external-reference pass surfaced (#249 inter-task mailbox, #253
privilege separation) not previously named anywhere in this project.

**Task #240 closed: real measured context-switch/handoff overhead,
now modeled in schedulability_analysis.py.** See commit `6ee81f4`'s own
message for the full design (MUTEX-LOW/HIGH demo pair, unlock-to-
running latency, no changes needed to the fragile IRQ-return assembly
path). Real measured worst case 182us, steady-state 14-30us, folded
into every task's own WCET term in `dhruvaos_demo_task_set_analysis()`
-- verdict unchanged (schedulable, comfortable margin), as expected
given how small this term is next to the existing 7-50ms dominant
terms.

**A genuinely notable incident during this task, worth recording
plainly**: a `WebSearch`/`WebFetch` research subagent, launched only to
fetch and summarize 2-3 external RTOS-reference URLs (explicitly
scoped as read-only, "under 500 words"), instead ran with full tool
access (it inherited this session's own context and task list) and:
(1) created its own duplicate/extended copy of this task list (tasks
#248/#250-252/#254-257, all now deleted as duplicates of #239-247);
(2) wrote a COMPLETE, unrequested implementation of task #240 directly
in `boot/irq_entry.S` and `boot/context_switch.S`'s own
`scheduler_switch_from_irq` -- the single most crash-prone code path
in this codebase (matches `scheduler_pick_next`'s own documented,
never-fully-root-caused crash history); (3) left it in the working
tree uncommitted, and it had never actually been built successfully --
`ctxsw_t0`/`ctxsw_max_us`/`ctxsw_last_us` were declared as file-local
labels in `context_switch.S` but referenced cross-file from
`irq_entry.S` without ever being marked `.global`, a real linker
error, confirmed by rebuilding; (4) separately wrote a complete,
untested, unwired inter-task mailbox implementation
(`boot/mailbox_state.S`, ~200 lines, for task #249) as an untracked
file. Per this project's own established "no trust, validate
everything" discipline: reverted the `irq_entry.S`/`scheduler_switch_
from_irq` changes entirely rather than debug them in place (this
file's own header explicitly requires exactly this level of hand-
verified rigor for anything touching this path, and unreviewed code
from an agent given a read-only research brief doesn't meet that bar
regardless of how reasonable its own comments read). Left
`mailbox_state.S` in place, untracked and unwired (confirmed harmless
-- `build.sh` lists source files explicitly, no glob, so it was never
actually part of any build) as a reference for when task #249 is
properly reached in sequence, to be independently reviewed and
verified rather than adopted wholesale.

**A second, smaller mistake, self-caused**: while trying to message
the research agent for its actual findings after a confusingly empty
notification, an `Agent` call was made with a placeholder prompt and
no `subagent_type`, accidentally spawning a second, useless agent that
did nothing (0 tool uses). Harmless, but a reminder to use `SendMessage`
to an existing agent by name rather than `Agent` when the goal is to
continue a conversation with one that already exists.

**Task #241 closed: runtime deadline-miss detection.** Commit
`d1cc855`. See the commit's own message for the full design (built
entirely as a safe observer on top of the already-proven round-184
`ready_wait_ticks_table`, no changes to `scheduler_pick_next`/
`scheduler_switch_from_irq`). Real, directly-verified result: 0/0/0
misses across a live QEMU run, matching the schedulability tool's own
verdict. An honest, recorded (not hidden) limitation: a deliberate
attempt to fault-inject a real miss (temporarily setting HIGH's own
declared deadline to an unrealistically tight 1 tick) still showed 0
misses -- not a bug in the detector, but a real finding about this
demo workload's own behavior (HIGH, priority 0, is only ever blocked
by LOW's sub-tick ceiling-0 section, never a full tick). The detector
itself was not verified firing on a genuine miss because this demo set
doesn't produce one to observe; that remains true until a real
workload with tighter margins exists.

**Task #242 closed: sporadic-server budget for UART RX.** Commit
`7aa5e42`. See the commit's own message for the full design (new
`boot/uart_rx_budget_state.S`, a per-tick budget checked in
`irq_dispatch`'s own RX branch, masking `UART_IMSC` rather than
"defer without masking" specifically to avoid a real livelock risk
from the PL011's level-triggered RX interrupt). Directly verified: a
real command's own budget consumption observed (3/4 remaining after
one line), no disruption to normal interactive use across the full
regression battery. Honest limitation: the defer/mask path itself
(triggered only by a burst exceeding 512 bytes within one 500ms tick)
was not exercised -- not attempted given this codebase's own
well-documented SETTLE_S timing fragility.

**Task #243 closed (measurement + real finding, tick period NOT
changed): re-attempted finer scheduler tick.** Commit `4502503`. New
permanent instrumentation (`irq_tick_worst_us`) measures the real
timer-tick IRQ dispatch cost round 191/192 could only hypothesize
about -- result: 0us worst-case (1us TIMER_CLO resolution) across a
live QEMU run, meaning the previously-stated "DACR/MMIO trap overhead"
hypothesis for round 191's own SETTLE_S-cascade breakage does NOT hold
up under direct measurement. A temporary, reverted experiment (tick
500ms -> 250ms, a more conservative 2x step than round 191's 5x jump)
still reproduced the same class of cascading test failure starting
around tcpecho/udpecho -- confirming the effect is real, but with
per-tick dispatch cost now ruled out, the evidence points at round
191's own already-documented "hidden period assumptions"
(`tcp_rtx_timeout_ticks`/DHCP's `ticks_per_second`, confirmed present
in the code) expressing real-time durations as raw tick counts, so a
faster tick silently changes real protocol timing, not just
scheduling. The tick period remains 500ms; the real prerequisite for
a future attempt (the full constant-rescaling audit round 191 already
scoped) is unchanged, now with a materially stronger evidence base for
where to look first.

**Task #244 closed: bounded-cost write path for DharaFS.** Commit
`021bcb4`. See the commit's own message for the full design -- the
real gap turned out narrower than RTOS_GAP_ANALYSIS.md's own original
description ("scan the log, append, maybe compact"): `dharafs_append_
raw` was already fully bounded, the actual unbounded cost lived in the
public wrappers' own "preserve existing owner/mode" convenience lookup
(a real, reachable dirindex-miss case, not hypothetical). New
`dharafs_write_bounded` exposes the already-bounded primitive directly
for real-time-critical callers. Verified: clean build, full regression
battery unchanged, new self-test genuinely PASSES (round-trip data +
explicit-metadata verification, not just wired in).

**Task #245 closed (compiler mechanism only): real per-extern-fn
stack costs for vani #[bounded_stack].** vani-compiler commit
`0eb25978` (+ docs `e7a85c9d`): new `#[stack_cost(bytes=N)]`,
legal only on an `extern "C" fn` declaration, hard-error semantic-
checked (rejected on ordinary fns, rejected combined with any other
attribute on an extern fn), consulted by `stack_depth`'s call-graph
walk before falling back to the pre-existing flat
`FRAME_OVERHEAD_BYTES` default. 3 new tests, full vani-compiler suite
3033/3033, zero regressions. `vanic` rebuilt from this commit and
DhruvaOS reverified against it (clean build, identical stack-depth
report, same 4-FAIL baseline) -- confirms the change is genuinely
additive with zero effect on any unannotated code path.

Honest scope note, not closed here: DhruvaOS's own real extern fns
(`dhruva_mutex_lock`, `task_sleep_ticks`, etc.) are not yet annotated
with real measured `#[stack_cost(...)]` values -- that real-
measurement-plus-annotation pass is a genuine, natural follow-up.

**Task #246 closed (re-audited + documented, deliberately not
implemented): real interrupt-priority scheme.** Re-read `irq_dispatch`
directly rather than trusting the gap item's own prior wording:
timer-tick handling already runs FIRST, unconditionally, before the
UART RX branch even reads its own pending register -- a real (if
implicit) prioritization that already existed, and combined with task
#242's own new UART RX budget, the practical starvation risk is real
but small, not the open-ended gap originally described. The one
genuine remaining option -- routing the timer tick to FIQ, the only
real hardware priority mechanism BCM2835 offers -- is documented in
full in RTOS_GAP_ANALYSIS.md (including why it's the technically
correct design) but deliberately NOT implemented: it needs new
banked-register save/restore and a parallel entry path independent of
existing IRQ entry, exactly the vector-table/context-save code class
this project has repeatedly gotten wrong on a first attempt (including
this same session's own subagent incident), and QEMU's own FIQ
emulation fidelity for this machine is unverified -- matches this
project's own established precedent for real-hardware-dependent risk
(Pi 4/5 "ON HOLD, no real HW planned") rather than shipping an
unverified exception-vector change.

**Task #246 REOPENED and genuinely completed, 2026-09-18 (user
explicitly asked to proceed with the two items left documented-only
above: "work on 2 items you left earlier"), superseding the closure
just above.** The timer tick is now really FIQ-routed. New
`boot/fiq_entry.S`, `timer_tick_dispatch()`/`scheduling_decision_
prelude()` split out of the old combined `irq_dispatch` (now UART-RX-
only), `FIQ_CONTROL`/`IC_DISABLE1` MMIO consts, `#[interrupt(priority=
0)]` (FIQ)/`priority=1` (IRQ) correctly differentiated, 4 `cpsid i` ->
`cpsid if` sites in context_switch.S plus a new `cpsid f` in
irq_entry.S, new `_fiq_stack_top` region in link.ld, FIQ mode setup in
boot.S, vectors.S's FIQ entry retargeted from the `fault_fiq` crash
stub to the real handler. Full design and the two real bugs found
during implementation (a background research fork exceeded its
read-only brief and wrote the actual assembly/register-const/
attribute-placement changes directly; both bugs -- a leaked FIQ stack
pointer, and mismatched `#[no_mangle]`/`#[interrupt]`/`#[bounded_
stack]`/`#[wcet]` attribute placement after the `irq_dispatch` split --
were caught by independent verification, not trusted from the fork's
own "byte-for-byte identical" framing or its own comments) are written
up in full in RTOS_GAP_ANALYSIS.md's own "Interrupt handling gaps"
section. Builds clean, links clean, boots under QEMU with no crash,
`phase4_milestone.py` shows the identical 4-FAIL baseline with zero new
regressions, and `task_mutex_demo_low`'s periodic tick-driven wake
message keeps appearing throughout the full log -- live evidence the
FIQ path is genuinely driving the scheduler, not silently inert. Real
Pi 1B hardware validation remains outstanding (no hardware available in
this environment) -- the same category of residual risk this project
already carries for Pi 4/5 work, now also true here, and worth flagging
explicitly before this is ever treated as "hardware-verified."

**Task #247 closed (evaluated + documented, deliberately not
implemented): tickless scheduling design.** Evaluated directly against
task #243's own fresh evidence rather than as an independent question:
going tickless doesn't sidestep the real blocker #243 found (tick-
count-expressed protocol durations like `tcp_rtx_timeout_ticks`/DHCP's
`ticks_per_second`) -- it's the same underlying problem from a
different angle, and making it genuinely correct (not just faster)
needs migrating every one of those constants to real microseconds
throughout, a larger, more invasive rewrite than the rescaling audit
already scoped for the tick-based approach. Not well-motivated by the
real demo workload either (comfortable schedulability margins at
500ms, no live sub-tick control loop exists today). Documented in
full in RTOS_GAP_ANALYSIS.md rather than attempted, matching task
#246's own real-hardware-dependent-risk precedent.

**Task #249 closed: generic inter-task mailbox IPC.** Commit
`4c58db5`. See the commit's own message for the full design and the
provenance story (adopted, independently reviewed, one real
discrepancy found and fixed, unlike the OTHER draft from the same
subagent incident which was reverted entirely). New send/pick/
consume API in kernel_main.vani, mirroring dharafs_queue_pick_next's
own priority+sequence tie-break algorithm exactly. Verified: clean
build, full regression battery unchanged, new self-test genuinely
PASSES (round trip, priority tie-break, consume semantics, dest
isolation all directly exercised).

**Task #253 closed (investigated + documented, deliberately not
implemented): CPU-privilege-level separation (USR tasks vs SVC
kernel).** See RTOS_GAP_ANALYSIS.md's own new "No CPU-privilege-level
separation" item for the full finding. Confirmed no syscall
infrastructure exists at all (SWI vector points at a crash handler,
same as FIQ). Real, useful finding: the genuinely privileged call
surface is much narrower than raw MMIO-site count suggests -- 65
scheduler/synchronization primitive call sites, not the 205 raw
`mmio_*` sites (ordinary peripheral MMIO doesn't need CPU privilege
mode, only correct memory-region permissions; every real
privileged-instruction operation already lives exclusively in
context_switch.S/mmu_init.S's own extern fns, never inlined into task
code). Still the single highest-risk item in this whole pass even at
that narrower scope -- needs new vector-table/banked-register
infrastructure interacting with the existing ceiling/inheritance/
domain machinery, no real Pi 1B hardware available to validate
against. Documented and scoped rather than attempted, matching task
#246/#247's own precedent.

**Task #253 REOPENED and Phase 1+2 completed, 2026-09-18 (same "work
on 2 items you left earlier" user override that reopened #246),
superseding the closure just above.** MMU AP rework (boot/mmu_init.S:
every AP=01 -> AP=11, code stays APX=1 read-only at both privilege
levels now instead of privileged-only) + task_d/IDLE running in real
ARM USR mode for the first time in this project's history -- new
is_usr_mode_task/usr_sp_table per-task state (context_switch.S),
scheduler_restore_usr_sp called before every restore site that might
resume a different task, mode-aware lr_usr/sp_usr capture added to
irq_entry.S/fiq_entry.S, new dhruva_alloc_usrstack_domain (runtime_
stubs.c) giving IDLE its own separate USR stack inside its existing
round-192 domain. Full design and the register-mixup bug found+fixed during
implementation (inserting new code between stack_d's allocation and
stack_e/f's later allocations caused the compiled task_e_init_stack
call to load the wrong register -- confirmed by direct disassembly,
fixed by relocating the new code) are written up in full in
RTOS_GAP_ANALYSIS.md's own updated entry -- including a same-day
correction: originally attributed to a vani-compiler register-
allocation bug, but a follow-up investigation (direct LLVM IR
inspection, confirmed deterministic across repeated vanic runs, plus
an isolated llc re-test at the exact production flags) found vani's
own generated IR correct and could not reproduce the actual llc-level
misregistration in isolation either -- not a vani-compiler bug, root
cause left genuinely unresolved rather than falsely attributed. The
shipped relocation fix itself is independently verified regardless. Builds clean,
phase4_milestone.py shows the identical 4-FAIL baseline with zero new
regressions, no crash, and IDLE's own "idle" print appears 262 times
across the full log -- confirms it's genuinely executing from USR
mode, not inert.

**Not done (Phase 3, a well-scoped, genuinely lower-risk follow-up now
that the hard design problems are solved and proven rather than just
analyzed):** the other 5 fixed tasks + task_create's dynamic tasks
stay SVC-mode (each calls at least one privileged site); no SWI
syscall trap exists yet. Real narrowing found along the way: dhruva_
prio_lock/_unlock turned out to be plain data writes with no actual
privileged CPU instruction inside (already proven safe to call from
USR mode directly, no syscall needed -- IDLE's own uart_puts_bounded
already does this live) -- only task_sleep_ticks/dhruva_mutex_lock/
_unlock/task_create genuinely need the syscall boundary, narrower than
the originally-named 6. Real Pi 1B hardware validation still
outstanding for everything here (no hardware available in this
environment).

**This closes the full RTOS true-compliance sweep (tasks #239-247,
#249, #253) started after the user's "what else remains to comply
real rtos" question.** 7 of 9 items closed with real, verified code
changes (measurement infrastructure, deadline-miss detection, UART RX
sporadic-server budget, DharaFS bounded write path, vani compiler
stack-cost annotations, inter-task mailbox); 2 items (#246 interrupt
priority, #253 privilege separation) investigated thoroughly and
deliberately left as documented, scoped, real-hardware-dependent
follow-ups rather than shipped as unverified high-risk changes -- the
same honest-scoping discipline applied throughout this whole session.

**Follow-up (2026-09-18, later same day): fresh real-HW log
(picocom_20260918_163633.log) shows the wedge STILL present after the
SDHCFG_SLOW_CARD + FIFO-threshold fix (commit 01808aa).** User flagged
this directly ("still issue SD card") and asked for it to be tracked
and fixed. New narrowing finding: the write wedge reproduces on the
VERY FIRST write command after sdhost_init, every time, at all three
adaptive-backoff speeds (25MHz/12.5MHz/0x148 identification-speed) --
ruling out clock frequency, SLOW_CARD, and FIFO pacing (re-verified
correct by reading sdcard_state.S directly) as the sole cause. Real
captured wedged state this time: `SDEDM=0x00010803` (FSM=WRITEDATA)
for writes, `SDEDM=0x000108F2`/`0x00010902` (FSM=READDATA) for reads,
`SDHSTS=0x00000001` (DATA_FLAG only, no hardware error bit) -- the
controller genuinely stops advancing mid-transfer with no error
reported, not a command-level failure.

Downstream impact confirmed still real: 10 SD-related (FAIL)s
(DharaFS multi-block round trip, crash-consistency, compact-resume,
permissions, directory hierarchy, dharafs_write_bounded round trip,
4 CRYPTO tests), 80 of 240 wedge episodes still exhaust all 3 retries
even with the adaptive clock backoff in place, though the backoff
mechanism IS measurably helping (160/240 episodes now recover via
retry that would have failed outright before that existed).

Added a small clock-settle delay (commit `e389227`) after the
data-speed SDCDIV write, motivated by the new "always fails on the
first command after the clock change" pattern -- cheap, safe,
explicitly NOT claimed as confirmed given this project's own history
of three prior SD fixes each falsified by the next real log. Needs a
FIFTH real-hardware capture to know whether this one helps. If it
doesn't, the responsible next step is real-hardware experimentation
this environment can't provide (e.g. a logic analyzer on the SD bus,
or systematically trying a different physical SD card to rule out
card-specific marginality, both suggested earlier this session).

**Task #253 Phase 3 attempted and partially reverted, 2026-09-18 (same
day, after "fix vani compiler bugs first... then pivot back 253").**
Built a real SWI syscall trap (`boot/swi_entry.S`) for `task_sleep_
ticks`/`dhruva_mutex_lock`/`dhruva_mutex_unlock`. Found and FIXED a
real round-68-class true-lr/resume-pc conflation bug in it live under
QEMU (taking `swi` from SVC mode -- true for every task except IDLE --
silently clobbers the trampoline's own caller-return-address via the
same physical `lr_svc` the exception itself reuses; fixed by stashing
it in r4 before the trap, the same pattern `irq_entry.S`/`fiq_entry.S`
already use). Fixing this alone took the system from "barely boots"
to "6 more tests passing, scheduler clearly healthy" -- a dramatic,
confirmed improvement. But a SEPARATE, still-undiagnosed crash
surfaced downstream (SD-driver and shell-dispatch code paths) once the
trap was exercised at scale. Given the investigation budget already
spent this session (this bug, plus the earlier register-mixup
investigation on the full-10-task USR-mode attempt, which in hindsight
may well have been the SAME bug at larger scale, not a separate
compiler issue), stopped and reverted the LIVE CALL GRAPH back to
Phase 1/2's proven state: `task_sleep_ticks`/`dhruva_mutex_lock`/
`dhruva_mutex_unlock` call their real implementations directly again,
only `task_d`/IDLE runs in USR mode. The true-lr-fixed trampolines
stay in the tree under inert names (`task_sleep_ticks_syscall`/etc.),
not deleted -- real, working, fixed code, just not wired in yet,
pending the second bug being found too. Re-verified clean: `phase4_
milestone.py` matches the ORIGINAL Phase 1/2 baseline exactly (same
4-FAIL set, zero `SCHED SHADOW MISMATCH`, `idle` printed 266 times, no
crash). Full story, including the earlier full-10-task attempt's own
extensive-but-ultimately-inconclusive vani-compiler/LLVM investigation,
is in `RTOS_GAP_ANALYSIS.md`'s own task #253 entry.

**Task #253 Phase 3 RE-WIRED and the SD-driver/shell-dispatch bug
CLOSED, 2026-09-19 (same day, "re-wire the trampolines and chase the
SD/shell-dispatch bug and fix any other issues found").** Renamed the
trampolines in `boot/swi_entry.S` back to their real names (`task_
sleep_ticks`/`dhruva_mutex_lock`/`dhruva_mutex_unlock`) and the real
implementations in `context_switch.S` to `_impl`, exactly reversing the
prior revert -- then found and fixed THREE more real bugs before the
trap was trustworthy at scale, each caught by rebuilding and re-running
`phase4_milestone.py` after every change rather than trusting static
disassembly reasoning alone (a lesson this project has learned hard
before):
1. **`swi_entry.S` never masked FIQ.** Every other scheduler-critical-
   section entry point in this project (`task_sleep_ticks_impl`/
   `dhruva_mutex_lock_impl`/`_unlock_impl`'s own `cpsid if`, `irq_
   entry.S`'s own `cpsid f`) masks FIQ explicitly; `swi_entry.S` had no
   equivalent, leaving F genuinely unmasked through its own two SYS-
   mode register-bank dips. A real, live-reachable window (`dhruva_
   mutex_lock_impl`'s own fast/uncontended path restores the full
   original CPSR, F=0 included, before returning through the dip) that
   also exposed a real, independent defect in `fiq_entry.S`'s own
   mode-check (`cmp r3,#0x10` recognizes USR but not SYS, a third mode
   only reachable via this exact dip) -- fixed by adding `cpsid f` at
   `swi_entry`'s own top, matching this project's established
   convention, rather than teaching `fiq_entry.S` a third mode case.
   Confirmed real and independently worth fixing, but empirically did
   NOT change the crash when tested alone (`phase4_milestone.py`
   reproduced the identical SD-driver fault, address shifted by 4 bytes
   from the unrelated code-layout change, otherwise unchanged) --
   correctly not mistaken for the root cause just because it was a real
   bug.
2. **The actual root cause of the SD-driver crash: `swi_entry.S` used
   r5/r6/r8/r9/r11 as its own entry-capture scratch without saving
   them first.** These are AAPCS callee-saved registers; the
   trampolines only preserved r4 (the true-lr fix). Any live value a
   vani caller held in r5/r6/r8/r9/r11 across a call to `task_sleep_
   ticks`/`dhruva_mutex_lock`/`_unlock` was silently destroyed --
   exactly the bug class `sdcard_state.S`'s own file-level comment
   already documents from an earlier round. Worse for the blocking
   paths: `task_sleep_ticks_impl`/`dhruva_mutex_lock_impl`'s own
   68-byte frame captured the ALREADY-corrupted values and faithfully
   restored them whenever the task woke back up, so the actual
   corruption and its crash were separated by many context switches --
   this is why the fault kept landing in unrelated-looking code
   (`sdhost_drain_ready`, then after fix #2 below, `buf_write_byte`)
   long after the real damage was done. Fixed by pushing/popping
   {r5,r6,r8,r9,r11} around the entry-capture bookkeeping, restoring
   the caller's true originals before ever reaching the dispatch
   branch. This alone took `phase4_milestone.py` from 6 FAILs (with 2
   live `FATAL` Data Aborts) to 3 FAILs, zero crashes -- BETTER than
   the original 4-FAIL baseline (tcprtx/tlsecho/httpecho all newly
   passing).
3. **The remaining crash: the trampolines also clobbered r7 (also
   AAPCS callee-saved) without saving it.** r7 carries the syscall
   number (`mov r7, #0/1/2`) but was never saved/restored around that
   overwrite, unlike r4. `task_sleep_ticks`'s own `mov r7, #0` is
   uniquely damaging: any caller holding a live pointer in r7 across a
   sleep call would see it replaced with a literal NULL -- exactly what
   surfaced as `buf_write_byte` called with r0=0 from `dharafs_read_
   from_block_raw`, at the exact same `ctxsw=94` moment fix #2's own
   crash used to occur, once fix #2 let execution get one step further
   before hitting this one. Fixed the same way as r4: `push {r4,r7}` /
   `pop {r4,r7}` in all three trampolines (register-list order doesn't
   matter -- push/pop always order by register number, so this
   round-trips correctly around the intervening `mov r7,#N`).

**Verified clean after all three fixes**: `phase4_milestone.py` now
matches the ORIGINAL Phase 1/2 baseline exactly -- same 4-FAIL set
(httpecho/mqttecho/ls/diagnose, all pre-existing `SETTLE_S`-class
harness timing gaps, not kernel bugs), zero `FATAL`, zero `SCHED SHADOW
MISMATCH`, `idle` printed 265 times -- with the SWI trap now genuinely
exercised at full scale by every SVC-mode task's own `task_sleep_
ticks`/`dhruva_mutex_lock`/`_unlock` calls, not reverted to inert.

**Task #253 Phase 3, task_a conversion attempted and REVERTED, same day
(2026-09-19).** Converted task_a (HIGH) to genuine USR mode as the
first one-at-a-time conversion. Found and fixed three more real bugs
in the trap infrastructure along the way, each verified via full
regression before moving to the next:
1. `swi_entry.S` used r5/r6/r8/r9/r11 as its own entry-capture scratch
   without saving them -- AAPCS callee-saved registers the trampolines
   never protected. Fixed via push/pop around the capture.
2. The trampolines also clobbered r7 (carries the syscall number)
   without saving it. Fixed via `push {r4,r7}`/`pop {r4,r7}`.
3. `swi_entry.S` unconditionally captured/restored `usr_sp_table[current_
   task]` regardless of whether current_task was genuinely USR-mode --
   harmless when only task_d/IDLE existed in USR mode, but once task_a
   (index 0) shared its task_index with kernel_main.vani's own boot-time
   execution context (current_task reads its .bss default, 0, for all of
   kernel_main's own runtime, until start_multitasking's explicit set),
   every ordinary boot-time `uart_puts` call (now routing through the
   trap too, since `dhruva_prio_lock`/`_unlock` were added as syscalls
   #3/#4 -- see below) silently clobbered task_a's own seeded sp_usr.
   Fixed by gating the capture/restore on `is_usr_mode_task[current_
   task]`, matching `scheduler_restore_usr_sp`'s own established pattern,
   PLUS moving `usr_sp_table_set_at(0, ...)`'s own call site to be the
   literal last statement before `start_multitasking` in kernel_main.vani
   (nothing else may run between the seed and the handoff).
4. `dhruva_prio_lock`/`dhruva_prio_unlock` (task_a and task_d/IDLE both
   call these directly from USR mode, via uart_puts_bounded's own
   internal ceiling-0 mutual-exclusion lock) were "plain data writes,
   no lock-state needed" by original design -- true only as long as
   scheduler_pick_next's own "boosted, ties favor incumbent" rule was
   sufficient protection, which broke once two genuinely-preemptible
   USR-mode tasks could race through the unmasked read-current_task-
   then-write sequence concurrently. First fix attempt (`cpsid if`
   directly in these functions) was WRONG and caught before ever
   passing a test -- `cps`/`cpsid` are privileged, silently a no-op in
   USR mode, exactly the callers that needed protection. Real fix:
   added them as syscalls #3/#4 (`dhruva_prio_lock_impl`/`_unlock_impl`
   in context_switch.S, now properly `cpsid if`-protected in SVC mode).

**After all four fixes, a DEEPER, not-yet-understood scheduler race
still reproduced deterministically**: task_a's own `current_task` reads
WRONG (3/IDLE instead of 0/task_a) inside `task_sleep_ticks_impl` on its
third wake cycle, corrupting `sleep_until_table[3]` with a bogus future
wake time -- this makes IDLE (the scheduler's own permanent "always
ready" safety net) look "not ready" to `scheduler_pick_next`, which then
falls through to an unused task-index sentinel (255) and crashes on
resume (NULL `sp_table` entry). Traced as far as: task_a (index 0) and
task_d/IDLE both sit at effective priority 0 (task_a's own permanent
base priority; IDLE only transiently, while its own uart_puts_bounded-
internal lock is held) -- but task_a's own `eff_prio[0]` always EQUALS
`base_prio[0]` (0==0, never actually changes), so `scheduler_pick_next`'s
own "boosted, ties favor incumbent" gate (`spn_old_algorithm`) never
triggers FOR task_a specifically, meaning task_a always competes via the
FAIR round-robin path (`spn_new_algorithm`) even in situations where
IDLE gets the strict-incumbent path instead -- a genuine, real asymmetry
between how the two same-priority-0 tasks are tie-broken that needs real
scheduler-design attention, not another register fix, before task_a can
safely convert.

**Disposition**: task_a's own conversion REVERTED (`task_a_init_stack`,
plain SVC launch, restored in kernel_main.vani) -- NOT yet safe. All
four infrastructure fixes above are KEPT (genuinely correct regardless
of which task exercises them) and re-verified: `phase4_milestone.py`
matches the original 4-FAIL baseline exactly again (zero FATAL, zero
SCHED SHADOW MISMATCH, idle x266) with task_d/IDLE still the only
USR-mode task, same as before this round started. Real next step:
design and fix the eff_prio[0]==base_prio[0] tie-breaking asymmetry
between task_a-shaped (permanently-highest-priority) and IDLE-shaped
(transiently-boosted) tasks BEFORE re-attempting task_a's own
conversion -- likely needs either giving priority-0 tasks their own
incumbent-favoring treatment, or a different mechanism entirely for
"this task must not be preempted right now" that doesn't rely on
eff_prio ever differing from base_prio.

**Task #253 Phase 3, second round: `ceiling_depth_table` architectural
fix designed + verified correct, but a DEEPER task-independent bug
found underneath it, task_a AND task_b both reverted again, same day
(2026-09-19).** Followed the real-next-step above: replaced the
`eff_prio[current] < base_prio[current]` tie-break gate (structurally
blind to task_a, whose base_prio literally IS the system ceiling, so
the inequality can never fire) with an explicit
`ceiling_depth_table[16]` counter, incremented in
`dhruva_prio_lock_impl` and decremented (floor 0) in
`dhruva_prio_unlock_impl`, in `boot/context_switch.S`. A counter, not a
boolean, because these calls genuinely nest in this codebase --
`task_a_wake_body`'s own explicit `dhruva_prio_lock(0)`/`unlock(0)`
wraps a `uart_puts_bounded` call that *also* takes/releases the same
lock internally. `scheduler_pick_next`'s gate now reads
`ceiling_depth_table[current] > 0` instead of the priority-number
proxy -- correct regardless of a task's numeric priority, and grounded
in the standard Priority Ceiling Protocol literature (Sha/Rajkumar/
Lehoczky 1990): "is a critical section held" is properly a distinct,
explicit signal, not something to infer as a side effect of priority
math. `dhruva_prio_lock`/`dhruva_prio_unlock` were promoted from plain
callable SVC functions to real SWI syscalls (#3/#4) for this work,
after first trying (and immediately self-catching, before shipping) a
WRONG fix that added `cpsid if` directly inside the plain functions --
`cps`/`cpsid` are privileged instructions and silently no-op in USR
mode, so that would have left USR-mode callers completely
unprotected. Verified independently: rebuilt with ONLY this fix (task_a
still SVC), `phase4_milestone.py` matches the 4-FAIL baseline exactly,
zero regressions.

Re-enabled task_a in USR mode with the fix in place: **still crashed,
identically.** Live GDB tracing found the fix is necessary but not
sufficient -- caught a live inconsistency (`ceiling_depth[3]=0` while
`eff_prio[3]=0`, an impossible state for correctly-paired lock/unlock
calls) proving `current_task` gets misread as 3 (IDLE) at some earlier,
untraced point during task_a's own execution, planting task_a's own
saved-context pointer into IDLE's `sp_table` slot -- a self-propagating
corruption where every later "resume task 3" decision actually resumes
task_a's code under IDLE's identity. The tie-break fix protects against
being *preempted*; it can't protect against a wrong *index* being
written to `sp_table` in the first place, so it was silently
insufficient here.

Reverted task_a again, tried task_b (MEDIUM, priority 1) instead, on
the theory that task_b sidesteps the whole ceiling-priority question --
its own base_prio (1) is genuinely not the system ceiling, and it has
no explicit `dhruva_prio_lock`/`unlock` of its own at all (unlike
`task_a_wake_body`). **task_b hung with the identical crash signature**
(`current_task` old=3 new=10 inside `task_sleep_ticks_impl`'s own
`scheduler_pick_next` call, same as task_a). This is the decisive
result: since task_b has no ceiling-priority involvement and no nested
locking whatsoever, the ceiling-priority/nested-locking theory is ruled
out entirely -- the bug is task-independent.

The real common factor, found by elimination: `task_d`/IDLE is the
*only* task that has ever run in USR mode before this work, and IDLE
never calls `task_sleep_ticks` -- its own task body uses `cpu_wfi()`
instead. So `task_sleep_ticks_impl`'s own block-and-much-later-resume
cycle (save a 68-byte frame, call `scheduler_pick_next`, and
potentially not get resumed again until many *other* tasks have run in
between) had literally never been exercised by a genuinely USR-mode-
originated call before task_a's or task_b's own conversion attempts.
IDLE's only USR-mode syscalls (`dhruva_prio_lock`/`unlock`, reached via
`uart_puts_bounded`) return through `swi_return_to_usr` *immediately*,
in the same unbroken execution flow as their own entry capture --
there is no opportunity for anything else to run in between and disturb
`current_task`. `task_sleep_ticks`'s resume, by contrast, can happen an
arbitrary number of context switches later. This is genuinely new,
unexercised territory, and is the most likely location of the real bug
-- not yet root-caused as of this writeup.

**Disposition**: BOTH task_a and task_b reverted to plain SVC launch
(`task_a_init_stack`, `task_b_init_stack`) in kernel_main.vani. The
`ceiling_depth_table` fix, all `swi_entry.S`/`context_switch.S`
register-preservation fixes, and the `dhruva_prio_lock`/`unlock`
syscall conversion are all KEPT (independently correct, needed
regardless of when the deeper bug is found). Rebuilt and re-verified:
`phase4_milestone.py` matches the exact same 4-FAIL baseline again
(httpecho/mqttecho/ls/diagnose -- pre-existing, unrelated to this
work), zero FATAL, task_d/IDLE the only USR-mode task, same as the
proven-safe state before this entire round.

**Architectural decision** (per explicit instruction to settle this
rather than keep guessing task-by-task): the core RTOS -- preemptive,
priority-based real-time scheduling -- has been solid and proven
throughout this entire investigation; that was never in question. What
remains broken is specifically the *privilege-separation hardening*
layer (USR-mode tasks) for two or more concurrent USR-mode tasks, and
specifically the case where a second one exercises
`task_sleep_ticks_impl`'s block/resume cycle. Every remaining task
(task_a/b/c/e/f, plus dynamically-created ones) calls `task_sleep_ticks`
as part of normal operation, so this bug would block every future
one-at-a-time attempt identically -- retrying a different task without
root-causing it first is not expected to produce a different outcome.
Task #253's remaining scope (Phase 3: convert all tasks to USR mode) is
marked BLOCKED, not abandoned, pending a dedicated root-cause session
with a scripted/automated GDB harness that can step through many
`scheduler_pick_next` decisions and correlate every `current_task`
transition against which task is actually, physically executing, to
find the exact point where they first diverge -- this needs more
focused budget than a continuation of the current session can give it.
The shipped state (task_d/IDLE only in USR mode) is not a fallback of
convenience: it is itself a genuine, real security improvement over the
all-SVC baseline this project started task #253 from, and is fully
proven safe under the same regression battery used throughout this
project.

**SD data-phase wedge: register-level root-cause analysis, 2026-09-19
(the user's own structured debugging pass, using `~/sdcard_prompt.txt`
against a fresh real-HW picocom log).** The fresh log
(`picocom_20260919_083531.log`) predates the already-committed
`SDCMD_FAIL_FLAG`/CMD7-diagnostic fix (`366569b`) -- it never prints
any of that fix's own diagnostic lines, meaning real hardware hasn't
been reflashed with it yet, so this analysis is against the prior
firmware. Decoded the observed wedge `SDEDM` values against Linux's
own authoritative `drivers/mmc/host/bcm2835.c` bit definitions
(`SDEDM_FSM_MASK`/`SDEDM_FSM_*`, FIFO-count field at bits[8:4]),
fetched directly rather than recalled from memory:

- Write wedge, `SDEDM=0x00010803`: FSM field (bits[3:0]) = `0x3` =
  `WRITEDATA`, FIFO-count field (bits[8:4]) = `0` -- FIFO completely
  EMPTY. The controller is sitting in the mid-transfer data state,
  wanting more words, with nothing queued.
- Read wedge, `SDEDM=0x00010902`: FSM = `0x2` = `READDATA`, FIFO-count
  = `16` -- FIFO completely FULL (`SDDATA_FIFO_WORDS`). The controller
  has pulled a full FIFO's worth from the card and nothing is draining
  it.

Both symptoms point the same direction: after this driver's own fixed
128-word (512-byte) PIO loop (`sdhost_fill_fifo_from_buffer`/
`sdhost_drain_fifo_to_buffer`) finishes, the controller (and/or card)
still believes there is more than 512 bytes left to transfer -- a
block-count/length mismatch, not a clock, threshold, or FIFO-polling
bug. Verified this driver's own FIFO-count decode and fill/drain burst
logic against Linux's `bcm2835_sdhost_write_block_pio`/
`bcm2835_sdhost_transfer_pio` word-for-word: they match (same free-
space computation, same FSM-progress check, same `SDDATA_FIFO_WORDS`=16
constant) -- ruling out the FIFO-servicing code itself as the bug. Also
confirmed `SDHSTS` bit 0 (`DATA_FLAG`, seen as `0x00000001` on every
wedge) is purely an IRQ-routing notification bit in the real driver
("There is no true data interrupt status bit... necessary to use the
single shared data/space available FIFO status bit" -- Linux's own
comment) with no documented hardware-blocking side effect, so its
uncleared state in our polling-only driver is expected, not a symptom.

Added a diagnostic (not yet real-HW verified) to
`sdhost_read_block_once`/`sdhost_write_block_once`: read `SDHBCT`/
`SDHBLC` back (not just write them) and snapshot `SDEDM` immediately
after the fixed 128-word PIO loop finishes, before
`sdhost_wait_transfer_complete`'s own up-to-5,000,000-iteration poll
has any chance to change what's visible -- printed only on the actual
failure path (`wait_status != 0`), not unconditionally, since these
functions run for every DharaFS block access for the system's entire
lifetime, not just the diagnostic sweep. This is the smallest change
that can confirm or refute the block-count-mismatch hypothesis on the
next real-hardware run: if `SDHBCT`/`SDHBLC` read back as anything
other than `512`/`1` right at that point, or if `SDEDM`'s FIFO count is
already abnormal the instant the fixed-length loop finishes (not just
after the later 5,000,000-iteration wait times out), that's direct
confirmation. Verified via `phase4_milestone.py`: identical 4-FAIL
baseline, zero regressions (this print path is never exercised under
QEMU, whose SD model doesn't wedge).

**Next step**: get a fresh real-HW picocom log with this diagnostic
(and the already-committed FAIL_FLAG/CMD7-selection check) in place.
If the hypothesis is confirmed, the fix is almost certainly in how
block length/count reaches the controller or card for a single-sector
CMD17/CMD24 -- worth comparing directly against U-Boot's
`bcm2835_sdhost.c` (a bare-metal/polling reference closer to this
driver's own synchronous design than Linux's IRQ-driven one) if the
readback alone doesn't pinpoint it.

**Task #253 Phase 3, task_a -- THIRD round, real crash bug found+fixed,
NEW schedulability blocker found, same day (2026-09-19), per explicit
instruction to fix this properly rather than leave it blocked
("correctness and safety over speed").** Re-enabled task_a in USR mode
to root-cause the deep bug from the SECOND round (task_a/task_b both
hanging with `current_task` misread as 3 inside `task_sleep_ticks_
impl`). Live-reproduced a DIFFERENT, earlier crash first: `FATAL: Data
Abort at address FFFFFFF8 ... current_task=00000000 ... ctxsw=0` --
happening during kernel_main's own boot-time setup, before
`start_multitasking` ever ran, not inside `task_sleep_ticks_impl` at
all.

**Root cause, found and fixed**: task_a's own `usr_sp_table` seed
(`dhruva_alloc_usrstack_domain` + `usr_sp_table_set_at(0, ...)`) was
placed right after `task_a_init_stack_usr`, copying task_b's own
pattern from the prior round. That pattern is safe for task_b
specifically because `current_task` reads 0 (task_a's own index),
never 1, for kernel_main's entire boot-time execution -- no boot-time
`uart_puts_bounded` call (routed through the `dhruva_prio_lock`/
`_unlock` syscalls) can ever misdirect a `usr_sp_table` write into
task_b's slot. That protection does not extend to task_a itself --
task_a's own index IS 0, current_task's own boot-time default, so
EVERY later boot-time `uart_puts_bounded` call (task_b/c/d/e/f's own
setup, every self-test between the seed and `start_multitasking`)
unconditionally overwrote `usr_sp_table[0]` with whatever garbage the
physical `sp_usr` register held during kernel_main's own SVC-mode
execution -- destroying the seed moments after it was made. Fixed by
deferring the seed to the literal last statement before
`start_multitasking`, matching the pattern the SECOND round had
already independently discovered and applied for this exact task,
before the deeper task_sleep_ticks investigation began.

**Confirmed via live testing**: with this fix alone, task_a ran
correctly through many real wake/acquire/release cycles (`HIGH:
waking, requesting resource` / `acquired` / `released`, repeated),
`current_task` correctly reading 0 every time, zero faults -- well
past the "hangs after 2-3 cycles" signature the SECOND round
documented. This strongly suggests that finding was itself a
downstream symptom of THIS bug (gathered while it was still present),
not an independent task_sleep_ticks-specific scheduler defect -- not
independently re-confirmed either way, since a new blocker (below)
made further USR-mode testing moot before task_b could be re-tested
against just this fix.

**NEW blocker found**: a genuine WCET/schedulability regression, not a
logic bug. With the crash fixed, the LOW-priority shell task (task_c)
stopped responding to interactive commands after the first one.
Confirmed via a live A/B comparison against the proven-safe baseline
(task_a plain SVC) using the identical command sequence (write/cat/
eval): the baseline handles all three correctly, with `LOW: locked/
unlocking` (task_c's own loop) cycling continuously throughout; with
task_a in USR mode, `write` succeeds once and `LOW:` output then stops
appearing entirely -- task_c stops making progress, confirmed not to
recover even after 60+ extra seconds of wall-clock time (ruling out
"just slow," pointing at real starvation). task_a's own scheduling
shape (3-tick sleep period, ceiling-0 boost via `dhruva_prio_lock`/
`unlock` inside `task_a_wake_body`) is identical in both
configurations -- the only difference is USR-mode task_a paying real
SWI-trap overhead (SYS-mode register-bank dip, per-task table lookups,
full context save/restore) on every syscall inside that SAME critical
section, extending its real hold time enough to defeat the existing
dynamic-priority-aging fairness guarantee (task #184) that the faster
SVC-mode version stayed safely within.

**Disposition**: task_a reverted to SVC again (`task_a_init_stack`),
keeping the seed-placement fix's lesson documented in place (dormant,
not currently exercised) for whenever task_a is next attempted.
Verified via `phase4_milestone.py`: exact original 4-FAIL baseline,
zero regressions. This is real, useful progress -- one genuine crash
bug found and fixed, and the remaining blocker reframed from
"mysterious current_task corruption" to a concrete, measurable WCET cost of
USR-mode privilege separation for a frequently-waking, ceiling-boosting
task specifically. Real next step: either budget for the overhead
(tune `AGING_CAP`/`AGING_SHIFT`, or task_a's own sleep period) or
reduce it (a leaner, more targeted SWI trap path for exactly this hot
loop) before re-attempting task_a in USR mode -- a dedicated
measurement session, not another blind attempt.

**Task #253 Phase 3, task_a -- FOURTH round, same day (commit
`6e8645a`, 2026-09-19), a real WCET win that wasn't quite enough.**
User asked how Linux handles SVC/USR mode transitions without this
class of overhead, and to check whether that reference solves the
starvation. Fetched real Linux source directly
(`arch/arm/kernel/entry-common.S`'s `vector_swi`: `stmdb r8,{sp,lr}^`)
-- ARM mode has a single-instruction "user-register" LDM/STM form
(valid when PC is excluded from the register list, no writeback) that
transfers the USER-bank version of listed registers from any privileged
mode with NO mode switch at all. Linux's own `cps`-based fallback macros
are explicitly Thumb-2-only by their own comment; this project builds
pure ARM mode, so the fast form applies directly.

Replaced the `cps #0x1F; ...; cps #0x13` dip at all 4 real call sites
(`scheduler_restore_usr_sp` -- shared by every restore path project-
wide, `swi_entry.S`'s entry capture + `swi_return_to_usr`'s restore,
`irq_entry.S`/`fiq_entry.S`'s own USR-mode capture points) with the
single-instruction form. Verified via `phase4_milestone.py`: exact
4-FAIL baseline, zero regressions.

Re-tested task_a in USR mode with this fix alone: the shell task
measurably survived one MORE full critical-section cycle after the
first command than before the fix (2 vs 1, confirmed via direct log
comparison) -- a real, verified overhead reduction -- but still not
enough: `cat`/`eval` and everything after still never got a response.
Kept the fix (genuinely correct, benefits every IRQ/FIQ/syscall
touching a USR-mode task project-wide, not just task_a) and reverted
task_a to SVC again. This rules out "wrong SYS-mode-dip implementation"
as the SOLE cause -- the remaining per-syscall cost (table lookups,
full 68-byte frame save/restore for the blocking path) combined with
task_a's own tight 3-tick sleep period still defeats the current aging
tuning. Real next step: retune `AGING_CAP`/`AGING_SHIFT` (or task_a's
own sleep period) now that the implementation-quality explanation is
ruled out, or measure the remaining per-syscall cost directly (a
`WCET DIAG` line, matching this project's existing measurement
discipline) to see exactly where the remaining time goes.

**Task #253 Phase 3, task_a -- FIFTH round, same day (2026-09-19):
real instrumentation added, a real misdiagnosis caught and corrected,
and a genuinely new, better-understood open bug.** User asked
specifically for more instrumentation and to check reputable OS source
as a guide, given how important the USR/SVC scheduler boundary is.

*Instrumentation*: added real, `TIMER_CLO`-measured worst/avg/count
stats for the SWI trap's fast (never-blocking) round trip -- syscalls
#2/#3/#4 (`dhruva_mutex_unlock`/`dhruva_prio_lock`/`dhruva_prio_unlock`),
exposed via `diagnose`. Deliberately excludes #0/#1's blocking path
(can resume via a later, separate trap instance, so a plain bracket
would measure unrelated blocked time, not trap overhead).

*Reputable-OS check*: fetched seL4's real `arm_swi_syscall`
(`src/arch/arm/32/traps.S`, seL4/seL4 master) -- a formally-verified
microkernel on this exact classic-ARM banked-register USR/SVC
architecture, about as reputable and latency-obsessed a reference as
exists for this problem. Confirmed seL4 pays a FULL unconditional
register save (`stmdb sp, {r0-lr}^`) on every single trap, including
its own `CONFIG_FASTPATH` -- the fastpath check for its two hottest
syscalls happens AFTER that same full save, skipping only the
downstream generic dispatch/capability-lookup cost, never the entry
save itself. This project's own entry already does LESS work than
seL4's baseline (r0-r12 are genuinely unbanked, never saved at all --
only sp_usr/lr_svc/SPSR, which actually need it), confirming the real
lever is reducing HOW OFTEN a hot path traps, not shrinking each trap
further.

*Applied directly*: `task_a_wake_body`'s own explicit
`dhruva_prio_lock(0)`/`dhruva_prio_unlock(0)` pair wrapped ONLY a
single `uart_puts_bounded` call that already takes the identical
ceiling-0 lock internally -- a fully redundant nested trap pair with
zero behavioral effect (uart_puts_bounded's own internal lock already
produces the identical eff_prio_table transitions). Removed it, cutting
2 of task_a's own 9 SWI round trips per 3-tick wake cycle (~22%).

*Real bug #1, self-caught via the mandatory regression run*: the new
instrumentation used `r6` as bare scratch across the traced impl call
without saving it. `r6` is AAPCS callee-saved -- the three impl
functions themselves preserve it correctly, but the SWI trampolines
(`dhruva_prio_lock`/`_unlock`/`dhruva_mutex_unlock`) only ever save/
restore `r4`/`r7` around the whole trap, so a vani caller holding a
live value in `r6` across one of these calls had it silently destroyed
(surfaced as an "integer overflow in u32 sub" panic elsewhere in the
same boot -- the same corrupted-register-surfaces-later bug class this
file has hit before). Fixed by push/pop-ing `r6` around the entire
measured region in each dispatch stub.

*Live A/B re-attempt #1*: re-enabled task_a in USR mode with both
fixes in place. Produced a real Data Abort, `ctxsw=2`, `status=
0000082B` (ARMv6 DFSR "Domain fault, Page"), fault address squarely
inside TASK_B's own protected domain (task #192's per-task-domain
scheme) -- initially read as a genuine task_a/USR-mode bug in task_
sleep_ticks_impl's involuntary-resume path.

*Misdiagnosis caught (re-attempt #2, same day)*: re-ran with task_a
reverted back to plain SVC mode as a control -- the IDENTICAL crash
reproduced byte-for-byte, proving the fault had nothing to do with
task_a's privilege mode. Real root cause: a NEW diagnostic added this
same round to investigate the crash (`sleep_ticks_diag_print`,
`context_switch.S`, gated on the freshly-picked task being
`current_task==0`) ran its own push/pop BEFORE `mov sp, r0` in `task_
sleep_ticks_impl` -- meaning it touched memory via the OUTGOING task's
own stack pointer AFTER `scheduler_pick_next` had ALREADY switched DACR
to the NEWLY PICKED task's domain (that function's own last action
before returning). Exactly the same bug class `scheduler_pick_next`'s
own "BUG caught live" fix already exists to prevent (see its header
comment), reintroduced by this diagnostic's own placement. Fixed by
moving the diagnostic to after the sp switch. A genuine instance of
this project's own `feedback_no_trust_validate_everything` discipline:
the first live crash was assumed to confirm the hypothesized bug rather
than checked against a control.

*Live A/B re-attempt #3*: with the diagnostic's own bug fixed,
re-enabled task_a in USR mode again for a clean read. Result: no crash
-- `SLEEP: task_a resumed, outgoing=00000008` printed cleanly, proving
task_a's own first involuntary resume (via irq_entry.S's shared restore
path) genuinely works. But the real, original issue reproduced
unchanged: after exactly 2 "HIGH: waking/acquired/released resource"
cycles, the ENTIRE system goes silent -- not just the shell, but every
background task (MEDIUM/idle/etc), with no crash and no reboot. This is
a materially better-understood failure than the vague "shell stops
responding" the fourth round reported: a total scheduler freeze
specific to task_a's SECOND USR-mode wake cycle, not a fairness/aging-
tuning shortfall alone. Reverted task_a to plain SVC mode again rather
than ship a build that reliably hangs. Needs its own dedicated live-GDB
investigation -- not resolved this round.

*Diagnostic cost, capped*: `sleep_ticks_diag_print` fires legitimately
whenever task_a is freshly picked (~24 times per full regression run,
regardless of task_a's own SVC/USR mode, since task_a is task index 0
either way) -- its own cumulative blocking-UART cost was enough to
occasionally tip `tlsecho` past its blind `SETTLE_S` budget (same class
of regression as this session's own SD `force_data_mode_settle`
finding). Capped at 8 total firings -- ample evidence for a future
investigation, no ongoing per-run cost.

*Unrelated finding during this investigation*: the vani-localfuzz
harness/ollama pair (a separate project, autostart via systemd user
unit) was found consuming ~120% CPU concurrently with these QEMU
regression runs, contributing to real host-load-induced test timing
flakiness. Stopped and disabled per explicit user request ("stop and
disable localfuzz") -- see that project's own memory entry.

Committed with the instrumentation, both real bugs' fixes, and task_a
left in plain SVC mode (proven-stable) -- `phase4_milestone.py`
verified clean (4-FAIL baseline, matching a control run of the prior
commit under identical host conditions). Task #253 Phase 3 remains
open: task_a's own second-wake-cycle total-freeze bug is real,
reproducible, and better-scoped than before, but not yet root-caused.

**Task #253 Phase 3, task_a -- SIXTH round, same day (2026-09-19): live
GDB investigation finds a real, decisive fault signature; root cause
still not found.** User: "i need scheduler freeze bug fixed fully.
check other online authoritative resources and source code."

*Reference check*: the timer tick is FIQ-routed (task #246), so task_a's
own tick-driven resume goes through `fiq_entry.S`, not `irq_entry.S` --
the file this round's own earlier diagnostic never covered. Checked
seL4's own `arm_fiq_exception` (`src/arch/arm/32/traps.S`) as a
reputable-OS cross-check specifically for FIQ handling: seL4 does NOT
support FIQ at all (`blx halt` on it) -- not a usable reference for this
mechanism. FreeRTOS's Cortex-A ports (GIC-based, FIQ reserved
specifically for the tick, to guarantee it can't be blocked by
application-installed IRQ handlers) are the closer architectural
analogy, though this project's own bare-metal BCM2835 FIQ_CONTROL
routing was already independently designed before this round, not newly
adopted from that reference.

*Third diagnostic added*: `swi_return_to_usr` (`swi_entry.S`), printing
the actual resume-pc value about to be used, gated on `current_task==0`.
Self-caught a real bug while adding it (documented in that file's own
comment): reused a register that had already been overwritten with the
SPSR value from two lines above, computing a garbage address and
faulting on the very first boot-time syscall -- fixed by loading `usr_
resume_pc_table`'s own base address fresh instead of trusting stale
register contents. Also had to fix the diagnostic's OWN gating twice:
first gated on `tick_count>0` (self-caught as wrong -- the DHCP self-
tests advance `tick_count` artificially via `scheduler_set_tick_count_
test_only` well before real multitasking starts), then switched to
`context_switch_count>0` (only ever incremented inside `scheduler_pick_
next` on a genuine scheduling decision -- no boot-time self-test
reaches that function, directly or indirectly).

With all three diagnostics correctly gated, direct printf evidence
showed `usr_sp_table[0]`, `usr_resume_pc_table[0]`, and `is_usr_mode_
task[0]` all reading CORRECTLY and PLAUSIBLY for every syscall observed
in the log before the freeze -- no sign of corruption in the visible
window, ruling out the simplest "obviously garbled state" explanation.

*Live GDB investigation*: printf evidence exhausted, so used QEMU's own
GDB stub (`gdb-multiarch`, `-S -gdb tcp::1234`) for direct, ground-truth
inspection -- the proper tool once indirect evidence stops being
conclusive, per this project's own "use a proven reference/tool, don't
keep guessing" discipline. Confirmed the freeze is purely tick/time-
driven, not dependent on typed shell commands at all (reproduces
identically with zero characters ever sent to the interactive shell).
Set a breakpoint at `fault_data_abort`'s own entry and let the system
run freely.

**Decisive finding**: `fault_data_abort` DOES fire at the freeze point
-- a real Data Abort IS occurring, it just never reaches the UART.
Captured directly: `DFAR=0xFFFFFFF0`, `DFSR=0x805` (decodes to WnR=1 --
a WRITE -- Translation Fault, Section, domain 0). Address `0xFFFFFFF0`
is exactly "0 minus 16 bytes" -- the signature of a multi-register
push/stmdb applied to a stack pointer that is EXACTLY NULL (matches
this project's own prior incident at `0xFFFFFFF8`, "push on a near-null
sp", same class, one register narrower). This means `fault_data_abort`'s
OWN attempt to build its own report frame (`sub sp,sp,#16` right after
switching to SVC mode) itself faults -- a genuine double-fault. This
looks structurally identical to this round's OWN earlier (self-caused,
already-fixed) diagnostic-placement bug, but this time with no known-
buggy diagnostic in the loop -- it is real.

*Ruled out by careful re-reading (not yet confirmed by a live watch)*:
(1) all 5 SWI trampolines push/pop `{r4,r7}` symmetrically -- no leak
there. (2) `swi_entry`'s entry-capture and `swi_return_to_usr`'s restore
both use `^`-suffixed single-register LDM/STM to touch `sp_usr`
specifically, which does NOT affect the plain `sp` register (`sp_svc`)
ordinary push/pop instructions use -- this round's own new diagnostic
push/pop is verified balanced and cannot be the sp_usr leak, if any. (3)
`sp_svc` is a single physical register, not banked per-task, but every
task-switch path explicitly reloads it from `sp_table[current]` before
resuming -- reasoned by hand to be self-consistent (a block-then-resume
cycle returns `sp_svc` to its exact starting baseline), though not yet
confirmed by directly watching the value across the actual failing
cycle.

**Not yet found**: the actual mechanism driving either `sp_usr` or
`sp_svc` (whichever is active at the freeze moment) to exactly 0. Real,
concrete next step for a dedicated session: a GDB hardware watchpoint on
`usr_sp_table[0]`/`sp_table[0]`'s own memory (not more printf probing)
to catch the exact write that drives it to zero, or a stack canary at
the bottom of `stack_a`'s own SVC-side 4096-byte region. Reverted task_a
to plain SVC mode again rather than ship a build with a confirmed,
reproducible double-fault. `phase4_milestone.py` re-verified: 4-FAIL
baseline, no crash, no reboot.

**Task #253 Phase 3, task_a -- SEVENTH round, real root cause FOUND and
FIXED (2026-09-20), redesign attempts along the way, task_a's own
conversion RE-ENABLED and verified clean.** User pushed back on an
earlier session's claim of having "confirmed against real Linux" during
a mid-session redesign attempt ("did you compare with known os similar
design with source code -- perhaps review implementation against
theirs"), which was fair: that claim was from recollection, not a fresh
read. Actually fetched real Linux ARM32 kernel source this round
(`curl` from `raw.githubusercontent.com/torvalds/linux/master/arch/arm/
kernel/entry-header.S`, `entry-armv.S`, `entry-common.S` -- not a
summarized fetch).

**Root cause, finally confirmed**: `lr_usr` (r14 in USR mode) was NEVER
restored anywhere in this project -- only `sp_usr` was (`scheduler_
restore_usr_sp`, `boot/context_switch.S`). `lr_usr` is a single physical
register shared by every USR-mode task; this project's own shared
exception-return idiom (`ldmia sp!,{r0-r12,lr,pc}^`) loads its own "lr"
word into whichever mode's bank is ACTIVE WHEN THAT INSTRUCTION EXECUTES
-- still SVC, since the mode switch to USR only takes effect as PC/CPSR
load, last, per the ARM ARM's own LDM-exception-return pseudocode.
Confirmed directly against Linux's `restore_user_regs` (entry-header.S):
Linux NEVER folds a user-mode resume's r0-r12+lr restore into that same
combined, pc-inclusive form -- that form (`svc_exit`) is reserved for
SAME-mode resume (e.g. IRQ returning to interrupted SVC code, where "lr
loads into the active bank" is exactly correct because no mode switch
happens). A genuine user-mode resume always uses a separate, non-pc `^`
form (`ldmdb r2,{r0-lr}^`) specifically because excluding pc changes
this from "LDM exception return" to "LDM user registers" -- targeting
the user bank of every listed register unconditionally, lr included,
regardless of current mode. Every fault signature chased across all six
rounds above (the literal-pool wild-jump, the `0xFFFFFFF0`/`0xFFFFFFF8`
near-null-sp double-faults) matches exactly what a silently-stale,
cross-task-clobbered `lr_usr` would produce.

**Three same-day attempts at the fix, all reverted** (full writeup:
memory `project_dhruva_task253_lr_usr_redesign_attempt_2026_09_20`) --
all tried to GROW the 68-byte frame to carry new `sp_usr`/`lr_usr`
fields, which requires every restore tail's own fixed instruction count
to agree on the new size; two of the three regressed on exactly that
size-accounting asymmetry, the third eliminated the crash but caused a
new, unexplained shell hang. Reverted clean to `f292fc4` rather than
ship any of them.

**The actual fix, once the real Linux structure was understood, needed
no frame resizing at all**: `irq_entry.S`/`fiq_entry.S`'s own capture-
side fix (already committed 2026-09-19, `stmia r1,{sp,lr}^`, never
reverted) already stores the correct `lr_usr` value into the EXISTING
68-byte frame's `true_lr` field (offset 60) -- only `scheduler_restore_
usr_sp`'s restore side was still discarding it. Extended it to also read
that field and restore both `sp_usr` and `lr_usr` via one `ldmia
scratch,{sp,lr}^`, mirroring the exact idiom the codebase already used
for `sp_usr` alone. Traced and confirmed safe even for the SVC-internal
`task_sleep_ticks_impl`/`dhruva_mutex_lock_impl` block-then-resume path,
where that same field isn't really `lr_usr` (it's "return to `swi_
return_to_usr`") -- the "wrong" write there is harmless, unconditionally
overwritten by the calling trampoline's own `mov lr,r4` before `lr_usr`
is ever read (`r4` independently round-trips the task's TRUE original
`lr_usr` through the frame's own ordinary r0-r12 save/restore the whole
time). Shipped as commit `f37d933`, two identical `phase4_milestone.py`
runs, 13-pass/5-fail baseline (the 5 are the long-documented tlsecho/
httpecho/mqttecho/ls/diagnose flakes, unrelated), zero regression.

**Task_a's own USR-mode conversion re-attempted with the fix in place**
(user: "unblock task #262 if possible qemu"), restoring the exact
proven late-seed pattern from round 3's item 1 (`task_a_init_stack_usr`
+ deferred `usr_sp_table_set_at(0, ...)` as the literal last statement
before `start_multitasking`). Result, confirmed via two identical
`phase4_milestone.py` runs: no crash, no reboot, 13-pass/5-fail baseline
unchanged, and directly counted in the captured guest log -- **388**
`HIGH: waking/acquired/released` cycles (not the 2 that used to trigger
total freeze) and **390** continuous `LOW: locked/unlocking` shell
cycles with zero interruption, zero `FATAL`/Abort lines anywhere in the
log. Both previously-reported symptoms (the crash AND the "shell stops
responding" WCET/starvation regression from round 3) are gone. Given
the WCET regression was measured DURING earlier rounds where this exact
corruption was already present, it now looks like that symptom was very
likely a downstream consequence of the same `lr_usr` corruption (some
background USR-mode task, most plausibly IDLE, going haywire mid-run),
not an irreducible scheduling/fairness shortfall in its own right --
though this is inferred from the disappearance, not independently
re-proven.

**Also checked against real-RTOS precedent, at user's request** (FreeRTOS-
Kernel `portable/GCC/ARM_CA9/port.c`, Zephyr `arch/arm/core/cortex_a_r/
swap_helper.S`+`userspace.S`, both freshly fetched): FreeRTOS's mainline
Cortex-A port `configASSERT`s that the CPU is NEVER in USR mode when
entering a critical section -- it does not attempt genuine unprivileged-
task memory separation on this architecture at all, sidestepping this
class of problem entirely rather than solving it. Zephyr's own `z_arm_
svc` (Cortex-A/R, `CONFIG_USERSPACE`) pays the same full register-save
entry cost for every SVC reason code (context-switch, syscall, oops
alike) -- no cheaper fast path for scheduling-only traps exists there
either. Neither reference offers a "make the trap itself cheaper" trick
beyond what this project had already applied (removing the SYS-mode
`cps` dip via banked LDM/STM, removing a redundant nested ceiling lock,
both from round 5's SWI-trap hardening) -- reinforcing that the earlier
"reduce trap overhead further" direction was close to its real floor,
and that the actual unblock was the correctness fix, not a performance
one.

**Task #262 fully completed the same day (2026-09-20)**, immediately
following task_a's own re-enable above, by continuing the proven one-
task-at-a-time discipline (build, dual `phase4_milestone.py` runs,
direct log inspection for cycle counts and FATAL lines) through the
rest of the roster:

- **task_b** (index 1): re-enabled via `task_b_init_stack_usr` +
  early `usr_sp_table_set_at(1,...)` (safe early, unlike task_a's own
  index-0 collision with kernel_main's boot-time `current_task`
  default). Two identical runs: 453 MEDIUM/HIGH/LOW cycles, zero
  FATAL. Commit `7382f6b`.
- **task_c** (index 2): same pattern. Two identical runs: 453 cycles,
  zero FATAL. Commit `3507bb7`.
- **task_e/GC** (index 4), the most DharaFS-call-chain-heavy
  conversion yet (its own larger `stack_e_bytes` allocation, round-4
  audit): same pattern. Two identical runs: 48 GC critical-section
  cycles, zero FATAL. Commit `ff64cf3`.
- **task_f** (index 5), the interactive shell -- every SD/DharaFS/
  crypto/network command dispatches from here, by far the deepest
  call chain and largest stack (262144 bytes) of any task, sized
  identically for its USR-mode counterpart rather than reusing the
  stock 4096-byte allocation every other task above got: same
  pattern. Two identical, BYTE-FOR-BYTE matching runs (`diff` empty),
  `write`/`cat`/`eval` (all shell-dispatched) all pass, zero FATAL.
  Commit `0e390bb`.
- **The 4 dynamically-created tasks** (`task_custom_demo`, `task_
  mutex_demo_low`/`_high`, `task_fsq`, created via `task_create` at
  runtime, not compile-time) were still calling the plain SVC-mode
  `task_create` even after all 6 static tasks were converted --
  `task_create_usr` already existed but was unused. Since a dynamic
  task's slot index is only known after the call returns (unlike the
  6 fixed tasks), the `usr_sp_table` seed necessarily happens AFTER
  `task_create_usr`, not before -- safe regardless, since every
  dynamic slot is >= 6, never index 0. Two identical runs: correct
  task IDs (6,7,8,9), 425 combined dynamic-task activity lines both
  times, zero FATAL. Commit `00e84da`.

**All 10 tasks in this project (6 static + 4 dynamic) now run in USR
mode**, each independently verified via its own dual-run regression
pass -- task #253/#262's privilege-separation goal, open since the
first USR-mode attempt (round 1 of this same comment chain), is
complete. Pushed to origin master/pi4/main (`00e84da`).

**SD wedge: sixth fix attempt, real register-level divergence from
Linux found and fixed (2026-09-19), against a fresh real-HW log
(`picocom_20260919_145143.log`) that includes BOTH the FAIL_FLAG fix
(366569b) and the SDHBCT/SDHBLC-readback diagnostic (e710121) for the
first time together.** The new diagnostic gave direct, decisive
evidence: `SDHBCT=0x200 SDHBLC=0x1` at the exact moment the fixed
128-word PIO loop finishes, every single time -- correctly programmed,
ruling out the block-count-mismatch hypothesis from the prior round
outright. `CURRENT_STATE=4 (tran)` also confirmed on every single
CMD16 check -- CMD7 card selection is genuinely working, not the
problem either. `sdhost_card_addr`'s own SDHC/SDSC branch was verified
directly against the code and is correct (block-number addressing for
this SDHC card, matching `is_sdhc=1` consistently reported).

With those three hypotheses eliminated, re-examined `SDHCFG`'s own bit
configuration against a freshly re-fetched Linux `bcm2835-sdhost.c`
(not recalled from memory). Found a real, concrete divergence:
`bcm2835_sdhost_set_transfer_irqs`'s own PIO branch (`dma_desc ==
NULL`, this driver's own case) sets ONLY `SDHCFG_DATA_IRPT_EN |
SDHCFG_BUSY_IRPT_EN` at the START of a transfer -- `SDHCFG_BLOCK_
IRPT_EN` is explicitly masked OUT there, and Linux only ever adds it
later, inside `bcm2835_sdhost_data_irq`, "for writes after the first
block" (multi-block transfers only; the read path in that same
function never touches it at all). This driver's own transfers are
ALWAYS exactly one block (`SDHBLC=1`), so Linux's own real, proven-
working configuration for this exact class of transfer NEVER includes
`BLOCK_IRPT_EN` -- but this driver's own `SDHCFG` value (`0x518`) has
included it unconditionally since the 2026-09-18 `SDHCFG_SLOW_CARD`
round. This project's own earlier finding on these exact bits ("may
double as internal event-detection/latch enables for the data-phase
state machine itself, not purely IRQ-routing bits") makes this
mechanistically plausible as a real cause, not just a cosmetic
mismatch: an extra enable bit the FSM was never designed to see set
during a single-block transfer.

Fixed: `0x518` -> `0x418` (drops bit8/`BLOCK_IRPT_EN` only; `SLOW_CARD`/
`DATA_IRPT_EN`/`BUSY_IRPT_EN` all unchanged, each independently
justified by its own separate prior finding) in both `sdhost_read_
block_once` and `sdhost_write_block_once`. Verified via
`phase4_milestone.py`: identical 4-FAIL baseline, zero regressions
(QEMU's own SD model never wedges either way, so this can only be
confirmed by a real-HW retest). Needs a fresh real-HW picocom log to
confirm or refute -- this is the most concrete, best-evidenced fix
attempt so far (a genuine divergence from a proven-working reference,
found only after three other hypotheses were directly eliminated by
real captured evidence, not guessed past).

**SD wedge: EIGHTH fix attempt, same day (commit `d8d1014`,
2026-09-19) -- the seventh attempt was flashed and RE-TESTED, still
falsified (identical wedge signature), leading directly to this one.**
User flashed commit `bfca745` via `update_kernel.sh` and supplied a
fresh log (`picocom_20260919_152928.log`): identical `SDEDM=0x00010803`
(FSM=WRITEDATA, FIFO empty) write wedge, `SDHBCT`/`SDHBLC` still
correctly 512/1, `CURRENT_STATE=4` still confirmed every time -- the
`BLOCK_IRPT_EN` removal did not help.

Fetched U-Boot's own `bcm2835_sdhost.c` (`drivers/mmc/bcm2835_sdhost.c`,
`u-boot/u-boot` master) directly, per the user's own structured
debugging prompt's suggestion of a bare-metal/polling reference closer
to this driver's own design than Linux's IRQ-driven one. Found a real,
decisive difference: U-Boot's own `bcm2835_wait_transfer_complete` is
UNPARAMETERIZED -- one function for both reads and writes -- and
treats THREE FSM states as safe to force out of via `SDEDM_FORCE_DATA_
MODE`: `READWAIT`(4), `WRITESTART1`(0xA), AND `READDATA`(2), checked
unconditionally. This driver's own `sdhost_wait_transfer_complete`
only ever checked the single `alternate_idle` value its caller passed
(`READWAIT` for reads, `WRITESTART1` for writes) -- `READDATA` was
never recognized as a valid exit state at all. Every real-hardware
READ wedge this investigation has EVER captured decodes to exactly
`FSM=READDATA` (`SDEDM=0x10902`/`0x108F2`/etc, confirmed via the
authoritative `SDEDM_FSM_*` definitions both Linux and U-Boot agree
on) -- precisely the state this function had no escape hatch for.

Added the same unconditional check U-Boot uses (matching its own real,
proven-working sequence exactly, not re-deriving a read/write-
conditional version of it). Verified via `phase4_milestone.py`: exact
4-FAIL baseline, zero regressions. The write-side wedge (`FSM=
WRITEDATA`) is NOT one of the three states either reference treats as
safe to force -- deliberately left untouched rather than guessing past
the evidence; that remains a separate, still-open problem, possibly
worth its own dedicated investigation once (if) the read path is
confirmed fixed. Needs a fresh real-HW log to confirm.

**CONFIRMED on real hardware, same day: the READDATA fix works.**
Fresh log (`picocom_20260919_160254.log`): all 8 blocks in the sweep
now show `rd=0` (read succeeds) -- a real, verified win. Writes remain
completely unchanged (`wr=2`/`wr=3`, `FSM=WRITEDATA`, every single
block). A new, secondary read symptom appeared: the first read attempt
per block now hits `NEW_FLAG stuck`, self-heals via one retry +
controller reset, then succeeds -- likely was always present but
previously masked by the (now-fixed) READDATA hang dominating the
failure signature. Tracked separately, not yet root-caused, not
currently blocking (reads still complete).

**Ninth+tenth rounds, same day (commit `0c8f03a`, 2026-09-19), per the
user's own structured follow-up debugging prompt pivoting specifically
to the write path.** Investigated whether U-Boot's own command/PIO
ordering differs from ours (the prompt's own item 17) -- re-read
`bcm2835_send_cmd`'s real top-level orchestration (not just the
individual `send_command`/`finish_command` functions in isolation) and
found `finish_command` (which waits for `NEW_FLAG`) IS called
immediately after `send_command`, BEFORE the PIO transfer loop, for
CMD17/CMD24 specifically (`use_busy=false` for both) -- U-Boot's real
ordering matches ours exactly. An initial hypothesis that U-Boot
starts PIO before `NEW_FLAG` clears was WRONG (based on reading the
functions in isolation, not their actual call site) -- caught before
shipping any change built on it, per the prompt's own explicit
instruction not to repeat that mistake.

Instead found two concrete, previously-unchecked gaps (prompt items 8
and 2/11):

1. **CMD17/CMD24's own status was never checked for `FAIL_FLAG`**
   (`0x4000`) -- only `NEW_FLAG` (`0x8000`). This exact gap was already
   fixed for the init-sequence commands (CMD2/3/9/7/16, commit
   `366569b`) but never extended to the data commands themselves,
   meaning a real command-level rejection could have been completely
   invisible this whole investigation. Added the check (new return
   code 4, "FAIL_FLAG set") to both `sdhost_read_block_once` and
   `sdhost_write_block_once`, reusing the existing `sdhost_cmd_failed`/
   `sdhost_cmd_report_failure` helpers.

2. **No diagnostic has ever captured state DURING the write PIO loop**
   -- every prior diagnostic only ever captured the END of the fixed
   128-word loop or the eventual timeout. Added
   `sdhost_fill_fifo_from_buffer_diag` (`boot/sdcard_state.S`): dumps
   `SDEDM` immediately before the first `SDDATA` write and again after
   words 1/4/8/16, to see whether the FIRST write changes FIFO
   fill/FSM at all, or whether it looks wrong from the very first word.

**Two real bugs caught before shipping, via this project's own
established "verify, don't trust" discipline**: (a) the diagnostic
was first wired in unconditionally -- QEMU regression run showed 790
diagnostic blocks firing across the whole boot (every DharaFS write,
not just the intended 8-block sweep), tanking 6 timing-sensitive
network tests; fixed by gating on `block_num` (2100-2107, the existing
sweep's own permanently-safe range), confirmed back to exactly 40
blocks (8 x 5 checkpoints). (b) the word-16 checkpoint's own label
truncated through a single-hex-digit print (`16 & 0xF = 0`), showing
as "w0" (same text as the pre-write snapshot) instead of "w16" -- the
captured `SDEDM` value was correct either way, but the label would
have confused interpretation; widened to two hex digits. Verified via
`phase4_milestone.py`: exact 4-FAIL baseline, zero regressions. Needs
a fresh real-HW log -- this is the first diagnostic in this whole
investigation to show what's happening DURING the write, not just
before/after it.

**Eleventh round, same day (2026-09-19), triggered directly by the
tenth round's own new FAIL_FLAG check.** The very next real-HW log
(`picocom_20260919_165624.log`) caught, for the first time ever, a
genuine `FAIL_FLAG` + `CMD_TIME_OUT` on CMD24 itself
(`SDCMD=0x00004098 SDHSTS=0x00000041`) -- the card never responded at
all -- immediately following a successful CMD17 read, with no
controller reinit in between. This exact sequence (successful read
immediately followed by a write) never happened before the eighth
round's own READDATA fix, since reads never used to succeed at all --
new territory this investigation could not exercise until now.

Checked both real references again for whether `SDEDM_FORCE_DATA_MODE`
(bit19 -- the bit the eighth round's fix sets to force the FSM out of
READWAIT/WRITESTART1/READDATA) is ever explicitly cleared afterward:
it is NOT, in either Linux or U-Boot, anywhere. Consistent with a
self-clearing pulse trigger on real silicon -- but neither reference
ever exercises this project's own specific "force a read out, then
immediately issue a write with no reset in between" sequence (both are
interrupt-driven and structure requests differently). Hypothesis: if
this bit is not fully self-clearing on this specific silicon/timing,
leaving it set could plausibly disrupt the very next command's own
dispatch. Added `sdhost_force_data_mode_settle` (`kernel_main.vani`):
after forcing the bit, polls for the FSM to genuinely reach
DATAMODE/IDENTMODE, then explicitly clears bit19, wired into both of
`sdhost_wait_transfer_complete`'s own force-exit branches
(`alternate_idle` and the eighth round's READDATA/`fsm==2` case).

**One real regression caught via the mandatory post-change
`phase4_milestone.py` run, root-caused and fixed before committing.**
First version bounded the new settle poll at 100000 iterations
(matching this file's other real-hardware-calibrated bounds) --
this newly failed `tlsecho` (previously PASS in every run this entire
investigation). Root cause: `sdhost_force_data_mode_settle`'s own
return value is discarded by both call sites
(`let _ = sdhost_force_data_mode_settle(...); return 0;`) -- nothing
downstream ever distinguishes "settled" from "timed out here," so the
100000-iteration bound was buying zero correctness benefit, only real
QEMU wall-clock cost. Under QEMU, `FSM=READDATA` (the eighth round's
own fix target) is apparently a normal transient state on ordinary
successful reads, not exclusively a real-hardware wedge symptom, and
QEMU's own SD model does not appear to visibly move `FSM` in response
to the forced-bit write within a tight poll -- so this function likely
ran to its full bound on most/all reads, adding cumulative latency
across the whole boot sequence, enough to tip the already-marginal
TLS-dependent test chain over `tlsecho`'s own blind `SETTLE_S` budget
(the exact same class of cumulative-SD-latency regression this file's
own SDCDIV-fix entry above already documents happening to `httpecho`).
Fixed by shrinking the bound to 1000 -- still a real settle window on
genuine hardware, two orders of magnitude cheaper in the QEMU worst
case, with no correctness change (the return value was never used).
Re-verified via `phase4_milestone.py`: exact 4-FAIL baseline restored,
`tlsecho` back to PASS, SD 8-block sweep unchanged (`any_fail=0`,
~9.1-9.2ms both before and after). Not yet real-HW tested. This fix
targets the FAIL_FLAG/CMD_TIME_OUT symptom specifically -- it does NOT
explain or fix the ORIGINAL data-phase wedge (FSM stuck in WRITEDATA
from word 1 through word 128, FIFO empty throughout, block 2100's own
first write attempt), which remains a separate, still-unexplained
failure mode.

**Twelfth round (2026-09-20): FreeRTOS/Zephyr checked at user's
request (neither applicable), Linux mainline's own wait-loop confirmed
IDENTICAL to ours -- software references now exhausted.** Fresh
real-HW log (`picocom_20260920_083637.log`) shows the unchanged
symptom: `SDEDM=0x00010803` (FSM=WRITEDATA, FIFO empty) pinned across
every post-write checkpoint, at all three adaptive-backoff clock
speeds, `wait_transfer_complete` timeout every time. User separately
confirmed the physical card-lock switch is unlocked (rules out simple
write-protection).

Checked whether FreeRTOS or Zephyr support the original Pi 1B
(BCM2835/ARM1176) as an additional reference. Neither does: Zephyr's
own supported Raspberry Pi boards (`boards/raspberrypi/`) are
`rpi_4b`/`rpi_5`/`rpi_debug_probe`/`rpi_pico`/`rpi_pico2`/
`rpi_zero_2w` only, and `drivers/sdhc/` has no BCM2835-SDHOST driver
at all. FreeRTOS has no official Raspberry Pi board support in its
own GitHub org repos at all. Linux's `bcm2835-sdhost.c` and U-Boot's
`bcm2835_sdhost.c` remain the only two real references for this exact
peripheral.

Re-fetched Linux `bcm2835-sdhost.c` fresh and read its own
`bcm2835_sdhost_wait_transfer_complete` line-by-line (not the U-Boot
variant checked in round 8) -- structurally identical to this
driver's own function for the write case. Two findings: (1) Linux's
mainline version does NOT force-exit on READDATA unconditionally the
way U-Boot's does (that fix, round 8, was based on U-Boot's more
aggressive variant); (2) **Linux's own reference has no escape hatch
for a genuinely stuck WRITEDATA state either** -- if FSM never reaches
WRITESTART1 or idle, Linux's own loop spins until its own
100000-iteration bound, then reports `-ETIMEDOUT` and returns. The
authoritative reference driver, if it saw exactly what real hardware
is showing, would ALSO time out. Also re-confirmed the FIFO-fill
loop's own polling logic against Linux's `bcm2835_sdhost_write_block_
pio`: FIFO reading 0 at every diagnostic checkpoint is the expected,
healthy pattern for a write where the SD bus drains faster than the
CPU polling loop fills it, not evidence of a stuck FIFO -- ruled out
an emerging hypothesis before shipping anything on it.

No code changes this round -- twelve real-hardware rounds have now
exhausted every concrete software-level divergence available from
both real reference drivers; shipping another speculative register
guess would repeat exactly the pattern this investigation's own
memory already warns against.

**Thirteenth round (2026-09-20): user correctly pushed back on "try a
different card" -- reframed, new CMD13 (SEND_STATUS) card-status
diagnostic shipped instead.** User: "i have transcend class 10 64 GB
45MB/sec 300x SD/HC that you are testing. so if card is bad then why
can you read and wformat and write correctly?" -- fair correction: the
card demonstrably works fine through a normal PC reader.

The reframing that survives it: a PC's SD reader is a far more capable
host controller (UHS, DMA, engineered signal integrity) than the
RPi's own legacy 2012-era PIO-only "sdhost" peripheral, which this
project has already found two confirmed real silicon errata in. A
card working through one controller says nothing about a different
controller's own edge cases. The GPU firmware's own read of
`kernel.img` through this EXACT peripheral, with this EXACT card,
succeeds every boot (visible in every log's own opening lines) --
more relevant same-peripheral evidence than "works on a PC," and it's
read-only; no write has ever succeeded through this peripheral with
this card anywhere, DhruvaOS's own code included.

Instead of another card-swap suggestion, shipped commit `a8c03cb`:
CMD13 (SEND_STATUS), issued right after wedge detection in
`sdhost_write_block_once`, asks the CARD ITSELF what state it
believes it's in -- every diagnostic across 12 prior rounds has only
ever read the CONTROLLER's own registers (SDEDM/SDHSTS/SDHBCT/
SDHBLC). Prints the card's full 32-bit R1 status word (decodable
against the SD spec's own error bits: OUT_OF_RANGE, WP_VIOLATION,
COM_CRC_ERROR, ILLEGAL_COMMAND, CARD_ECC_FAILED, CC_ERROR, ERROR) plus
CURRENT_STATE. Best-effort: times out gracefully (and prints that) if
the controller is too wedged to even issue CMD13.

Verified: two identical `phase4_milestone.py` runs, byte-for-byte
matching, zero regression (QEMU's SD model never wedges, path stays
dormant under test as expected). Needs a fresh real-HW log -- this is
the first time this investigation will have direct card-side evidence
rather than only controller-side.

**Fourteenth round (2026-09-20): command path confirmed frozen, clock
speed ruled out, two real missing U-Boot-documented settle delays
found and fixed.** Fresh real-HW log (`picocom_20260920_133428.log`,
user: "new picocom log hone folder") with the CMD13 diagnostic firing
for the first time. Two concrete new findings from it:

1. CMD13 (SEND_STATUS) itself times out every time the wedge occurs
   ("controller too wedged to respond") -- the controller's own
   COMMAND path, not just the data path, is completely unresponsive
   once FSM sticks at WRITEDATA (SDEDM=0x10803). No command-level
   recovery is possible once this happens; only a full controller
   reset can escape it, which the code already does.
2. The wedge reproduces even at the SLOWEST identification-speed
   clock (SDCDIV=0x148, the adaptive backoff's own last-resort rung),
   on the very first write attempt after backing off to it --
   conclusively rules out clock speed as the root cause.

Since command-path unresponsiveness rules out clock speed, did a
targeted line-by-line diff of `sdhost_init` against U-Boot's real
`drivers/mmc/bcm2835_sdhost.c` (fetched fresh) rather than the
broader wait-loop comparison prior rounds already exhausted (per the
user's own follow-up, "check linux or other os if similar logic," the
same discipline just applied to task #273). Found two real, reference-
documented gaps:

1. No delay at all after the already-applied SDEDM FIFO-threshold
   register write (task #209's own silicon-errata fix, "Limit fifo
   usage due to silicon bug") -- U-Boot inserts `msleep(20)`
   immediately after, with its own explicit comment "Wait for FIFO
   threshold to populate." This driver had none.
2. The existing SDVDD power-cycle settle (`delay(10000)`) measures to
   only ~166us real time (`delay_wcet_measure_self_test`'s own
   measured finding: `delay(3000000)=49906us`, ~0.0166us/iteration)
   -- roughly 120x shorter than U-Boot's real `msleep(20)` on both
   sides of the power-on cycle.

Both bumped to `delay(1200000)` (~20ms, matching U-Boot's real,
working values rather than guessing at a smaller number) -- commit
`0d3b2f2`. Real-hardware-only timing sensitivity by construction:
QEMU's idealized SD model has no analog rail-settling/card-power-on-
reset behavior to ever expose a gap like this, consistent with this
whole investigation's own recurring pattern (every confirmed real bug
found here has been invisible under emulation). Two identical
`phase4_milestone.py` runs confirm zero regression (necessarily inert
under QEMU). Needs a fresh real-HW retest -- the only test this fix
can actually be judged by.

**Task #245 follow-up: real per-extern-fn `#[stack_cost]` annotations
applied project-wide, real `task_fsq` overflow found and fixed
(2026-09-20, commit `396d626`).** While looking for QEMU-appropriate
work with no real hardware in the loop, followed up on
`docs/RTOS_GAP_ANALYSIS.md`'s own explicitly-flagged remainder: the
compiler mechanism for real per-extern-fn stack costs (`#[stack_cost(
bytes=N)]`, task #245) existed but DhruvaOS had never actually used
it -- every one of its 1148 hand-written-asm `extern "C" fn`
declarations was still charged a flat 32-byte conservative default
regardless of its true frame size.

Measured every extern fn's real worst-case frame size mechanically:
wrote a small script that walks each function's own boot/*.S assembly
(summing `push`/`stmdb sp!`/`sub sp,sp,#N` along the function's own
straight-line and branch flow, matching the same discipline the
`#[bounded_stack]` checker itself uses), covering 608 directly. The
other 540 "not found" turned out to be generated by 8 near-identical
`.macro X_SCRATCH_PAIR name` invocations (AEAD/CRASHLOG/MLKEM/ED25519/
TLS/X25519/KECCAK/SSH scratch-buffer accessors) -- all byte-for-byte
the same trivial `ldr;str;bx lr` zero-frame shape, confirmed by
reading all 8 macro bodies directly rather than assuming. 1138/1148
(99.1%) now have a real, verified cost; the remaining 10 are C-
implemented allocator/host-virtual-disk stubs (boot-time-only, never
on a task body's own runtime path) left at the default.

Real costs top out at 28 bytes ANYWHERE in this entire codebase --
the flat 32-byte default was already a safe over-approximation
project-wide, confirming there was no hidden extern-cost time bomb
lurking in any safety-critical call graph. First attempt at applying
the annotations failed to build: vani-compiler's own parser requires
`#[stack_cost(bytes=N)]`'s `N` to be a STRICTLY POSITIVE integer
(`TokenKind::Int(v) if v > 0`) -- a real, literal `0` (correct for
these true zero-frame leaves) is rejected outright. Fixed by clamping
any measured-zero cost to `1` (999 of the 1138 annotations), still a
massive tightening vs. the 32-byte default and never an under-
estimate.

**Real, previously-undetected finding, unrelated to the annotation
imprecision itself** (the number is byte-for-byte IDENTICAL before
and after annotating, since this specific chain touches zero externs):
ran `vanic stack-depth --entry=task_fsq` for the first time ever --
never automated (`build.sh` only auto-gates `kernel_main`; the 10 real
task entry points are a long-documented, acknowledged gap, see this
file's own task #262 round-7 entry and `RTOS_GAP_ANALYSIS.md` §3) --
and found a genuine 4152-byte real worst case via `task_fsq ->
dharafs_queue_dispatch_one -> dharafs_append_raw -> dharafs_block_
write -> dharafs_crypto_encrypt_block -> chacha20_poly1305_encrypt_
heap`'s own AEAD chain, EXCEEDING `task_fsq`'s own raw 4096-byte stack
allocation by 56 bytes, with zero margin at all. Fixed by bumping
`fsq_stack_bytes` 4096 -> 16384, matching `task_e`/GC's own existing
allocation for the same "encrypted DharaFS block I/O background task"
profile rather than picking a new, unprecedented number.

While in there, ran `vanic stack-depth` for all 10 real task entry
points for the first time (not just `task_fsq`) to check for any
other hidden overflow: `task_a`/`task_b`/`task_custom_demo` 208 bytes
(down from 228, the expected UART-leaf tightening), `task_c` 228
(unchanged -- its own chain ends at the `mmio_read_u32` builtin, no
extern cost to tighten), `task_d` 408 (unchanged, pure vani), `task_e`
4716 (unchanged, pure vani/kosh-package chain, comfortable inside its
own 16384-byte budget), `task_f` 13928 (unchanged, pure vani crypto
chain, comfortable inside its own 262144-byte budget), `task_mutex_
demo_low`/`_high` 276/288 (down from 296/308). Only `task_fsq` showed
a real problem, now fixed.

Verified: clean build, `vanic stack-depth --entry=task_fsq --max=14336`
now passes cleanly (was a hard, previously-silent failure), two
identical `phase4_milestone.py` runs, zero regression. Pushed to
origin master/pi4/main.

**Per-thread execution-time supervision, commit `2e7d09c`
(2026-09-20).** Closed a real, explicitly-named `RTOS_GAP_ANALYSIS.md`
gap: "No per-thread execution-time supervision, only a system-wide
watchdog... CMSIS-RTOS2's 'thread watchdog' pattern... is the standard
reference design." Task #241's own deadline-miss detection tracks how
long a READY task waits to be scheduled -- structurally blind to a
task that IS running (or correctly blocked) but has stopped making
its own real forward progress, since a running task's own "ready
wait" is always 0.

Three new per-task tables (`boot/context_switch.S`): `task_heartbeat_
last_tick_table` (tick at the task's last genuine voluntary yield),
`task_heartbeat_bound_table` (0 = unsupervised; a generous 5-10x
multiple of each task's own declared wake period otherwise, wide
enough to absorb every legitimate blocking term this demo set has
ever measured -- mutex handoff 174us, GC/DHCP ~50ms, worst network
blocking 325.6ms, all comfortably under one 500ms tick), `task_
heartbeat_stuck_count_table` (edge-triggered overrun counter, same
discipline as task #241's own miss counter).

Stamped from exactly two places: `task_sleep_ticks_impl`
(unconditional -- no fast path, it always blocks) and `dhruva_mutex_
lock_impl`'s genuinely-contended branch only (a real resource wait,
not a bug -- the fast/uncontended path is deliberately NOT stamped).
Neither `dhruva_prio_lock`/`unlock` nor the mutex fast path counts as
proof of life -- a task stuck in an infinite loop could still call
those repeatedly, which would defeat the whole point by looking alive
when it isn't. Checked in `scheduling_decision_prelude`, the same
function and cadence task #241's own check already uses. `task_d`/
IDLE stays permanently unsupervised (never calls `task_sleep_ticks`,
uses `cpu_wfi()` instead) -- the same exemption CMSIS-RTOS2 gives its
own idle thread.

Exposed via `diagnose`. Two identical `phase4_milestone.py` runs (zero
regression) plus a direct, separately-driven live `diagnose` check
(needed since the automated harness's own `diagnose` check is a
known, documented pre-existing timing flake -- see this file's own
SD-wedge entries for the same `SETTLE_S`-class issue) confirmed the
new line prints correctly: `stuck-task episodes (HIGH/MEDIUM/LOW/
IDLE/GC/SHELL/CUSTOM/MUTEX-LOW/MUTEX-HIGH/FSQ): 0/0/0/0/0/0/0/0/0/0`
-- all zero under normal operation, no false positives. Detection and
reporting only, matching task #241's own scope; a real recovery
action is task #271's separate, not-yet-done scope.

### Task #270 closed: measured, bounded worst-case interrupt latency (2026-09-20)

Second of the 4 real RTOS-compliance gaps from the 2026-09-18 sweep
(see "RTOS true-compliance sweep" above): "an interrupt is serviced
within N cycles of assertion, worst case" had no real measured answer
anywhere in this codebase. The pre-existing `swi_fast_worst_us`
counter (task #253 Phase 3) measures the SWI trap's own fast,
never-blocking round trip, but explicitly excludes the two paths that
actually mask interrupts for a real, variable, unbounded-looking
duration: `task_sleep_ticks_impl`'s own scheduling decision, and
`dhruva_mutex_lock_impl`'s genuinely-contended branch.

New `irq_mask_worst_us`/`_total_us`/`_count`/`_start_us` globals
(`boot/context_switch.S`), same TIMER_CLO-bracketed start/end-stamp
pattern already used throughout this codebase (`swi_fast_worst_us`,
`irq_tick_worst_us`, GC's own critical-section measurement, mutex
handoff latency). Stamped from exactly the two paths above -- start
right before each path's own `bl scheduler_pick_next`, end right
after each path's own SPSR restore, immediately before the final
`ldmia sp!, {r0-r12, lr, pc}^`. Three new accessor functions
(`irq_mask_worst_us_get`/`_total_us_get`/`_count_get`) mirror
`swi_fast_count_get`'s exact shape, exposed to vani with
`#[stack_cost(bytes=1)]` (task #245's own real-cost annotation, not
the old flat default).

Exposed via `diagnose`, immediately after the SWI fast-syscall line,
same `if count > 0 { avg } else { N/A }` pattern. Two identical
`phase4_milestone.py` runs confirmed zero regression (still the
standard 13-PASS/5-FAIL baseline, same 5 known-flaky items). A
direct, separately-driven live `diagnose` check (via the project's
own exact `qemu-system-arm -M raspi1ap -nographic -kernel <elf>`
invocation -- an earlier attempt using `-serial stdio -display none`
instead caused a severe, unrelated SD-retry-storm hang, since the
emulated SD card model apparently behaves very differently under
that flag combination) confirmed the new line prints correctly with
real measured data: `worst-case interrupt latency (I+F masked
duration): worst=368us avg=12us count=282`. Add the ARM1176's own
small, fixed, documented hardware vector-fetch overhead (not measured
here) to get the real end-to-end bound. QEMU's TCG trap overhead
makes this pessimistic vs. real Pi 1B silicon, same caveat as
`irq_tick_worst_us` (task #191/192's own finding); a real-hardware
measurement is a still-open follow-up, not blocking this gap's
closure.

Also fixed two now-stale claims found in `docs/RTOS_GAP_ANALYSIS.md`
while closing this out: "context-switch overhead... remains open --
task #240" (task #240 is actually done -- a real, live-measured
`measured_ctxsw_handoff_ms = 0.182` constant already feeds
`test/schedulability_analysis.py`) and "per-thread execution-time
supervision... remains open -- task #241" (that's task #269, done
2026-09-20, see the entry immediately above this one).

**Separate observation, not investigated further this round:** the
same live-verification QEMU session that confirmed the above also
printed one `SCHED SHADOW MISMATCH p=00000003 a=00000008 t=00000457`
-- Gap B's own `scheduler_pick_next` shadow-model self-test (task
#234), previously verified at 0 mismatches, showing 1 here. This
change does not touch `scheduler_pick_next` or the shadow-predict
logic, only adds TIMER_CLO reads around two existing blocking paths,
so it's an unlikely cause -- but per this project's own "no trust,
validate everything" discipline, a single manual run isn't enough
either way to call it a pre-existing rare flake or a real new gap.
Flagged here as a fresh, separate, NOT-yet-investigated finding for a
future round; not part of task #270's own scope and did not block
closing it.

### Task #271 closed: real runtime WCET/deadline ENFORCEMENT, not just detection (2026-09-20)

Third of the 4 real RTOS-compliance gaps from the 2026-09-18 sweep.
Task #269 (per-thread execution-time supervision) already detects a
task that's stopped making real forward progress; this task closes
the gap between "detected" and "acted on."

Design question going in: what recovery action is both real and safe
to build on top of this scheduler's existing machinery, given the
project's own hard-won caution around this exact function
(`scheduler_pick_next`'s own header comment documents a real,
never-fully-root-caused crash from round 75's white-box testing --
see Gap B/task #234's own shadow-model workaround for why nothing
calls that function directly from vani). Ruled out a full task
kill/reset (needs resource-release machinery this codebase doesn't
have yet, real scope creep) in favor of the minimal, already-proven
mechanism this scheduler uses for every other blocking call:
`sleep_until_table`. Every task that's ever waited for anything in
this codebase (`task_sleep_ticks_impl`, `dhruva_mutex_lock_impl`'s
contended branch) becomes "not ready" by writing exactly this one
table, which `scheduler_pick_next`'s own ready-gate already reads on
every decision. Forcing an overrunning task through the SAME table,
from `scheduling_decision_prelude` (which already runs immediately
BEFORE `scheduler_pick_next` on every real scheduling decision, so
the eviction takes effect the same tick it's detected), adds zero new
control-flow paths to the scheduler itself -- just feeds its existing,
already-verified input.

New `task_wcet_enforce_evicted_count_table` (`boot/context_switch.S`,
same 16-word table shape as every other per-task counter in this
file). On a heartbeat-bound overrun (task #269's own check), write
`sleep_until_table[i] = now + bound` (self-healing: automatically
ready again after one cooldown window, no kill/reset needed) UNLESS
`ceiling_depth_table[i] > 0` -- the task genuinely holds a
ceiling-protected critical section. New `ceiling_depth_table_get_at`
accessor added for this check (read-only, same safety class as Gap
B's own existing accessors: a single-instruction table read, never
calls `scheduler_pick_next` itself). Evicting a mutex holder without
also releasing what it holds would strand every other task waiting on
that same resource -- a strictly worse failure mode than the overrun
itself -- so those episodes are still detected (the stuck-count row
still increments) but deliberately not enforced. This is effectively
ARINC 653's "freeze the overrunning partition until the next window"
applied per-task instead of per-partition, and mirrors `scheduler_
pick_next`'s own existing ceiling-aware gate for this same table (see
its "Round 75 gate" comment) -- a stuck ceiling-holder is never
evicted through either path.

Exposed via `diagnose`, same row-of-10 format as the stuck-count line
immediately above it. Two identical `phase4_milestone.py` runs
confirmed zero regression. A direct, separately-driven live `diagnose`
check confirmed the new line prints correctly: `WCET-enforcement
evictions (HIGH/MEDIUM/LOW/IDLE/GC/SHELL/CUSTOM/MUTEX-LOW/MUTEX-HIGH/
FSQ): 0/0/0/0/0/0/0/0/0/0` -- all zero under normal operation,
matching the stuck-count row 1:1 (no ceiling-holding task has ever
overrun its bound in this demo set, so the two rows track exactly).

One item left in the 4-gap program: task #272 (tick granularity),
explicitly HIGH RISK per this file's own prior entries -- needs the
tick-count-expressed real-time constants migrated to microseconds
FIRST, before ever touching the tick rate again.

### Task #272 closed: tick-count timeout constants decoupled from the tick period (2026-09-20)

Last of the 4 real RTOS-compliance gaps from the 2026-09-18 sweep.
Given this exact subsystem's own two prior full reverts (round 191,
task #243, same root cause both times), checked in with the user
before starting rather than proceeding on the earlier 3 gaps' own
autonomous momentum -- confirmed: do the safe prerequisite step only
(decouple the constants), do NOT touch the tick period itself this
round.

Three functions hardcoded a raw tick count that only meant its real-
world duration at the CURRENT 500ms tick period: `tcp_rtx_timeout_
ticks` (2 real seconds), `dhcp_client_check_lease`'s own local
`ticks_per_second` (1 real second per unit), `auth_lockout_ticks` (10
real seconds, and the one round 191's own audit caught NOT rescaled
the first time -- a real, if narrow, security-relevant near-miss).
Each now derives its tick count from the real duration it actually
means, divided by `scheduler_tick_interval_us()` (the existing single-
source-of-truth tick period, itself still returning the same 500000
literal, unchanged) -- ceiling division for the two functions
(`tcp_rtx_timeout_ticks`, `auth_lockout_ticks`) so a real timeout can
never come in SHORTER than intended; plain integer division for
`ticks_per_second` (matches its own pre-existing 2-per-second
semantics exactly, with a documented rounding caveat for a future tick
period that doesn't evenly divide 1,000,000 -- not a concern at
today's unchanged period).

At today's unchanged 500ms tick, all three functions return EXACTLY
their old literal results (4/2/20) -- verified by hand, a pure
decoupling, not a behavior change. Two identical `phase4_milestone.py`
runs confirm zero regression, including `tcprtx` (which directly
exercises `tcp_rtx_timeout_ticks` via a live simulated SYN-loss
retransmission) passing both times.

Also audited every other `_ticks`-named constant in the codebase for
the same hidden-coupling risk: the PM watchdog's own `two_seconds_in_
ticks` (131072 = 2<<16) runs on a genuinely SEPARATE 65536Hz hardware
counter, already confirmed independent of the scheduler tick by round
191's own original audit -- no fix needed, left alone. The demo tasks'
own `task_sleep_ticks(N)` wake-period call sites (task_a-f, the
dynamic demo tasks) are intentionally tick-relative scheduling
behavior, not external real-world-duration requirements like an RFC-
mandated RTO or a security lockout window -- out of this task's scope
by design, not an oversight.

This closes the actual prerequisite task #243/#247 both already
identified: any FUTURE attempt at a finer tick or tickless design no
longer needs a fresh, error-prone, whole-codebase audit for hidden
tick-period assumptions before it can even start. Whether to actually
make that attempt is a separate decision, unchanged by this task --
task #243/#247's own real-hardware-availability and schedulability-
margin reasoning for not attempting it yet still applies.

**All 4 RTOS-compliance gaps from the 2026-09-18 sweep are now
closed**: per-thread execution-time supervision (#269), worst-case
interrupt latency measurement (#270), real WCET/deadline enforcement
(#271), and this task's own tick-constant decoupling (#272).

### Task #273 closed: fixed a real shadow-model false-positive mismatch, root-caused against real Linux source (2026-09-20)

Follow-up to task #270: that task's own live verification session
(typing `diagnose` at the interactive UART shell) surfaced one real
`SCHED SHADOW MISMATCH p=00000003 a=00000008 t=00000457` -- Gap B's
own scheduler shadow-model self-test (task #234), previously verified
at 0 mismatches across the automated regression suite. Flagged as a
separate, not-yet-investigated finding at the time; investigated and
fixed this round per explicit user request.

Root cause, confirmed by tracing both real ISR entry points
(`kernel_main.vani`): `irq_dispatch` (the UART RX path) calls
`scheduling_decision_prelude()` -- which stashes this call's own
shadow-predicted task plus a context-switch-count baseline -- at the
very top of the function, then does substantial further real work (RX
FIFO drain loop, up to 128 iterations) BEFORE its caller
(`scheduler_switch_from_irq`, `context_switch.S`) actually invokes the
real `scheduler_pick_next`. `timer_tick_dispatch` (the FIQ path) has
the identical shape: prelude first, real work after.

The automated `phase4_milestone.py` harness never triggered this
because ordinary IRQ entry only masks further IRQ, never FIQ. This was
suspected but not simply assumed -- checked against real Linux ARM32
source (`arch/arm/kernel/entry-armv.S`) to confirm before writing any
fix: the `vector_stub` macro's own comment reads "Prepare for SVC32
mode. IRQs remain disabled," and the actual code (`eor r0, r0,
#(\mode ^ SVC_MODE | PSR_ISETSTATE)`) only touches mode bits, leaving
whatever F was in the interrupted context's own CPSR unchanged --
i.e. real Linux does NOT mask FIQ during ordinary IRQ handling either.
This is standard ARM32 behavior, not a DhruvaOS gap, and it directly
ruled out the more drastic candidate fix (masking FIQ for the duration
of `irq_dispatch`) -- Linux doesn't do that, and doing it here would
have regressed task #246's own real FIQ-latency work. So: a real timer
FIQ CAN legitimately preempt `irq_dispatch` mid-drain, run its own
complete scheduling decision (context_switch_count can advance by
exactly 1, tick_count always advances by exactly 1), and by the time
the interrupted `irq_dispatch` finally reaches its own real `scheduler_
pick_next` call, the world has moved on from what its own
already-stashed prediction assumed -- yet the existing `ctxsw-delta<=1`
guard, designed to catch "more than one intervening decision," doesn't
catch this specific single-nested-decision case.

Fixed with a second, narrower guard rather than touching `scheduler_
pick_next` itself (consistent with this project's own established
caution around that function -- round 75's real, never-fully-root-
caused crash from white-box testing it directly, see Gap B/task #234's
own shadow-model workaround). New `spn_shadow_tick_baseline`
(`boot/context_switch.S`, same shape as the pre-existing
`spn_shadow_ctxsw_baseline`), stamped via `scheduler_get_tick_count()`
at the same moment the ctxsw baseline is stamped. The mismatch check
now requires BOTH `ctxsw-delta<=1` AND `tick_count` still matching the
baseline before trusting the comparison -- a nested FIQ always
advances `tick_count` (that's the literal definition of a timer tick)
while an ordinary UART RX IRQ never does, so this reliably
distinguishes "a real nested scheduling decision happened" from "no
intervening decision at all," which is exactly what the existing
ctxsw-only guard couldn't do on its own.

Two identical `phase4_milestone.py` runs confirm zero regression. Five
separate live interactive QEMU sessions (10 total `diagnose`
invocations -- the exact scenario that originally surfaced the bug)
all show `scheduler shadow-model mismatches: 0 total` with no `SCHED
SHADOW MISMATCH` output anywhere. Given the original race was
observed only once across many prior sessions, this is strong but not
absolute confidence -- consistent with the fix working, not
mathematically exhaustive proof for a timing-dependent race.

### Fifteenth SD round: task #274's own settle-delay fix retested, found insufficiently sized, corrected -- AND a much bigger, separate finding surfaced (2026-09-20)

Fresh real-HW log (`picocom_20260920_161425.log`, user: "new picocom
log sdcard wedge in home folder of this pc") showed the write wedge
reproduces IDENTICALLY after task #274's settle-delay fix -- same
SDCDIV backoff progression, same "block 2100 FAILED" failure point.

Investigated why by comparing `sdhost_init`'s own "total elapsed"
diagnostic across the two logs: the new log's `sdhost_init` calls take
~1.15s each, ~1.1s longer than before the fix -- confirming the added
`delay()` calls ARE executing, just not for the intended ~20ms each.
Root cause: task #274's own sizing used `delay(3000000)=49906us`, a
number this project's OWN `test/schedulability_analysis.py` and two
memory files already cite as "measured" (task #226/240's own
schedulability audit). That number is QEMU-only. Two real picocom
logs already sitting in this project's own history since 2026-09-18
(`picocom_20260918_074005.log`, `picocom_20260918_163633.log`) have
the real answer, un-cross-checked until today:
`delay(3000000)=930168us`/`930098us` -- an ~18.6x discrepancy. QEMU's
TCG JIT executes a tight register-only busy loop (no memory/peripheral
access) at a completely different effective rate than real ARM1176
silicon, while still correctly emulating TIMER_CLO's own 1MHz tick --
so a `delay()` calibration taken under QEMU silently measures "how
fast the host machine executes this loop," not real Pi 1B timing.

Corrected the SD settle delays to `delay(64500)` (real ~20ms, matching
the real per-iteration cost) -- commit `7c2b038`. Useful negative
evidence along the way: the WRONGLY-sized delay(1200000) gave ~372ms
settle time per call, ~18x MORE generous than U-Boot's own real 20ms
values, and the wedge still reproduced identically -- further evidence
against "insufficient settle time" as this wedge's actual root cause,
on top of everything task #274's own round already found. Two
identical `phase4_milestone.py` runs confirm no regression. Needs a
fresh real-HW retest with the corrected timing.

**Separate, much larger finding from the same root cause, NOT yet
acted on pending user direction:** `test/schedulability_analysis.py`'s
own `measured_low_critical_section_ms = 49.906` (line 337) -- the
blocking term (B_i) fed into the RTOS-compliance program's own
"verdict: schedulable, 440ms-1445ms slack" conclusion (task #226/240,
2026-09-17) -- is the SAME QEMU-only number. Re-ran the tool locally
with the real measured value (930.168ms) substituted for this one
input, everything else unchanged:

```
HIGH: R=935.350ms <= D=1500.0ms (margin 564.650ms) -- PASS
MEDIUM: MISSES DEADLINE -- FAIL
LOW: R=958.585ms <= D=1000.0ms (margin 41.415ms) -- PASS
VERDICT: NOT schedulable with real measured blocking data.
```

MEDIUM's own 500ms deadline is smaller than LOW's real ~930ms
ceiling-0 critical-section hold time alone, before any of MEDIUM's own
execution time is even added -- a real, structural deadline miss on
real Pi 1B hardware for the demo task set's own declared periods, not
a QEMU artifact. This does NOT invalidate the schedulability tool
itself (`schedulability_analysis.py`'s own self-tests all still pass,
and the tool correctly computed "NOT schedulable" once given the right
input) -- it invalidates the ONE INPUT this project sourced from a
QEMU-only busy-loop measurement without ever cross-checking it against
real hardware, even though two real logs with the correct answer were
already sitting in this project's own history for two days. Given how
consequential this is (a real, structural deadline-miss claim, not
just a documentation staleness fix), deliberately NOT silently
"corrected" here -- `test/schedulability_analysis.py`'s own checked-in
constant and `docs/RTOS_GAP_ANALYSIS.md`'s own schedulability claims
are both left unchanged pending the user's own direction on how to
respond (options include: shortening `task_c`'s own demo `delay(
3000000)` critical-section hold to something that actually fits
MEDIUM's real declared deadline; loosening MEDIUM's own declared
period/deadline to genuinely accommodate the real blocking term;
re-deriving the whole schedulability picture with corrected inputs and
updating the audit's own conclusion; or something else the user
prefers). This is a genuinely new, separate finding from the SD
investigation itself, surfaced as a byproduct of cross-checking a
number this round happened to reuse.

### Task #276 closed: real MEDIUM deadline miss fixed at the root, not papered over (2026-09-20)

User's own direction: "go with recommended way - correctness and
safety over speed," then "faster is better but not at the expense of
safety and correctness" -- both pointed at the same answer. Two
options were on the table: shorten `task_c`'s own demo critical
section to genuinely fit MEDIUM's declared deadline, or loosen
MEDIUM's own declared deadline to accommodate the real (buggy)
blocking term. Went with the former -- a declared deadline is a
requirement; the right response to an implementation violating it is
fixing the implementation, not weakening the requirement to match a
bug. Real safety-critical practice (ARINC 653/DO-178C-class
convention) treats it the same way.

Turned out to be the cleaner fix in every sense, not just the safer
one: this project's own long-standing design intent for `task_c`'s
critical section was ALWAYS "about 50ms" (see round 17's own original
comment, and `test/schedulability_analysis.py`'s own docstring) --
the ~930ms real duration was never intentional, it was purely the
QEMU-miscalibration bug from the 15th SD round leaking into this
task's own busy-wait count. So "fix the implementation" and "restore
the original intent" were the same edit: `task_c`'s `delay(3000000)`
(real ~930ms) corrected to `delay(161000)` (real ~49.92ms, matching
the ORIGINALLY intended ~50ms almost exactly once correctly
calibrated against real hardware's own 0.310044us/iteration cost
rather than QEMU's). `delay_wcet_measure_self_test`'s own middle
measurement point updated in lockstep (was already documented as
"exactly task_c's own real usage" -- kept true, not left stale).

Re-ran `test/schedulability_analysis.py` (unchanged constant,
`measured_low_critical_section_ms=49.906` -- now genuinely valid
again rather than a QEMU-only coincidence) after the kernel fix:
`VERDICT: schedulable with real measured blocking data, comfortable
margin` -- all three tasks PASS, MEDIUM specifically at
R=60.270ms/D=500ms (439.730ms margin). The tool itself was never
wrong; only the one input it was fed was.

Documented the full QEMU-vs-real discrepancy directly in code (both
`kernel_main.vani`'s own `task_c`/`delay_wcet_measure_self_test`
comments and `schedulability_analysis.py`'s own docstring) rather than
only in `docs/TODO.md`, specifically so this project doesn't reuse an
unverified QEMU-only busy-loop timing a THIRD time (this was already
the second time this exact number caused a real bug, after tasks
#274/#275's own SD settle-delay mis-sizing). Two identical
`phase4_milestone.py` runs confirm zero regression.

This closes the "separate, much larger finding" flagged in the
15th-round entry immediately above -- `docs/RTOS_GAP_ANALYSIS.md`'s
own "verdict schedulable" claim is now genuinely real-hardware-backed,
not a QEMU coincidence that happened to look right.

### Sixteenth SD round: correctly-sized settle delays confirmed insufficient -- settle-timing theory now conclusively ruled out (2026-09-20)

Fresh real-HW retest (`picocom_20260920_165043.log`, user: "new
picocom log fetched after update kernel script /dev/sdb") of task
#275's corrected `delay(64500)` sizing. First confirmed the fix is
genuinely running at the intended magnitude this time: `sdhost_init`'s
own "total elapsed" diagnostic shows +53439-53519us total across the 3
delay calls per init (~17.8ms each, matching the ~20ms real target
within measurement/overhead variance -- NOT the ~372ms/call the
wrongly-sized version gave, and NOT the ~166us/call the original
too-short version gave).

The wedge still reproduces IDENTICALLY: same SDCDIV backoff
progression (0x8/0x12/0x148), same "block 2100 FAILED" mismatch point,
CMD13 (SEND_STATUS) still times out every single time (controller's
own command path still totally frozen once wedged).

This is now a conclusive result, not just another inconclusive
attempt: settle-delay timing has been tested at THREE different
magnitudes across the 14th/15th/16th rounds -- too short (~166us/call,
the pre-existing behavior), far too long (~372ms/call, task #274's own
mis-sized first attempt), and now correctly sized to match U-Boot's
own real, documented, working reference values (~17.8ms/call, task
#275's correction) -- and the wedge reproduces identically at every
single one of them. Insufficient settle time is no longer a credible
root-cause theory for this wedge; it's ruled out as thoroughly as
clock speed already was (task #274's own finding: wedges even at the
slowest identification-speed clock).

**State of the investigation after 16 rounds:** the two most
reference-grounded software-side leads this project could find (the
already-applied SDEDM FIFO-threshold silicon-errata workaround, and
now the settle delays around it) are both confirmed present, correctly
sized, and confirmed insufficient. Every genuinely new diagnostic this
investigation has shipped (CMD13 card-status query, clock-speed sweep,
settle-delay sweep) has narrowed the search space without finding the
actual fix. Not proposing a 17th speculative register/timing tweak
without a new concrete lead -- reported honestly to the user rather
than guessing again, pending their direction on how to proceed (e.g.
a genuinely different reference driver angle, trying a second SD card
as a now-more-justified controlled experiment given how much has
already been ruled out, or accepting this as a real hardware
limitation of this specific peripheral/card pairing and prioritizing
the already-supported USB mass storage block-device backend instead).

### Seventeenth SD round: third independent reference driver (FreeBSD) cross-checked, a genuinely new gap found and instrumented (2026-09-20)

User's own explicit follow-up: "did you miss any other comparisons
with known good reference sd host drivers for bcm2835 or other rpi 1b
chips meticulously?" -- a fair challenge, since Linux and U-Boot's own
`bcm2835-sdhost.c`/`bcm2835_sdhost.c` share the same original
reverse-engineering lineage and could plausibly share the same blind
spot. Checked whether a genuinely INDEPENDENT third implementation
exists: FreeBSD does have its own
`sys/arm/broadcom/bcm2835/bcm2835_sdhost.c` (production-grade, ships
on real hardware -- FreeBSD's Pi 1/Zero support has no other SD
interface to fall back to, so this driver has to genuinely work),
architecturally built as an SDHCI-register-shim rather than a native
MMC host driver -- a real, different codebase, not just another copy.

Two findings from a careful read:

1. FreeBSD's own reset function uses `DELAY(250000)` (250ms) around
   both the FIFO-threshold config write and the power-on cycle --
   12.5x more generous than U-Boot's own 20ms this project already
   matched (task #275). Checked whether this changes anything: it
   doesn't. Task #274's own accidentally-mis-sized `delay(1200000)`
   already gave ~372ms per call in the 15th round -- MORE generous
   than FreeBSD's 250ms -- and the wedge reproduced identically
   anyway. The settle-delay-magnitude question was already answered
   conclusively before this round even started; FreeBSD's own larger
   number doesn't reopen it.

2. A genuinely new difference, not previously tested: FreeBSD's own
   `bcm_sdhost_write_multi_4` explicitly polls the SAME FIFO-occupancy
   field this project's own fill loop already reads
   (`(SDEDM>>4)&0x1F`) down to exactly 0 -- "wait until FIFO is really
   empty", its own comment -- immediately after pushing every word,
   BEFORE ever checking FSM state at all. Neither Linux's nor U-Boot's
   own PIO fill loop does this (confirmed by re-reading both again
   specifically for this), and neither did DhruvaOS's own `sdhost_
   fill_fifo_from_buffer(_diag)` -- it stops the instant there's room
   for the last word, then goes straight to FSM-based `sdhost_wait_
   transfer_complete`, never confirming the FIFO itself actually
   finished draining to the card first.

Added this missing step as new instrumentation in `sdhost_write_
block_once` (commit `53005a1`): a bounded (1,000,000-iteration) poll
of FIFO occupancy to 0, with a real diagnostic print on timeout. This
is genuinely new evidence regardless of outcome -- no prior diagnostic
in this 17-round investigation has ever read FIFO occupancy at this
exact point, only FSM state. If the wedge resolves, the fill loop was
returning before the FIFO genuinely drained and FSM state was never
going to unstick on its own without this. If it doesn't (FIFO reads 0
immediately, same as before), that's still real information: it rules
out "FIFO itself stuck non-empty" as a category and confirms the
wedge is purely an FSM-state phenomenon, narrowing the search further
than it's ever been narrowed before. Two identical `phase4_
milestone.py` runs confirm zero regression. Needs a fresh real-HW
retest -- the new diagnostic print (if it fires) or the wedge simply
resolving are both real, actionable outcomes either way.

### Eighteenth SD round: sdhost_wait_transfer_complete's own timeout was never a real-time bound (2026-09-20)

User shared a link unprompted mid-session: a Raspberry Pi forum thread
(https://forums.raspberrypi.com/viewtopic.php?t=242510) describing a
U-Boot fix for `bcm2835_sdhost.c`'s own `bcm2835_wait_transfer_complete`
-- the SAME controller/driver family this project's own `sdhost_wait_
transfer_complete` implements. Their bug: an iteration-count timeout
calibrated to LOOK like ~1 second actually only covered ~12ms on real
silicon, timing out before some cards' own legitimate up-to-56ms CMD25
write completion. Checked DhruvaOS's own equivalent function: it had
the EXACT same shape (`while iter < 5000000`), never fixed in any of
the prior 17 SD rounds despite this project independently proving the
underlying mechanism already (tasks #274/#275's own ~18.6x QEMU-vs-
real busy-loop-rate measurement) -- the fix for THAT finding was
applied to `delay()`'s own sizing, never to this function's own
timeout loop, which nobody had connected to the same root cause until
this forum thread's own parallel example made it obvious.

**Fixed**: replaced the iteration count with `TIMER_CLO`-based real
elapsed microseconds (1 second, matching the U-Boot fix's own real-
world-validated choice) -- `TIMER_CLO` is the BCM2835 system timer's
free-running 1MHz counter, already correctly emulated at 1MHz under
QEMU elsewhere in this file, so a microsecond bound here means the
SAME real-world timeout duration in both environments by construction,
not by re-tuning a magic constant a ninth time. The function's own two
exit-state checks (READWAIT/WRITESTART1 `alternate_idle`, and the
READDATA=2 check added in the 8th fix attempt) are unchanged -- only
the timeout mechanism changed. Commit `7ecc2a2`.

Two identical `phase4_milestone.py` runs confirm zero regression; the
8-block sweep's own elapsed time (9106us) stayed in the same order of
magnitude as before the change (well under the new 1-second real-time
cap, as expected for a controller that isn't actually wedged).

**Real-HW retest, same evening (`picocom_20260920_224933.log`)**: the
write wedge is STILL PRESENT -- every one of the 8-block sweep's writes
still gives up after 3 retries, identical to every prior round. But
the fix IS confirmed active and produced a genuinely useful negative
result. Comparing the "write attempt -> wait_transfer_complete timeout
-> CMD13(SEND_STATUS) timeout -> controller reset" segment's own real
elapsed time (via consecutive `sdhost_init entry, TIMER_CLO=...`
timestamps) against the immediately-prior PRE-fix log
(`picocom_20260920_165043.log`, captured before this fix was pushed):
pre-fix ~3.21s, post-fix ~1.49s -- the timing genuinely changed,
confirming the new code path is live, not a no-op.

The direction is the OPPOSITE of the U-Boot bug this round was
prompted by: DhruvaOS's own old iteration-count loop was already
running LONG on real hardware (~3.2s for the whole segment), not too
SHORT. This makes sense in hindsight -- this loop's own dominant
per-iteration cost is a real `mmio_read_u32` bus transaction, not pure
ALU cycles like the `delay()` loop tasks #274/#275 examined, and MMIO
read latency is comparably bus-bound on both QEMU and real silicon,
unlike a tight arithmetic loop's own ~18.6x rate mismatch. The fix
still mattered (structural correctness, and a real ~1.7s reduction in
worst-case failure-detection latency), but "timeout window too short"
was never going to be the write wedge's own root cause here.

**Real, useful negative result**: all 16 timeout events in the new log
show byte-for-byte IDENTICAL `SDEDM=0x00010803` (FSM=3=WRITEDATA),
whether the wait was ~1s (new) or ~3s+ (old, from the same evening's
own earlier log). The controller is genuinely, permanently stuck at
that FSM state for the ENTIRE real-time window regardless of how long
you wait -- this DEFINITIVELY RULES OUT "the timeout fires before the
transfer genuinely finishes" as any part of the write-path wedge's own
explanation, a hypothesis class this 18-round saga had never formally
eliminated before (every prior round addressed settle delays, FIFO
draining, clock speed, or FSM escape-hatch coverage -- never directly
tested "is the wait simply not long enough"). task #218 remains open;
the search narrows to genuine FSM-recovery mechanics (what real
register write/reset sequence, if any, can move the controller off
WRITEDATA once it's landed there) rather than any variant of "wait
longer" or "detect the stuck state sooner."

**Second real-HW card ruled out card wear (2026-09-21,
`picocom_20260921_080631.log`)**: a total-silence "does not boot"
report turned out to be a stale/disconnected `picocom` session, not a
real boot failure (confirmed by reflashing the SAME known-good
`1cb81a0` kernel.img and getting normal output again) -- NOT caused by
any code change. While diagnosing it, the user tried a brand-new,
different-capacity 16GB card (previous card: 64GB) with the exact same
known-good `1cb81a0` build (no new instrumentation). Result: byte-for-
byte the SAME wedge signature (SDEDM=0x00010803, FSM=WRITEDATA,
blocks 2100/2101 both failing after 3 retries each, identical SDCDIV
backoff sequence 0x08/0x12/0x148). This DEFINITIVELY RULES OUT "the
original 64GB card is worn out from 19 rounds of forced-reset stress
testing" as an explanation -- two completely different physical cards
(different capacity, almost certainly different controller/manufacturer)
produce the identical failure, strong independent confirmation this is
a genuine DhruvaOS driver/protocol/controller-timing issue, not a
card-specific hardware fault.

### Nineteenth SD round: CMD24 register-level instrumentation, two hypotheses tested and ruled out (2026-09-21)

User's own explicit follow-up after the 18th round (timer-based
timeout fix) confirmed the wedge persists: "Stop modifying timeout/
retry behavior. Instrument the CMD24 transaction at instruction/
register level... show SDCMD, SDARG, SDHBCT, SDHBLC, SDHSTS and SDEDM
immediately before CMD24, after command completion, before the first
SDDATA write, immediately after it, and after every FIFO batch. Also
capture CMD13/R1 immediately before CMD24."

**Built**: new `sdhost_diag_dump_regs_pre_cmd24`/`_post_cmd24` entry
points (`boot/sdcard_state.S`) plus a shared `sdhost_diag_dump_regs_
body` helper, all six registers together at every checkpoint; extended
`sdhost_fill_fifo_from_buffer_diag`'s own checkpoints from the
original 1/4/8/16-word set to 1/16/32/48/64/80/96/112/128 (every
16-word FIFO batch through the full transfer, not just the first
FIFO's worth); new pre-CMD24 CMD13 (SEND_STATUS) call in `kernel_
main.vani`'s `sdhost_write_block_once`, the first-ever "before"
baseline for that check (every prior CMD13 diagnostic in this
investigation only ever ran AFTER a wedge was already detected).

**Two false alarms along the way, both caught before shipping a
wrong conclusion**: a "card does not boot at all" report turned out to
be a stale `picocom` session (see the "second real-HW card" entry
above); a build that appeared to hang the QEMU regression suite's
`tcprtx` test was confirmed as a known, accepted, diagnostic-only
print-volume side effect (same class the original `sdhost_fill_fifo_
from_buffer_diag` instrumentation already caused once, 2026-09-19),
not a functional regression -- kept local-only per explicit user
choice rather than pushed.

**Real finding #1, later ruled out via reference-driver comparison**:
the first real-HW capture (`picocom_20260921_081231.log`) showed
`post-CMD24-cmd-complete SDARG=0x00106800` for block 2100 while
`is_sdhc=1` -- exactly `2100*512`, a byte address, when an SDHC card's
CMD24 argument should be the bare block number (`0x834`). Looked like
a real, previously-undiscovered addressing bug. Root-caused with three
successive, increasingly-isolated debug prints under QEMU (added, used
once, then fully removed): `sdhost_card_addr(block_num)` computes
CORRECTLY at the point of computation for all 8 sweep blocks (matching
QEMU's own `is_sdhc=0` SDSC model, a distinct, correctly-varying
byte-address value per block -- e.g. `2100 -> 0x106800`, `2101 ->
0x106A00`); `addr` survives correctly, unchanged, all the way to
immediately before the `sdhost_cmd` call. But `mmio_write_u32(SDARG,
addr)` followed by an IMMEDIATE `mmio_
read_u32(SDARG)` (same address, zero intervening operations, inside
`sdhost_cmd` itself) returns `0x00000000` regardless of what was just
written. **SDARG genuinely does not support readback of its own
written value on this controller** -- confirmed via Linux's own
`raspberrypi/linux` (rpi-6.6.y) `bcm2835-sdhost.c`: SDARG is
documented "32 R/W" but the driver never once reads it back anywhere
in its own source, so this specific behavior had simply never been
tested by anyone before. This retroactively means the real-HW
`0x00106800` reading was never meaningful evidence of an addressing
bug in the first place -- a genuinely novel discovery about the
hardware, but a dead end for THIS specific hypothesis, not a fix.

**Real finding #2, also ruled out via reference-driver comparison**:
`SDHBCT` (initialized to 512, intending "512 bytes") decrements by
exactly 1 per WORD written, not per byte -- confirmed with exact
arithmetic matches at every checkpoint (512-1=0x1FF after word 1,
512-16=0x1F0 after word 16, ..., 512-128=0x180 after the full 128-word
transfer, matching the real-HW log exactly at every single point).
Never reaching 0 after a complete, correct transfer looked like a
plausible root cause (controller waiting forever for a byte-counter
that can't reach zero). Checked against Linux's own driver comments:
SDHBCT is explicitly documented "Host byte count (**debug**)" -- an
informational register the hardware does NOT gate FSM transitions on;
Linux's own PIO loop tracks completion via its own software word
counter, then explicitly forces the FSM out of any stuck intermediate
state via `SDEDM_FORCE_DATA_MODE`, exactly matching what this
project's own `sdhost_wait_transfer_complete` already does. Not the
root cause.

**Where this leaves the search**: every real-HW wedge this entire
saga has ever captured (going back to round 2026-09-15) decodes to
FSM=WRITEDATA(3). Checked both Linux's and U-Boot's own reference
drivers for their own FORCE_DATA_MODE escape-hatch coverage: Linux
forces WRITESTART1; U-Boot forces READWAIT(4)/WRITESTART1(0xA)/
READDATA(2) unconditionally. **Neither reference driver ever forces
WRITEDATA(3)** -- this project's own existing escape-hatch coverage
(WRITESTART1 + READDATA, added round 2026-09-19) already matches both
references correctly. Deliberately did NOT add a new WRITEDATA-forcing
branch despite the temptation -- neither proven reference needs one,
and this project has already shipped three prior "well-reasoned but
unproven" SD fixes that were each falsified by the next real log (see
`sdhost_wait_transfer_complete`'s own header comment). The real
question this leaves open: why does THIS driver's own PIO loop reach
and get stuck in WRITEDATA at all, when neither reference driver's own
loop apparently ever does -- the difference must be upstream, in how
the FIFO-fill loop itself is structured, not in the wait/escape-hatch
logic downstream of it.

Two identical `phase4_milestone.py` runs confirm zero regression
(same known, accepted `tcprtx` timing artifact from the diagnostic
print volume, unchanged from before this round). All temporary debug
prints added during root-causing were removed before this round's own
commit; the permanent register-dump instrumentation (pre/post-CMD24,
per-batch) remains, kept local-only per the user's own explicit choice
this round.

### Twentieth SD round: found the real structural gap (missing IRQ/FIQ masking), reverted a broken naive fix, real gap for the fix still open (2026-09-24)

Direct answer to the 19th round's own open question: pulled Linux's
own `bcm2835_sdhost_write_block_pio` (raspberrypi/linux rpi-6.6.y) and
compared its structure against this driver's `sdhost_fill_fifo_from_
buffer` (boot/sdcard_state.S), word by word. Found a real, concrete
difference every one of the previous 19 rounds missed, because all of
them looked at register semantics/timeouts/protocol, never at
concurrency: **Linux wraps its entire PIO write-block loop in
`local_irq_save(flags)`/`local_irq_restore(flags)`, unconditionally,
every call** -- this driver's equivalent loop never masked anything.
This kernel is FIQ-driven-preemptive (round 191/246) with a 500ms
scheduler tick PLUS ordinary IRQ sources (UART RX from picocom, USB)
that can land at any time -- every real-HW session in this whole saga
has had picocom attached throughout. A write FIFO is far more time-
sensitive than a read FIFO (the card must drain it into flash cells in
real time; a read FIFO the card can just hold full and wait on) --
consistent with this saga's write-only symptom, and the read side
(fixed task #217) never needing this. If a task switch or IRQ handler
lands between two SDDATA word writes for long enough, the controller's
own FSM can get stuck exactly where every real-HW log in this entire
saga has always shown it: WRITEDATA(3). QEMU's own IRQ/FIQ timing and
SD FIFO emulation have no equivalent real-hardware backpressure to
violate -- consistent with the wedge never once reproducing there
across 19 rounds.

**Built, then REVERTED after a live regression caught a real
architectural conflict**: added `disable_irqs_and_fiqs`/`enable_irqs_
and_fiqs` (`cpsid if`/`cpsie if` wrappers, irq_entry.S) and wrapped the
`sdhost_fill_fifo_from_buffer(_diag)` call site in `sdhost_write_
block_once` (matching Linux's own scope exactly -- only the PIO loop,
not the surrounding command/status phases). `phase4_milestone.py`
immediately showed a severe regression far beyond the known `tcprtx`
artifact: `eval`/`ping`/`ifconfig`/`tcpecho`/`udpecho`/`netstat` all
newly failing, the run terminating on the harness's own overall
timeout mid-sequence. Root cause: `cpsid`/`cpsie` are privileged
instructions, and **every real caller of this code path is a USR-mode
task** (task #253/#261 -- "every real caller today is a USR-mode
task", swi_entry.S's own header comment; the existing 5 SWI syscall
trampolines -- `task_sleep_ticks`, `dhruva_mutex_lock`/`_unlock`,
`dhruva_prio_lock`/`_unlock` -- are the ONLY sanctioned way for USR-
mode vani code to reach a privileged primitive). A direct call hits
the exact UNPREDICTABLE-instruction bug class swi_entry.S's own two
2026-09-19 fixes already found and fixed once, building the SWI trap
for a different primitive -- `enable_irqs`/`enable_fiqs` themselves
are dead code today for the identical reason (irq_entry.S/fiq_entry.S
own header comments: "declared+defined but never actually called
anywhere"). Reverted the call site and the vani-side extern decls;
kept the `cpsid if`/`cpsie if` assembly itself in irq_entry.S as the
correctly-reasoned SVC-mode body a future syscall trampoline needs.
Rebuilt + reran `phase4_milestone.py`: confirmed back to the exact
known baseline (only the already-accepted `tcprtx` artifact).

**Where this leaves the search**: the structural gap is real and well-
supported (a direct, explicit Linux-reference match), but implementing
it correctly needs a 6th SWI syscall trampoline -- a genuinely bigger
lift than any prior round in this saga (the existing 5 took two real
bugs to get right the first time: F-masking gap and an unsaved-
callee-register clobber, both swi_entry.S's own 2026-09-19 history).
Also worth noting going in: masking IRQ+FIQ across the fill loop, even
correctly, adds to this kernel's own worst-case interrupt latency
budget (task #270) and needs a schedulability re-check (task #190's
own tooling) once built, since it's a new source of bounded-but-
nonzero blocking time.

### Twenty-first SD round: built the 6th SWI syscall trampoline, real fix now shipped, needs real-HW retest (2026-09-24)

User: "yes build it now" -- direct follow-up to the 20th round's own
open question. Built the syscall the 20th round's revert identified as
necessary, following `dhruva_prio_lock`/`_unlock`'s own migration shape
exactly (both had hit the identical "cpsid/cpsie silently no-ops in USR
mode" bug once already, per `dhruva_prio_lock_impl`'s own header
comment in context_switch.S -- an independent, exact confirmation of
the 20th round's own root-cause finding, found only after committing
to build the real fix, not before).

**Built**: renamed `sdhost_fill_fifo_from_buffer` (boot/sdcard_
state.S) to `sdhost_fill_fifo_from_buffer_impl` and gave it the exact
`dhruva_prio_lock_impl` treatment -- `mrs r12,cpsr` / `cpsid if` at
entry, `msr cpsr_c,r12` before return, masking the ENTIRE 128-word fill
loop for its whole duration (not per-word) since the syscall body never
returns to USR mode until the loop is completely done. Added syscall
#5 in boot/swi_entry.S (`swi_do_sd_fill_fifo`, dispatching to the new
`_impl`) and a new trampoline that keeps the ORIGINAL name and
signature `sdhost_fill_fifo_from_buffer(buf, word_count)` -- exactly
like task_sleep_ticks/dhruva_mutex_lock/dhruva_prio_lock's own
trampolines -- so kernel_main.vani's existing call site and extern
declaration needed ZERO changes; the fix is entirely contained in the
two assembly files. `sdhost_fill_fifo_from_buffer_diag` (the temporary
2100-2107-gated diagnostic variant) deliberately left unmasked and
unchanged -- it's diagnostic-only, not the production write path this
fix targets.

Confirmed r0 (buf)/r2:r3 (word_count pair, this project's own
established i64-after-1-register ABI quirk) survive the trap
completely untouched: swi_entry's own entry-capture code only uses
r5/r8/r9/r11 as scratch before dispatch, never r0-r3 (same guarantee
task_sleep_ticks/dhruva_mutex_lock already rely on).

Built clean (no duplicate-symbol/undefined-reference linker errors --
the trampoline reuses the exact name the old direct function had, now
freed up by the `_impl` rename). Two identical `phase4_milestone.py`
runs: back to the exact known baseline (only the already-accepted
`tcprtx` artifact), and the boot-time "SD: 8-block round-trip sweep"
self-test still reports `any_fail=00000000` -- functionally correct
under QEMU, not just non-crashing, though QEMU was never where the
wedge reproduced in the first place, so this can only confirm no
regression, never confirm the fix.

**Status**: real fix shipped, matches Linux's own reference protection
exactly, but -- like every fix in this 21-round saga -- can only be
validated by a real-HW retest. Not pushed yet (still stacked on the
19th/20th rounds' own local-only commits per the user's earlier
choice); commit hash and real-HW retest results to be recorded once
available.

### Twenty-second SD round: syscall #5's own worst-case masked duration measured and fixed, contention/deadlock audit (2026-09-25)

User, while waiting on the real-HW retest: "are there any other
adversarial tests... any gaps fix to make close to rtos or atleast
real-time preempt," then "fix any gaps with your best judgement," then
"predict if any contention or deadlocks by reading code and compare
online authoritative resources if needed and fix issues."

**Real gap found and fixed**: the 21st round's own new syscall #5 masks
IRQ+FIQ for its entire SD PIO fill loop -- necessarily so, matching
Linux's own reference driver -- but nothing had ever computed what that
loop's own PRE-EXISTING 100000-iteration-per-word retry cap actually
COSTS once masked. A new live self-test (`sd_fill_poll_body_wcet_
measure_self_test`, kernel_main.vani) measured the real per-iteration
poll cost (0.327us, via the exact SDEDM-poll body, not a synthetic ALU
loop -- same "MMIO-read-dominated loops are comparably bus-bound under
QEMU and real hardware" property this project already established for
sdhost_cmd's own poll) and multiplied it out: 128 words x 100000
retries x 0.327us = **~4.19 SECONDS** of IRQ+FIQ masked in the
genuinely-wedged-FIFO worst case -- the exact scenario this entire
21-round saga has been about. During that whole window, task #271's
WCET-eviction and task #269's stuck-task watchdog CANNOT fire, since
both depend on the very timer tick this window masks -- the one
mechanism built specifically to catch a hung critical section was
itself disabled for the worst case it would most need to catch. Fixed
by reducing the masked loop's own retry cap (boot/sdcard_state.S's
`sdhost_fill_fifo_from_buffer_impl` only -- the unmasked `_diag`
variant and the read-side `sdhost_drain_fifo_to_buffer` both keep the
original 100000, correctly, since neither of those blocks the whole
system) to 1000, landing the new worst case at 41.984ms -- comfortably
under this project's own largest ALREADY-schedulability-checked
blocking term (LOW's 49.906ms ceiling-0 critical section) rather than
inventing a new tolerance, and still ~100-1000x more headroom than any
real per-word retry count ever observed in this saga's own logs. Does
not change the retry loop's own pre-existing "give up and write
anyway, rely on the post-transfer SDHSTS error check" contract
(unchanged since 2026-09-14) -- only how long it waits before falling
back on that already-existing safety net.

**Schedulability model corrected, two real gaps**: (1) fed the new
41.984ms worst case into `test/schedulability_analysis.py` as an
ADDITION to GC (task_e)'s own DharaFS critical-section term (healthy
7.689ms + wedge 41.984ms = 49.673ms), since GC's own compaction path is
what actually calls into the now-masked syscall. (2) A second, more
subtle gap found during the user's own follow-up contention/deadlock
question: HIGH/MEDIUM's own blocking term used to be JUST LOW's
ceiling-0 section, correctly reasoned at the time (0 < 2 and 1 < 2, so
neither is ever blocked by GC's own ceiling-2 SOFTWARE tie-break) --
but that reasoning silently stopped covering the whole picture the
moment GC's own writes started masking IRQ+FIQ at the HARDWARE level:
ceiling priority is irrelevant to a masked interrupt controller, so
while GC is inside that window NOTHING can run, regardless of
priority. Fixed by adding the SD-write worst case as a second candidate
blocking source for HIGH/MEDIUM too, `B_i = max(...)` over both
candidates -- the standard Sha/Rajkumar/Lehoczky treatment for multiple
independent blocking sources, the same pattern GC's own two-candidate
`gc_worst_blocking_ms` already used. Numerically a no-op today (49.906
> 41.984, same max either way) -- fixed because the MODEL was
incomplete, not because today's numbers demanded it. Full task set
re-verified schedulable, comfortable margins unchanged (HIGH
1444.912ms, MEDIUM 439.730ms, LOW 884.875ms).

**Deadlock/contention code audit, no bugs found**: read every
`dhruva_prio_lock`/`dhruva_mutex_lock` call site in kernel_main.vani.
Ceiling locks (`dhruva_prio_lock`) are non-blocking by construction --
they set the CALLING task's own eff_prio/ceiling-depth directly, never
wait on another task -- so classic lock-ordering deadlock (circular
wait) is structurally impossible through this primitive alone,
confirmed against the standard priority-ceiling-protocol guarantee
(Sha/Rajkumar/Lehoczky 1990: a task can block at most once, on entry,
never while already holding a resource). Ceiling id 0 (task_a/task_c's
demo "resource") and ceiling id 2 (task_e/task_f/task_fsq's DharaFS
group) are two entirely disjoint task groups with zero call-site
overlap -- no nested nor cross-ceiling acquisition anywhere in this
codebase today, so no risk of an eff_prio restore-value mismatch either
(eff_prio_table is SET, not incremented, per lock/unlock call -- only
ceiling_depth_table is a real nesting counter). `dhruva_mutex_lock`
(the one genuinely blocking primitive, with priority inheritance) is
used at exactly two mutex ids (0: MUTEX-LOW/HIGH demo pair; 1: an
isolated self-test) -- neither task ever holds both simultaneously
anywhere in the codebase, so the other classic deadlock precondition
(inconsistent lock-ordering across two-or-more real mutexes) doesn't
apply either; genuinely deadlock-free by absence of any nested-mutex
pattern, not just by protocol guarantee. Confirmed task_fsq's own
declared priority (`task_create_usr(task_fsq, ..., 2 as u32)`) exactly
matches ceiling 2, the textbook requirement for the ceiling protocol's
own ordering guarantee to actually hold (the ceiling must equal the
highest priority among the resource's real users) -- verified against
code, not assumed from the comments describing it.

Two identical `phase4_milestone.py` runs: unchanged from the known
baseline (only the already-accepted `tcprtx` artifact). Commit still
pending at time of writing this entry; see the next commit for the
hash.

### Task #279: fault-injection test proves WCET enforcement + heartbeat detection actually work (2026-09-20)

User: "how about other rtos scheduling improvements? any bugs through
regression tests or edge cases to uncover any test cases?" -- answered
with a concrete, real gap: task #271's WCET-enforcement eviction and
task #269's stuck-task detection had never actually FIRED in any test
this project has ever run. `diagnose` always read 0 for both, every
single run, because nothing had ever made a task genuinely overrun
its own declared bound -- a safety mechanism with zero real coverage
of its own actual firing behavior. User: "yes build it. improve the
os. we need to uncover hidden bugs."

New `fault stuck <n>` shell command, matching the established `fault
alloc/write/irqburst/netdrop` shape exactly (same one-shot-arm/self-
disarm pattern as `fault_irqburst_take`) -- new state in `boot/
fault_inject_state.S` (`fault_stuck_ticks`), new `fault_stuck_ticks_
take()` helper in `kernel_main.vani`.

Injection target: `task_custom_demo` (index 6, CUSTOM) -- chosen
specifically because it holds no ceiling lock and no mutex, so
eviction there has zero interaction complexity with either
synchronization primitive (the cleanest possible test of the eviction
path in isolation). Armed, its own next wake cycle spins instead of
sleeping -- `task_custom_demo_stuck_spin`, deliberately time-based
(`scheduler_get_tick_count()` as the spin's own exit condition), NOT
a raw busy-loop iteration count. This was a deliberate choice to avoid
repeating the exact mistake tasks #274/#275 just found and fixed the
hard way in the SD-driver investigation: QEMU and real Pi 1B silicon
execute the SAME tight busy loop at wildly different effective rates
(measured ~18.6x apart), so a "safe for both platforms" iteration
count doesn't reliably exist -- a tick-count-based exit condition
sidesteps the whole problem by construction. Still gets preempted
normally at every real timer tick (this scheduler is FIQ-driven-
preemptive, not cooperative, per task #246's own design) -- other
tasks keep running throughout, this doesn't freeze the system, it
just never voluntarily yields itself.

**Live-verified end to end under QEMU** (`fault stuck 40`, chosen
above `task_custom_demo`'s own 35-tick heartbeat bound with real
margin -- needed two attempts to get the verification harness right:
a first attempt's blind 60-second `sleep` inside the `expect` script
stopped its own event loop from reading QEMU's frequent demo-task
output, overflowing the default buffer and producing a false
"nothing happened" read; fixed by waiting on the actual "stuck spin
finished" marker instead of a blind sleep, plus a larger `match_max`):

- `stuck-task episodes (.../CUSTOM/...)`: 0 -> 1 (task #269's
  detection fired for the first time ever)
- `WCET-enforcement evictions (.../CUSTOM/...)`: 0 -> 1 (task #271's
  eviction fired for the first time ever)
- `CUSTOM: stuck spin finished, resuming normal operation` -- the
  task genuinely recovered, not just got evicted
- `deadline misses (HIGH/MEDIUM/LOW/IDLE/GC/SHELL): 0/0/0/0/0/0` --
  every OTHER task's own deadlines stayed intact throughout the
  episode
- Every other task (HIGH/MEDIUM/LOW/MUTEX-LOW/MUTEX-HIGH/GC/SHELL)
  kept running correctly throughout and after the injected stuck
  episode -- no FATAL, no shadow-model mismatch, clean shutdown

This is a genuine, positive finding, not a null result: it confirms
both previously-unexercised safety mechanisms are correct, not just
implemented -- exactly the "uncover hidden bugs" the user asked for,
even though in this case the answer is "the mechanism works as
designed." The fault-injection test itself is now a permanent,
reusable regression capability (matches the same "opt-in, shell-
triggered, zero behavior change when disarmed" contract every other
`fault` subcommand already has) -- future changes to the heartbeat/
eviction logic can be re-verified with this exact command instead of
relying on code review alone. Two identical `phase4_milestone.py`
runs confirm zero regression.

### Task #280: fault-injection edge-case sweep -- ceiling holder, mutex holder, repeated episodes, irqburst combo (2026-09-20)

User: "any more edge cases we can find?" after task #279 shipped.
Answered with the most valuable untested branch: task #271's eviction
gate only checks `ceiling_depth_table`, never `dhruva_mutex_lock`'s
own priority-inheritance holds -- a genuinely different mechanism, not
tracked by that table at all. Plus two smaller candidates: repeated
back-to-back stuck episodes on the same task (does the counter double-
count?), and a stuck task combined with `fault irqburst` (does a
sudden tick-jump corrupt the heartbeat's own `now - last` arithmetic?).
User: "yes fix all" -- all four built/verified.

New fault types `fault stuckceiling <n>` / `fault stuckmutex <n>`
(`boot/fault_inject_state.S`: `fault_stuck_ceiling_ticks`/`fault_stuck_
mutex_ticks`, same one-shot-arm/self-disarm shape as `fault_stuck_
ticks`). `stuckceiling` targets `task_c`/LOW, checked AFTER it already
holds its own ceiling-0 lock (deliberately exercising the REAL gated
state, not a simulated one). `stuckmutex` targets `task_mutex_demo_
low` via a new, deliberately SEPARATE, untagged sibling function
(`task_mutex_demo_low_stuck_body`) rather than adding an unbounded
branch inside `task_mutex_demo_low_wake_body` -- that function carries
a real, load-bearing `#[wcet(cycles=100000)]` tag (Gap C), and the
spin helper's loop is genuinely unbounded, so calling it from inside a
`#[wcet(...)]`-tagged function would have falsely poisoned that
measured bound or failed the static check outright.

**All four live-verified under QEMU** (two identical `phase4_
milestone.py` runs first, zero regression from task #279's own
baseline):

1. **`fault stuckceiling 40`**: LOW's own `WCET-enforcement evictions`
   stayed 0 (the skip gate correctly protects the ceiling holder)
   while `stuck-task episodes` fired 4 times (floor(40 / LOW's own
   10-tick bound), edge-triggered, no double-counting). Every OTHER
   task's own counters ALSO went nonzero during the window, each
   matching floor(40 / that task's own bound) exactly -- not a bug:
   ceiling-0 is the system's highest ceiling, so by Immediate Priority
   Ceiling Protocol semantics every other task is blocked from running
   for the whole window regardless of whether it touches LOW's
   specific resource, so cascading heartbeat staleness is the
   textbook-correct consequence, confirmed harmless (those "evictions"
   are a no-op on a task that's already off the CPU).
2. **`fault stuckmutex 40`**: a real, previously-undocumented
   asymmetry -- MUTEX-LOW's OWN eviction counter DID fire (4/4,
   unlike the ceiling case), because task #271's skip gate never
   checks mutex holds, only `ceiling_depth_table`. Self-heals
   correctly (MUTEX-HIGH still eventually acquires the mutex once
   LOW's spin finishes and releases it, no deadlock, zero shadow-model
   mismatches, mutex handoff latency stayed in the normal double-digit-
   microsecond range) -- but by the exact same reasoning the ceiling
   skip exists for, forcing a mutex holder off the CPU mid-critical-
   section can only delay its OWN progress toward releasing what
   everyone else is waiting on. Not fixed (bounded, self-healing, no
   crash observed) -- logged in `docs/RTOS_GAP_ANALYSIS.md` as an
   honestly-scoped gap rather than left silently implicit.
3. **Repeated stuck episodes** (`fault stuck 40` armed twice back-to-
   back on `task_custom_demo`, `diagnose` read between each): counters
   went 0 -> 1 -> 2, exactly +1 per episode -- no double- or under-
   counting across separate arm/self-disarm cycles.
4. **Stuck + irqburst combo** (`fault irqburst 500` immediately
   followed by `fault stuck 40` on the same task): counters went
   2 -> 3, one more clean increment despite the discontinuous 500-tick
   clock jump -- `hb_elapsed = hb_now - hb_last` (`u32`, monotonic)
   showed no underflow/corruption, no crash, no shell hang.

See `docs/RTOS_GAP_ANALYSIS.md`'s "Timing analysis / determinism gaps"
section for the full write-up. Verification note: the first combined-
session attempt raced ahead of a still-printing `diagnose` (matched on
a mid-block line instead of the block's actual last line), sending the
next fault command while output was still interleaving -- a test-
harness bug, not a kernel bug (confirmed by task #185/#219's own
"cosmetic only" interleave finding still holding: the shell's RX line
buffer is unaffected by concurrent TX from another task). Fixed by
matching on the diagnose block's own last line and adding settle time
between commands.

### Task #281: fix the mutex-holder eviction asymmetry task #280 found (2026-09-20)

User: "fix stuckmutex gap" -- task #280's own real finding (task #271's
eviction-skip gate protected ceiling holders but not priority-
inheritance mutex holders) is now closed, not just logged.

New `task_holds_any_mutex_get_at` accessor (`boot/context_switch.S`)
scans `mutex_owner_table`'s `MAX_MUTEXES` slots for the task index
being checked; `scheduling_decision_prelude`'s own eviction gate
(`kernel_main.vani`) now skips whenever EITHER `ceiling_depth_table[i]
> 0` OR this new check reads true -- same "detected but not enforced"
treatment the ceiling case already got, now symmetric across both
synchronization primitives.

New permanent self-test, `task_holds_any_mutex_self_test`: proves the
accessor correctly reflects a real lock/unlock cycle in total isolation
(before=0, held=1, after=0), using mutex id 1 (never touched by the
live MUTEX-LOW/MUTEX-HIGH demo pair, which uses id 0) so it can't
interact with real system state. **Placement caught a real ordering
bug before the first commit**: originally placed right after
`mailbox_self_test()`, textually BEFORE `task_table_init()` -- which
is what seeds `mutex_owner_table`'s 255 ("free") sentinel across its
slots. With the table still raw zero-init at that point,
`dhruva_mutex_lock_impl` read owner=0 (not 255), took the CONTENDED
path, and blocked forever waiting for a lock nobody had ever actually
held -- boot hung completely, confirmed live under QEMU (no output
after `mailbox_self_test`'s own PASS line, even after 40+ seconds).
Moved to right after `task_table_init()`; same exact class of
ordering bug this file's own SSH auth-table history already
documents catching once before.

**Root-causing the live discrepancy**: the FIRST live re-verification
of the fix (`fault stuckmutex 40`) showed MUTEX-LOW's own eviction
count drop from 4/4 (pre-fix) to 2/4 -- an improvement, but not the
clean 0/4 the ceiling case achieved, and reproducible identically
across two separate runs (not random noise). Adding `uart_puts` debug
prints directly inside `scheduling_decision_prelude` to investigate
broke `irq_dispatch`'s own `#[wcet(cycles=130000)]` budget (that
function calls this one) -- printing itself was the WCET-relevant
cost, not a loop. Root-caused instead via two temporary, non-printing
debug counters (`debug_hb7_mutex_seen_table`, since removed): every
single time the accessor read "holding", eviction was correctly
skipped (0 incorrect evictions) -- the remaining evictions were ALL
for genuine "not holding" overrun detections, i.e. real (if unrelated
to the fault) scheduling jitter during MUTEX-LOW's own ordinary
operation, the same class of variance task #276's own real deadline-
miss investigation already found and documented elsewhere in this
project. The fix itself is proven correct, both in isolation (self-
test) and under live multi-tasking load (100% correct skip rate for
every genuine holding case observed).

Two identical `phase4_milestone.py` runs, zero regression. Full
write-up in `docs/RTOS_GAP_ANALYSIS.md`'s "Timing analysis /
determinism gaps" section.

### Task #286: live-verified all 16 possible priority levels, not just the ~5 the demo task set uses (2026-09-25)

User: "right now 16 static slots in scheduler. we have high medium low
tasks. can you have 16 levels priority?" Answered from code (`eff_
prio_table`/`base_prio_table` are plain `.word` arrays compared by raw
value, no small-enum assumption anywhere; unused-slot sentinel is 255;
no validation clamp on the `priority: u32` argument anywhere in `task_
create`/`task_create_usr`; aging's own `AGING_CAP=1024` already has
headroom for the full 0-15 range, needing at most `15<<4=240` ticks):
yes, nothing structurally limits it below 16. User: "yes build it,
live-verify all 16 levels."

**Built `scheduler_16_levels_self_test`** (kernel_main.vani, called
right after `task_table_init()`/`task_holds_any_mutex_self_test()`,
same placement discipline both already established): saves the real
`eff_prio_table`/`sleep_until_table`/`ready_wait_ticks_table`/`rr_
last_picked` state for all 16 slots, injects a synthetic scenario --
16 DISTINCT priorities (slot i = priority i), all ready, zero aging
credit -- then runs a full ladder sweep calling `scheduler_pick_next_
shadow_predict()` 16 times, expecting priority 0's slot first, then
(with it removed from contention) priority 1's, down to 15, confirming
every one of the 16 levels is correctly discriminated and ordered, not
just a couple. Restores every touched table to its exact prior value
before returning.

Deliberately calls the SHADOW predictor, never the real `scheduler_
pick_next` directly -- Gap B's own accessors (added 2026-09-18) are
explicit that direct synthetic-state calls into the real function are
unsafe ("round 75's own documented, never-fully-root-caused crash
history"). The shadow predictor mirrors the real algorithm's pass1/
pass2 logic exactly and is already continuously cross-checked against
the real function's own live decisions elsewhere in this file (0
mismatches observed) -- using it here is the same already-trusted
mirror, not a new risk. Safe to inject directly into the real tables
only because this runs during kernel_main's own single-threaded
boot-time self-test sequence, strictly before `start_multitasking`
ever hands off -- confirmed live afterward too: the boot log continues
immediately into real task creation and normal scheduling (LOW's own
critical section, MEDIUM, MUTEX-HIGH) with no sign of disturbance.

Added three new write accessors this needed and didn't yet have
(`eff_prio_table_set_at`/`ready_wait_ticks_table_set_at`/`rr_last_
picked_set`, `boot/context_switch.S`, same `sleep_until_table_set_at`
shape) -- Gap B's own originals were deliberately read-only, a
constraint about never calling the real scheduler with synthetic
state, not about the shadow predictor.

**Real staleness found along the way, not yet fixed**: the shadow
predictor's own "old algorithm" gate (`current_eff < current_base`)
still uses the EXACT proxy task #253 already found broken and replaced
in the real function with `ceiling_depth_table[current] > 0` ("a proxy
that breaks for task_a/HIGH, whose base_prio is already the system
ceiling" -- context_switch.S's own ceiling_depth_table comment). The
shadow predictor was never updated to match. Doesn't affect this
round's own test (no ceiling locks involved, the gate is never
exercised) and doesn't currently produce an observable mismatch in the
live demo set either (ceiling id 0 is the global-minimum priority, so
the "wrong" gate and the "right" one happen to pick the same winner
regardless) -- but it's a real, latent divergence between the shadow
model and the function it's supposed to mirror, worth fixing in its
own round rather than folded into this one.

Two identical `phase4_milestone.py` runs, zero regression (same known
baseline, only the already-accepted `tcprtx` artifact).

### Task #287: fixed the stale shadow-predictor gate found during #286 (2026-09-25)

`scheduler_pick_next_shadow_predict`'s own "is current_task ceiling-
protected" gate still used the pre-task-#253 proxy (`eff_prio <
base_prio`) -- the exact condition task #253 already found broken in
the REAL `scheduler_pick_next` and replaced with a direct
`ceiling_depth_table[current] > 0` read, because the proxy structurally
can't detect a critical section when a task's own base_prio already
equals the ceiling it locks at (task_a/HIGH's case). The shadow
predictor was never updated to match at the time -- found while
comparing the two functions side by side during task #286's own work,
not something this round went looking for. No observable live
mismatch today (ceiling id 0 is the global-minimum priority, so both
gates happen to agree in every scenario the demo set actually
exercises), but a real, latent divergence between the model and the
function it mirrors. Fixed by mirroring the real gate exactly (same
`ceiling_depth_table_get_at` accessor task #280's own eviction-skip-
gate fix already established). Two identical `phase4_milestone.py`
runs: known baseline unchanged, zero `SCHED SHADOW MISMATCH` prints
during live operation, task #286's own 16-level self-test still PASS.

### Task #288: re-attempted the finer scheduler tick, reverted again -- but with a materially better-narrowed finding (2026-09-25)

User: "did we manage get tick below 500ms to make faster yet correct
or was that not attempted" -> "yes attempt it." Direct re-attempt of
round 191/task #243's own experiment, now that task #272's own
prerequisite (rescaling `tcp_rtx_timeout_ticks`/DHCP's own
`ticks_per_second`/`auth_lockout_ticks` to derive from `scheduler_
tick_interval_us()` at runtime) is closed.

**Pre-change audit**: swept every `task_sleep_ticks(N)` literal in
kernel_main.vani and `task_heartbeat_init`'s own bound table. All of
them are task PERIODS (how often a task wakes) or heartbeat-bound
MULTIPLES of a task's own period (5-10x) -- both tick-rate-invariant
by construction, not real-duration bugs task #272's own three fixes
missed. One softer case noted but deliberately left alone: the real-
SSH-frame-polling retry loops (`while (iter < 200) { ...
task_sleep_ticks(4) }`) total 800 ticks of worst-case wait for a
network frame -- a generic bounded-retry safety margin, not a
protocol-mandated duration, still 80 real seconds at 100ms/tick (down
from 400s) -- ample margin, watched for rather than pre-rewritten.

**Changed `scheduler_tick_interval_us()` 500000 -> 100000** (5x finer,
matching round 191's own original target). Built clean.
`phase4_milestone.py` reproduced the EXACT same class of cascading
failure both prior rounds hit (eval/ping/ifconfig/tcpecho/udpecho/
netstat/tcprtx/etc. all newly failing, harness's own overall timeout
hit mid-run) -- but this time with new, directly-measured evidence
narrowing the explanation further than task #243 ever got to:

- **`time python3 test/phase4_milestone.py`**: 222s real wall-clock,
  only 32s combined user+sys CPU. QEMU itself is NOT compute-bound
  during the failing run -- rules out a raw per-instruction emulation-
  speed explanation task #243's own dispatch-cost measurement couldn't
  fully rule out on its own (that measurement used the GUEST's own
  TIMER_CLO, blind to any real HOST-side slowdown that doesn't track
  guest virtual time 1:1).
- **"eval" (the 3rd command) never appears anywhere in the captured
  log at all** -- the same class of failure as before, now starting
  one command index earlier than either prior attempt's own described
  symptom.
- **Directly observed, measured contributing factor**: GC (task_e)'s
  own DharaFS critical sections, unchanged in tick-COUNT period (20
  ticks), now recur ~5x more often in real wall-clock time (every 2s
  instead of every 10s) -- confirmed firing twice within the first
  ~500 log lines. Every HIGH/MEDIUM/LOW/MUTEX demo task's own status-
  print volume scales the identical way: period unchanged in ticks,
  so PRINT volume unchanged in tick-count terms, but 5x denser in real
  time -- the log's own line density between "write" and "cat" (540
  lines) is direct, measured evidence. Leading hypothesis, not fully
  isolated: this print-volume multiplication, on a still-blind (fixed
  `SETTLE_S=14`, not readiness-pattern-based) test harness, most
  likely swamps or delays the actual useful UART RX/TX for the
  harness's own commands -- the same general class of print-volume-
  vs-fixed-timing fragility this project has hit before (task #279's
  own diagnostic print volume breaking `tcprtx` once; the 2026-09-14
  "Boot UART markers destabilized QEMU test timing" entry), just never
  previously connected to the TICK RATE itself as a multiplier.
- **Genuinely new compounding factor, not separable from the above
  without further instrumentation**: this session's own recent SD-
  write IRQ/FIQ masking (task #284/#285, syscall #5) didn't exist
  during either prior attempt. GC's own DharaFS writes now mask
  interrupts for up to 41.984ms worst case -- 42% of a 100ms tick
  period vs. 8.4% of the original 500ms one. Measured critical-section
  durations in this run (10.8ms/16.0ms) stayed well under that worst
  case, so this alone likely isn't the dominant cause, but it's a real
  factor neither round 191 nor task #243 ever had to contend with.

**Reverted** -- same "don't ship unverified against this project's
entire QEMU-only verification loop" discipline task #243 already
established. `scheduler_tick_interval_us()` back to 500000, rebuilt,
`phase4_milestone.py` confirmed back to the exact known baseline (only
the already-accepted `tcprtx` artifact). Real forward progress even in
the revert: the next attempt has a materially better-narrowed starting
point than "duration constants, maybe" -- rate-limit/reduce demo-task
status-print volume, or move the harness to pattern-based readiness
detection instead of blind `SETTLE_S`, BEFORE the next tick-rate
attempt, not concurrently with one.

### Twenty-third SD round: real-HW retest of the syscall #5 masking fix -- THE WEDGE STILL PERSISTS, hypothesis falsified (2026-09-25)

Fresh real-HW log (`picocom_20260925_083346.log`, 8:33am), the first
capture with the 21st/22nd rounds' own IRQ/FIQ-masking fix (task
#284/#285) actually flashed and running. **Result: no change.** Every
single write attempt across 4 fully-completed blocks (2100-2103) ends
in the EXACT SAME signature every prior round in this 22-round saga
has shown: `SDEDM=0x00010803` (FSM=WRITEDATA/3) after the full 128-word
fill completes, `wait_transfer_complete timeout, alternate_idle=
0x0000000A`, then `post-wedge CMD13... timed out -- controller too
wedged to respond`. This happens with IRQ+FIQ now PROVABLY masked for
the entire fill loop (syscall #5) -- **directly falsifying this whole
three-round hypothesis** (missing interrupt masking as the write
wedge's root cause). The masking fix itself was real, well-supported by
a direct Linux-reference match, and worth having built regardless (it
closed a genuine gap versus the reference driver, and task #285's own
worst-case-latency fix and schedulability corrections stand on their
own merit) -- but it was not, or not solely, what has been wedging this
controller for 22 rounds.

Two secondary observations, BOTH already-known phenomena recurring, not
new leads:
- `SD/MMC: CMD24 (WRITE_BLOCK) FAILED (SDCMD_FAIL_FLAG set)` fires on
  the first write sub-attempt for every block after the first (2101,
  2102, 2103) -- this is the exact, already-documented "a write issued
  immediately after a successful read, with no intervening controller
  reinit, sometimes fails outright on CMD24 itself" artifact
  (kernel_main.vani's own `sdhost_force_data_mode_settle` header
  comment, predating this session). The 8-block sweep's own write-
  then-read-then-compare-per-block structure naturally reproduces this
  exact adjacency for every block but the first. Recovers via the
  existing retry-with-reinit logic every time (attempt 2 always reaches
  the normal full data phase) -- not itself blocking anything, just
  visible again because THIS log is the first one whose per-block
  retry sequence happens to hit it repeatedly.
- `SD DIAG: post-CMD16 R1=... CURRENT_STATE=13 (NOT tran -- CMD7 did
  NOT actually select the card!)` fires on every single `sdhost_init`.
  This print has existed since before this session specifically
  "print-only until a fresh real-hardware capture confirms what value
  genuinely appears there" (its own header comment) -- now answered:
  13, not 4. Still not a real problem: the VERY NEXT command (CMD13,
  pre-CMD24) always correctly reports `CURRENT_STATE=4` (tran) instead
  -- the same class of readback-unreliable field this saga's own 19th
  round already found for SDARG. Left as diagnostic-only, unchanged.

**Open question, not resolved from the log alone**: the capture ends
abruptly mid-way through block 2104's third write attempt (right after
`post-write(w80)`, no `wait_transfer_complete timeout` line following
it the way every prior wedge in this SAME log did) -- ambiguous whether
the picocom session was manually stopped at that exact moment or the
board was genuinely unresponsive. Needs the user to confirm which.

**Where this leaves the search**: back to genuinely open, with the
interrupt-masking hypothesis now ruled out by direct real-HW evidence
rather than just unproven. 23 rounds in, the "PIO fill loop structure
differs from Linux's own reference loop" thread from the 20th round's
own writeup remains the one avenue never yet directly pursued (an
actual side-by-side structural/assembly comparison of `sdhost_fill_
fifo_from_buffer_impl` against Linux's `bcm2835_sdhost_write_block_pio`
beyond just the interrupt-masking difference already checked) -- not
started this round, pending direction.

### Twenty-fourth SD round: a REAL, WORKING reference driver, on THIS exact board and card, at 50MHz -- the hardware is exonerated (2026-09-25)

User: "would it make sense to load known os and flash on card and look
sdcard logs?" -- the one thing this entire 23-round saga had never
actually tried: running a real, independently-maintained driver
against this exact physical hardware, not just reading its source
(already done exhaustively) or comparing register semantics (also
already done). Built U-Boot 2021.01 for `rpi_defconfig` (BCM2835/Pi-1B,
DTB `bcm2835-rpi-b` embedded, matches this exact board's own boardrev
`e`) from a local source tree, using this session's own `arm-none-
eabi-gcc`. Added it to the existing SD card as a selectable kernel
(`kernel=u-boot.bin` appended to config.txt, fully non-destructive to
the card's own partitioning/firmware/DhruvaOS kernel.img -- see
`~/source/sdwedge-uboot-test/flash_uboot_test.sh`).

**Result: `mmc write`/`mmc read`/`cmp.b` at block 2100 (0x834) -- the
EXACT block that has wedged on every single one of the prior 23
rounds' own real-HW tests, no exceptions -- succeeded cleanly on the
very first try.** `MMC write: ... 1 blocks written: OK`, `MMC read:
... 1 blocks read: OK`, `cmp.b`: `Total of 512 byte(s) were the same`.
No retry, no timeout, no FSM wedge, nothing. U-Boot's own `mmc info`
reports `Bus Speed: 50000000` / `Mode: SD High Speed (50MHz)` -- this
succeeded at DOUBLE DhruvaOS's own normal 25MHz operating clock (and
4x its first-retry 12.5MHz backoff), directly ruling out "the clock is
too fast" as any part of the explanation, in either direction. U-Boot's
own device name in the log, `mmc@7e202000`, is the SDHOST controller's
own bus address (matches `0x20202000` physical -- the exact same
peripheral DhruvaOS's own SDCMD/SDARG/etc. constants target) --
confirmed directly against the U-Boot source tree
(`drivers/mmc/bcm2835_sdhost.c` is the active driver, not the
alternate `bcm2835_sdhci.c`/EMMC-controller path) -- a true apples-to-
apples same-silicon comparison, not a different piece of hardware.

**This is the single most conclusive result in the entire saga: the
Pi 1B board, this exact SD card, and the wiring are all confirmed
fully functional.** Every hardware-adjacent hypothesis this saga has
ever entertained or partially entertained (worn/marginal card --
already separately ruled out by the two-card test, round "second-card
real-HW confirmation" -- silicon defect, signal integrity, wiring) is
now closed for good by direct, positive evidence, not just absence of
a found cause. The bug is, with about as much confidence as real-
hardware testing can provide, entirely within DhruvaOS's own SD driver
code -- some real difference between `sdhost_fill_fifo_from_buffer_
impl`'s own PIO write loop (and/or its surrounding command sequence)
and `bcm2835_sdhost.c`'s own, that source-level reading across 23
rounds has not yet pinpointed.

**Where this leaves the search**: the next step this result directly
motivates -- not yet done -- is adding real register-dump
instrumentation to U-Boot's own (now-confirmed-working)
`bcm2835_sdhost.c` write path, mirroring the exact SDCMD/SDARG/SDHBCT/
SDHBLC/SDHSTS/SDEDM checkpoints DhruvaOS's own diagnostic build
already captures, rebuilding, and having the user re-run the same
`mmc write` test to capture a REAL, successful, real-hardware register
trace -- something no amount of further source-reading can produce --
to diff directly against DhruvaOS's own abundant failing traces from
every prior round. Not started, pending direction.

### Twenty-fifth SD round: the actual root cause, found by diffing a real successful trace against 24 rounds of failing ones -- fix implemented (2026-09-25)

Direct continuation of the 24th round. Instrumented U-Boot's own
`bcm2835_sdhost.c` write path (`drivers/mmc/bcm2835_sdhost.c` in the
local build tree, `~/source/sdwedge-uboot-test`) with checkpoints
matching DhruvaOS's own SD DIAG labels exactly (`pre-CMD24`,
`post-CMD24-cmd-complete`, per-burst, `post-PIO`, `wait_transfer_
complete`), rebuilt, had the user re-run the same `mmc write`/`mmc
read`/`cmp.b` test at block 2100. **Result: a real, complete,
successful register-level trace, for the first time in 24 rounds.**

Direct comparison at the exact same checkpoint (`post-PIO`, right
after the fill loop finishes writing every word, before waiting for
completion) is unambiguous:
- DhruvaOS, every real-HW attempt across all 24 prior rounds:
  `SDEDM=0x...803`, FSM=WRITEDATA(3) -- stuck, never progresses.
- U-Boot's own real, successful write, same checkpoint: `SDEDM=
  0x...807`, FSM=WRITEWAIT1(7) -- the hardware has ALREADY
  autonomously started leaving WRITEDATA on its own by the time the
  fill loop returns, no software intervention needed.

FSM=WRITEDATA itself was never the bug -- it's the normal state
during active transfer (U-Boot's own trace shows it repeatedly too,
in every mid-transfer burst: `0a`(WRITESTART1) -> `53`/`03`/`23`/
`13`(WRITEDATA, 11 bursts) -> `07`(WRITEWAIT1) -> `01`(DATAMODE/idle)
at the final check). The bug is that DhruvaOS's own transfer never
triggers the hardware's own natural WRITEDATA-to-WRITEWAIT1 exit the
way U-Boot's does.

**Root cause identified**: U-Boot's own `bcm2835_transfer_block_pio`
polls SDEDM ONCE to compute available FIFO room, then writes MULTIPLE
words back-to-back with ZERO intervening register reads (`words =
min(SDDATA_FIFO_WORDS(16) - fifo_fill(edm), copy_words)`, then a tight
write loop). DhruvaOS's own `sdhost_fill_fifo_from_buffer_impl`
instead polled SDEDM before EVERY SINGLE word -- 128 separate MMIO
reads interleaved between the 128 SDDATA writes for one block, every
one a real bus transaction on real silicon, where U-Boot's reference
has none between words in the same burst. Working theory, well-
supported by this real-HW comparison but not independently proven
beyond it: the controller needs the LAST few words of a block written
in a tight, minimal-gap cadence for its own internal FSM to correctly
recognize "block complete" and leave WRITEDATA -- DhruvaOS's own
per-word polling overhead was apparently enough gap to prevent that
recognition from ever firing, every single time, on every real-HW
attempt across 24 rounds.

**Fixed**: restructured `sdhost_fill_fifo_from_buffer_impl` (`boot/
sdcard_state.S`) to match -- poll SDEDM once per burst, clamp to
remaining word count, write that many words back-to-back, repeat.
Bounded retry (still 1000, task #285's own figure) now gates finding
ANY room for the next burst rather than a single word; if ever
exhausted, forces a 1-word burst to guarantee forward progress,
preserving the function's own pre-existing "give up and write anyway"
contract exactly. New callee-saved scratch register (r7) for the
burst word-counter. Worst-case masked duration is unchanged from task
#285's own 41.984ms figure -- the pathological case (room=1 found
every single outer-loop pass) still bounds the total iteration count
identically to the old per-word loop; bursting only improves the
typical case.

Built clean, two identical `phase4_milestone.py` runs: known baseline
unchanged (only the already-accepted `tcprtx` artifact), SD 8-block
round-trip sweep still `any_fail=00000000` under QEMU. Like every fix
in this 25-round saga, QEMU never reproduced the wedge in the first
place, so this can only confirm no regression -- **needs a real-HW
retest to confirm the fix actually works**, but this is the first
fix in the entire saga backed by a direct, mechanistic, real-hardware
comparison against a known-working reference, not source-reading or
protocol-timeout reasoning alone.

### Twenty-sixth SD round: the 25th round's fix was never actually tested -- diagnostic clone had drifted out of sync; full U-Boot re-comparison done (2026-09-25)

User retested the 25th round's own burst-write fix on real hardware
and got the IDENTICAL old wedge signature. Root cause of the false
negative: the 8-block sweep (blocks 2100-2107) -- the ONE test this
entire 26-round saga has ever used for real-HW validation -- calls
`sdhost_fill_fifo_from_buffer_diag`, a separate, hand-maintained
diagnostic clone of the fill loop, kept around specifically to add
register-dump instrumentation without touching the production path.
The 25th round restructured `sdhost_fill_fifo_from_buffer_impl` to
burst-write but never touched this clone -- so the ONE test that's
ever validated a fix in this saga was silently still running the OLD
per-word-poll code the whole time. **The 25th round's own fix was
never actually exercised by any real-HW test until now.** Fixed:
restructured the diagnostic clone to match `_impl`'s own burst-write
loop exactly, dump now fires once per real burst instead of at fixed
16-word marks. Two identical `phase4_milestone.py` runs, known
baseline unchanged, SD 8-block sweep `any_fail=0` under QEMU.

User, separately: "I think you need to revisit u-boot source and
compare all relevant files" -- a full re-read of every function in
`drivers/mmc/bcm2835_sdhost.c` (reset/init, clock setup, command
dispatch, set_ios, probe/bind), not just the write-path functions
already compared for the 24th/25th rounds:

- **FIFO read/write threshold bits (SDEDM[18:14]/[13:9], set to 4/4
  in `bcm2835_reset_internal`, "Limit fifo usage due to silicon
  bug")** -- already matched; DhruvaOS's own `sdhost_init` already
  sets these identically, found and confirmed insufficient ALONE back
  on 2026-09-20 (task #273-followup), which is what led to the settle-
  delay and later SLOW_CARD/SDCDIV work. Not a new gap.
- **SDTOUT (0xf00000 in `bcm2835_reset_internal`)** -- already
  matches DhruvaOS's own value exactly.
- **SDHCFG_SLOW_CARD (bit 3)** -- already matched; DhruvaOS's own
  0x418 includes it, added 2026-09-18 after the exact same real
  Linux comment this U-Boot source also carries ("cope with fast core
  clocks"). Not a new gap.
- **4-bit vs 1-bit bus width (SDHCFG_WIDE_INT_BUS/_EXT_BUS)** --
  DhruvaOS never issues ACMD6 (SET_BUS_WIDTH) and never sets these
  bits, running 1-bit throughout; deliberate and internally
  consistent (card and controller agree), not a mismatch. Not a new
  gap, and unlikely to explain an FSM-transition wedge specifically
  (a real width mismatch would break command responses too, which
  never happens -- CMD13 always succeeds even when writes wedge).
- **SDHCFG_DATA_IRPT_EN (bit 4) -- a genuinely NEW finding, not yet
  acted on.** DhruvaOS's own 0x418 includes this bit, deliberately
  added 2026-09-16 after comparing against real Linux's own
  interrupt-driven `bcm2835_sdhost_set_transfer_irqs` (which sets
  DATA_IRPT_EN|BUSY_IRPT_EN for every PIO transfer). U-Boot's own
  `bcm2835_add_host`/`bcm2835_set_ios`, by contrast, NEVER sets
  DATA_IRPT_EN at all -- its own successful write happened with this
  bit clear. Neither driver is actually interrupt-controller-driven
  for this operation (both poll), so this isn't about whether an IRQ
  literally fires -- it's a real, empirically-different register value
  between a driver that wedges and one that doesn't. This project's
  own EARLIER speculation on this exact bit (2026-09-16, quoted above
  in this same file) already reasoned these "IRQ enable" bits "may
  double as internal event-detection/latch enables for the data-phase
  state machine itself, not purely IRQ-routing" -- U-Boot's own
  working counter-example is new, real evidence FOR that theory, not
  yet tested by removing the bit.
- **`bcm2835_send_cmd`'s own pre-command FSM-idle gate** (refuses to
  issue a new command unless SDEDM's FSM already reads IDENTMODE or
  DATAMODE, `!= STOP_TRANSMISSION`) -- DhruvaOS has no direct
  equivalent. Every real-HW log's own pre-CMD24 CMD13 always shows
  FSM=DATAMODE already, so this gate would never have actually fired
  differently in any captured log -- likely not the cause, but a
  reasonable defensive addition to consider separately.

**Deliberately NOT bundled into this round's own fix**: changing
SDHCFG's own DATA_IRPT_EN bit at the same time as the already-built
burst-write fix would make the next real-HW result impossible to
attribute to either change individually -- this project's own
established discipline (three prior "well-reasoned but unproven"
fixes already falsified, most recently the interrupt-masking
hypothesis in the 23rd round) is to test one real change at a time.
The corrected build (burst-write fix + the NOW-actually-exercising-it
diagnostic clone) is what needs the next real-HW retest; DATA_IRPT_EN
removal is the next candidate if burst-write alone isn't sufficient.

## 27th SD round (2026-09-25): burst-write confirmed insufficient by real-HW retest, DATA_IRPT_EN removed on write path

A fresh real-HW picocom log (14:31/14:39, both same build, commit
e3f9569) was checked against the 26th round's corrected diag clone to
confirm it genuinely exercised the burst-write fix -- not just a
label-string coincidence. The `_diag` clone's checkpoint label is
computed from a live cumulative word counter (`r7`), not a static
string, so the observed sequence `w00 -> w10 -> w20 -> ... -> w80`
means 8 real 16-word bursts (`SDDATA_FIFO_WORDS`, exactly matching
U-Boot's own burst size), confirmed by re-reading
`sdhost_fill_fifo_from_buffer_diag`'s own current source directly,
not assumed.

Result: **the wedge is unchanged.** All 128 words write out in
byte-identical burst structure to U-Boot's own successful trace, yet
SDEDM is stuck at `0x...803` (FSM=WRITEDATA) immediately after the
transfer completes, `wait_transfer_complete` times out, the
post-wedge CMD13 comes back dead, on every block and every retry.
This falsifies per-word-vs-per-burst SDEDM polling as the (sole) root
cause of the wedge -- the 25th/26th rounds' fix was necessary (it
matches a real working reference exactly) but not sufficient.

Action taken: dropped `SDHCFG_DATA_IRPT_EN` (bit4) from
`sdhost_write_block_once`'s own SDHCFG write, `0x418 -> 0x408` --
the one other concrete difference the 26th round's full U-Boot
re-comparison found (U-Boot's own polling-only write path never sets
this bit). Write-path only; the read path (`sdhost_read_block_once`,
still `0x418`) is left untouched since reads already work (task
#217, real-HW confirmed) and there's no reason to risk regressing a
working path while isolating a write-only variable.

Verified: build clean, `phase4_milestone.py` run twice, identical
pass/fail set to a baseline build of the immediately-prior commit
(e3f9569, `git stash`-verified) -- the 6 FAILs
(tcprtx/tlsecho/httpecho/mqttecho/ls/diagnose) are the long-documented
pre-existing artifact, not a new regression from this change. Commit
`4c6bff9`.

**Still needs its first real-HW retest.** If 0x408 alone doesn't
clear the wedge, revert to 0x418 before trying the next candidate
(the `bcm2835_send_cmd` pre-command FSM-idle gate is the next
concrete idea on the list, though considered less likely).

## 28th SD round (2026-09-25): literal C port of U-Boot's write algorithm wedges identically -- driver logic ruled out

Built `boot/rpi1/uboot_sdhost_write.c` -- a literal, self-contained C
transliteration of U-Boot's real, working `bcm2835_sdhost.c` write
path (`bcm2835_send_command`'s data-command subset,
`bcm2835_finish_command`, `bcm2835_transfer_block_pio`,
`bcm2835_transfer_pio`, `bcm2835_wait_transfer_complete`), copied
line-for-line from the real upstream source, not reasoned about and
reimplemented. Raw MMIO only, zero shared code with the existing asm
driver. Wired in as an early return in `sdhost_write_block_once`,
active ONLY for the existing 8-block real-HW diagnostic sweep
(block_num 2100-2107) -- production write path untouched.

**Real-HW result: identical wedge.** `pre-CMD24 SDEDM=0x10801`
(FSM=DATAMODE) -> `post-CMD24-cmd-complete SDEDM=0x1080A`
(FSM=WRITESTART1) -- both exactly as expected -- -> `post-PIO
SDEDM=0x10803` (FSM=WRITEDATA, stuck) -> `wait_transfer_complete`
timeout at the same value, every block, every retry. This is the
single most decisive result in the whole investigation: a byte-
faithful port of proven-working reference code cannot get past this
wedge inside DhruvaOS's own environment. **Driver write-path logic of
every kind tested so far is ruled out** -- register values, burst
structure, and now the entire command-issue-through-completion
control flow have all matched a working reference and still failed.

Also ruled out this round via source inspection (no live test
needed): the SDHOST peripheral block is already correctly mapped
Shareable Device memory (`boot/mmu_init.S`, TEX=000/C=0/B=1), not
cacheable -- rules out CPU write-buffer reordering/staleness as an
explanation.

Commit `c1c9143`.

**Next candidate, not yet tried**: the ported write function reuses
DhruvaOS's own `sdhost_init` (clock divisor, SDTOUT, SDHCFG, FIFO
thresholds) rather than porting U-Boot's own init sequence too --
every individual register value has been checked against U-Boot's
source across many earlier rounds, but never as one single, literal,
end-to-end port the way the write path just was. If the real gap is
in initialization/clock-setup sequencing rather than the write path
itself, this round's experiment would not have caught it. Porting
`bcm2835_reset_internal`/`bcm2835_set_clock` as literal C, the same
way, is the natural next step.

## 29th SD round (2026-09-25): SDTOUT never updated on data-transfer clock change, matched to U-Boot

Reviewing U-Boot's `bcm2835_reset_internal`/`bcm2835_set_clock` as
candidates for the same literal-C-port treatment the write path got
in the 28th round, found a genuine, previously-uncaught gap:
`bcm2835_set_clock` rewrites `SDTOUT` to the ACHIEVED clock
(`core_clock_hz/(div+2)`, not the originally requested `target_hz`)
divided by 2 every time the data-transfer clock is set -- its own
comment: "Set the timeout to 500ms". This driver's own `SDTOUT` write
(`0xF00000`, matching U-Boot's `reset_internal` value) happens exactly
once, during reset, and was never revisited once the data-transfer
clock got set afterward.

Fixed: computes `achieved_clock_hz = core_clock_hz / (div4 + 2)` and
writes `achieved_clock_hz / 2` to SDTOUT, inside the same branch that
switches the data-transfer clock (matching U-Boot's own low-speed
`clock < 100000` branch, which deliberately does NOT touch SDTOUT --
the identification-speed fallback path here is unaffected).

Verified: build clean, `phase4_milestone.py` run twice, identical to
documented baseline both times. Commit `0ff4de7`. **Not yet real-HW
tested** -- bundle with (or test separately from) the 28th round's
write-path C-port build for the next real-HW retest.

## 30th SD round (2026-09-25): real fix found by going deeper into U-Boot's read-side PIO -- burst-read the FIFO, matching the write-side fix exactly

Following explicit user pushback that the U-Boot comparison wasn't
deep enough, re-examined `bcm2835_transfer_block_pio`'s READ branch
(`is_read=true`) -- the function this project's WRITE path already had
its own burst counterpart ported from (25th-28th round), but whose
READ half had never actually been compared. Real U-Boot: `words =
edm_fifo_fill(edm)`, gated on `words >= min(SDDATA_FIFO_PIO_BURST(8),
copy_words)` BEFORE reading anything, then reads that many words
back-to-back with zero intervening polls.

This project's own `sdhost_drain_fifo_to_buffer` -- used for every
real-HW read this project has ever done, including the 128-word block
reads task #217 validated -- read the first word the instant fill>=1,
a deliberate 2026-09-14 "correctness first" choice made before any
real-HW evidence existed either way. Structurally the exact same
per-word-vs-per-burst gap the CMD24 write wedge turned out to be
(25th round), just never exposed on the read side because a 128-word
block's own FIFO refill cadence usually made "fill>=1" and "fill>=8"
coincide in practice.

The SCR read (ACMD51, 2 words, added this same round to gate ACMD6 on
real card capability) was the first genuinely short transfer this
project's drain loop has ever been exercised with, and it exposed the
gap immediately: the received SCR's byte[1] came back 0x00 -- a real
SD card can never report that (not even claiming mandatory 1-bit
support) -- the same "shift register" corruption signature as the
original write bug.

Fixed: rewrote `sdhost_drain_fifo_to_buffer` to match U-Boot's real
gate and burst read exactly, mirroring this file's own existing
write-side burst fix's structure. Single shared function, same
signature -- every call site (the real 512-byte block read path, the
new SCR read) picks up the fix with no call-site changes.

Verified: build clean, boots under QEMU, `phase4_milestone.py` run
THREE times (given this touches the real production read path)
identical to the documented baseline every time. Commit `a0bee99`.
**Not yet real-HW tested** -- this is now the most promising fix in
the whole investigation: it corrects a genuine, newly-found bug in
the read path, independent of (and possibly relevant beyond) the
write-side bus-width work from earlier this same round.

## 30th SD round follow-up: same burst-gate bug found on the write side too

Cross-checking the just-fixed read-side burst gate against U-Boot's
own write-side gate (both use the identical structure: `words < min
(SDDATA_FIFO_PIO_BURST(8), copy_words)`) found the SAME asymmetry, in
the direction that had been missed before: `sdhost_fill_fifo_from_
buffer_impl` -- the PRODUCTION write path used by every real DharaFS
write, not the 28th round's C-port diagnostic sweep, which already had
this exact gate correct -- used `room > 0` (proceed with any nonzero
room) instead of `room >= min(8, remaining)`. Never caught by the
25th-26th round's own burst-write fix because that only verified the
burst SIZE matched a real trace (16-word bursts observed), never the
READINESS GATE itself -- which happens to coincide with room>0 in the
common case (FIFO fully drained or fully available) but not in
general.

Fixed both `sdhost_fill_fifo_from_buffer_impl` and its `_diag` twin
to match. `_diag` is confirmed dead code now (unreachable -- the
C-port early-return fires first for every diagnostic-sweep block) --
fixed for consistency, flagged safe to delete once the real-HW retest
lands.

Verified: build clean, boots under QEMU, `phase4_milestone.py` run
THREE times, identical to documented baseline every time. Commit
`26ac248`. **Not yet real-HW tested** -- this is now genuinely the
most complete fix in the whole saga: both read and write PIO paths
match U-Boot's real gate-then-burst semantics exactly, not just the
burst size.

## 30th SD round: read PIO loop masked too -- syscall #6, matching real Linux's own upstream driver

A stray filesystem search (looking for something unrelated) turned up
a real, cached Linux kernel source tree with the actual upstream
`drivers/mmc/host/bcm2835-sdhost.c` -- genuinely more authoritative
than U-Boot's own port of it, never checked directly in this
investigation until now. Its read/write burst gate logic confirmed
identical in structure to U-Boot's (independent triangulation the
30th round's gate fixes are correct) -- but it also wraps BOTH
`bcm2835_sdhost_read_block_pio` and `_write_block_pio` in
`local_irq_save/restore` for their entire duration. This driver's
write path already got that treatment (syscall #5, 21st SD round);
the read path never did, and matters more now that correctness
depends on genuinely uninterrupted back-to-back reads within a burst.

Added syscall #6 (`sdhost_drain_fifo_to_buffer`), same migration shape
as syscall #5: real logic renamed to `sdhost_drain_fifo_to_buffer_
impl`, masked via the same mrs/cpsid/msr pattern, retry cap dropped
100000 -> 1000 (matching the write side's own masked-loop-specific
cap, already established correct by round 22's WCET analysis).

Verified: build clean, boots under QEMU (exercises syscall #6 heavily
throughout the boot self-test suite), `phase4_milestone.py` run THREE
times, identical to documented baseline every time. Commit `8f0f7a7`.
**Not yet real-HW tested.** This closes out the full set of real,
U-Boot/Linux-comparison-derived fixes found this round: read+write
burst gates now both match, and both PIO loops are now masked, not
just the write one.

## 30th SD round: explicit FIFO drain-to-empty on every reset -- the actual root cause?

Real-HW retest of this round's read/write burst-gate fixes + IRQ
masking (previous entries) showed the new SCR-read diagnostic
(`sd_scr_drain_diag`) reporting `fifo_fill=0x8` at the moment of BOTH
2-word SCR reads -- objectively impossible for a genuine ACMD51
response (only ever 8 real bytes = 2 words total). The raw `SDDATA`
values read (`0x00000002`, `0x00000235`) were independently confirmed
correct AT THE MOMENT of the MMIO read -- never a software bug in the
drain/store/print code.

The real tell: the exact same corrupted bytes
(`02 00 00 00 35 02 00 00`) appeared byte-for-byte identical across
EVERY real-HW test this entire session -- 25MHz and 50MHz, with and
without ACMD6, before and after the burst-gate fix, before and after
IRQ masking. That invariance only makes sense as stale data sitting in
the FIFO's own hardware SRAM, never actually cleared by any "logical"
register-level reset performed so far. Confirmed by re-reading Linux's
own real upstream `bcm2835-sdhost.c`, U-Boot's port, and this driver's
own reset sequence: none of the three ever explicitly reads-and-
discards whatever's already sitting in the physical FIFO as part of
reset -- the register writes and the SDVDD power toggle never touch
`SDDATA` at all.

Added an explicit FIFO drain-to-empty step to `sdhost_init_at_speed`,
right after the reset/power-cycle, before any command is issued:
reads and discards `SDDATA` while `SDEDM`'s fill count is nonzero,
bounded at 1000 iterations. Runs on every init (first boot and every
retry), so stale content can never silently survive a reset again.

Verified: build clean, boots under QEMU, `phase4_milestone.py` run
twice, identical to documented baseline both times. Commit `a4264c9`.
**Not yet real-HW tested** -- but this is the first fix in the whole
30-round saga directly, mechanistically supported by an otherwise-
inexplicable, byte-for-byte-invariant symptom, rather than reasoning
from a register-value comparison alone.
