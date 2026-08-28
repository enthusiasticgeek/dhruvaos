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

## Test infra debt (flagged by the Dhruva Feature Ledger, not yet fixed)

- **Stale "stdin delivery unconfirmed" status headers** — `[S, part
  of a round]`
  `test/shell_interactive_check.py` and `test/shell_interactive_check.sh`
  both carry 2026-08-26 header comments claiming interactive-shell
  stdin delivery "could not be confirmed to actually exercise the
  shell in this sandbox." That's now stale: `test/phase4_milestone.py`'s
  `subprocess.Popen(..., stdin=subprocess.PIPE)` + write+flush method
  has reliably driven the shell every round since (write/cat/eval,
  then ping/ifconfig/tcpecho/udpecho on top). Fix: update both files'
  status headers to point at `phase4_milestone.py` as the confirmed
  working method (or retire the two stale files outright in favor of
  it), so a future session doesn't waste time re-litigating a solved
  problem.

- **Concurrency-hazard regression test** — `[S-M, ~1 round]`
  `task_e`'s own comment (round 27, extended in rounds 29/30) documents
  a real, still-unfixed hazard: netif has one shared FIFO queue with no
  per-protocol demux, and `task_e`'s periodic `dhcp_client_poll` plus
  the shell's live network commands (`ping`, `tcpecho`, `udpecho`) are
  genuinely concurrent consumers of it — any one can dequeue a frame
  another was waiting for. This has only ever been documented, never
  exercised by a test that actually reproduces the race (e.g., firing
  two live commands back-to-back with minimal settle time and checking
  for a dropped-frame retry rather than a hang or wrong answer). Not a
  fix for the hazard itself (that's a separate, larger per-protocol
  receive-path redesign) — just closing the gap between "documented"
  and "verified to behave safely under the documented conditions."

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
