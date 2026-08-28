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
