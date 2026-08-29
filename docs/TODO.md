# Dhruva OS — open backlog

Effort buckets are relative to this project's own established
"round" cadence (see git log / project memory — one round is
typically one focused, fully-verified unit of work: build, full
self-test + `phase4_milestone.py` battery, `heap_stress.py`/
`power_yank.py`, commit). S/M/L/XL below is sized against that unit,
not calendar time.

## Storage & USB portability (Pi 4 / Pi 5 / Compute Module)

See `docs/PORTING.md` for the full writeup this backlog references.

- **Block-device abstraction for the FS layer** — `[S, ~1 round]`
  Replace the ~5 direct `sdhost_read_block`/`sdhost_write_block` call
  sites in `fs_init`/`fs_append_raw`/`fs_find_latest_block_raw`/
  `fs_compact`/`fs_read_raw` with calls through a small function-
  pointer device interface, SDHOST becoming the first backend behind
  it. No new hardware needed to build or verify — fully covered by
  the existing self-test + `phase4_milestone.py` + `power_yank.py`
  battery on the current Pi 1/QEMU target. Low risk: single backend,
  same behavior, just indirected.
  Blocks: any future non-SDHOST storage backend (EMMC2, NVMe, a
  USB-mass-storage-backed block device).

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

- **USB mass storage class driver** — `[L, ~4-6 rounds — in progress,
  round 33 landed the foundation]`
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
  - Remaining: a minimal SCSI command subset beyond `TEST UNIT READY`
    (`INQUIRY`, `READ CAPACITY`, `READ(10)`, `WRITE(10)` — the last two
    need a data-stage transfer moving a full 512-byte sector, out of
    this round's scope since `TEST UNIT READY` has no data stage at
    all), then FS integration.
  Natural integration point once built: the block-device abstraction
  above — a USB mass-storage device becomes a third backend behind the
  same interface as SDHOST/EMMC2, not a special case.
  Depends on: block-device abstraction (above), for the FS-integration
  half specifically.

- **TCP retransmission + simultaneous open** — `[M-L, ~3-4 rounds]`
  Today's TCP is "a real, useful, correctly-sequenced happy-path
  connection lifecycle, not a spec-complete implementation" (the
  code's own words) — no retransmission timers, no simultaneous-open/
  simultaneous-close, and the advertised window is never consulted.
  Retransmission needs an RTO mechanism that fits this project's
  poll-don't-block design (comparing `scheduler_get_tick_count()`
  deltas against a per-segment retry deadline, not a real async
  timer) plus per-segment retry state. Fully QEMU-testable: packet
  loss can be synthesized directly in a self-test (deliberately not
  delivering a segment `tcp_conn_poll` would otherwise see, then
  checking recovery) — no real network loss scenario or hardware
  needed. Simultaneous-open/close is a smaller, more contained
  addition to the existing state machine once retransmission's own
  timing plumbing exists.

- **FS directory hierarchy + multi-block files + journaling
  hardening** — `[L, ~4-5 rounds]`
  Today's FS is "flat, append-only, checksummed log" — paths are
  opaque strings (`ls` does prefix filtering, not real directory
  listing), and every record is capped at one 512-byte block (464-byte
  payload). Real hierarchy needs path-segment parsing and directory
  metadata; multi-block files need a block-chaining scheme (a
  "next block" pointer per record) so a payload can span more than one
  block. The existing checksum-verified crash recovery and
  compaction/GC are already a basic journal — "hardening" here means
  extending `power_yank.py`'s own crash-consistency sweep to the new
  multi-block case specifically, since a torn write spanning multiple
  chained blocks is a genuinely new crash-consistency risk class the
  current single-block-per-record design never has to handle. Fully
  QEMU-testable — `power_yank.py`'s existing tear-point-sweep
  methodology extends directly, no hardware needed.

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

## Not yet scoped (flagged in `docs/PORTING.md`, no estimate yet)

- ARMv8-A (Cortex-A72/A76) boot path — `boot/rpi1/boot.S` and
  `context_switch.S` are ARMv6/ARM1176JZF-S-specific (exception
  model, MMU, no EL2/EL1 handling today).
- GIC-based interrupt controller (replaces BCM2835's simple
  interrupt controller — `timer_ic_init` and everything built on it).
- Pi 4/5 timer peripheral differences.

These are prerequisites for a real Pi 4/5 boot, independent of the
storage/USB items above — full scoping deferred until a Pi 4/5 port
is actually started.
