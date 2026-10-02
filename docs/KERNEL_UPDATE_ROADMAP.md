# Remote kernel update over UART: scoping (no code written yet)

Prompted by the UART corruption investigation's own real-HW tooling work (task #306/#307): the user asked
whether debugging AND deployment could both happen over UART once a board is up, and specifically whether a
kernel update over UART is possible. This doc scopes that as task #308, phased, with an explicit fallback-
slot design — nothing in this doc has been implemented.

## What's real today vs. what's missing

**Already proven, reusable as-is:**
- Raw SD block I/O at an arbitrary block number, with no filesystem awareness in the way:
  `dharafs_block_read_raw`/`_write_raw` (`kernel_main.vani`) dispatch straight to `sdhost_read_block`/
  `_write_block` — no range check, no partition-table awareness. This project has spent dozens of real-HW
  rounds making exactly this primitive reliable (the whole SD-wedge/burst-write saga). The hard reliability
  work this feature would otherwise need is already done.
- A real hardware watchdog with a software-triggerable full reset: `watchdog_arm(timeout_ticks)` writes the
  BCM2835 PM_WDOG/PM_RSTC registers directly. Arming it with a short timeout and not kicking it is already a
  working "reboot myself" primitive.
- A proven chunked binary-transfer-over-UART protocol: `wifikey chunk <hex>`/`wifikey commit` (task #164),
  already moved a real ~16KB firmware blob over a live serial line in ~337 commands, real-HW confirmed.
- SHA-256 (`sha256_init`/`_update`/`_finalize`) for verifying a staged blob before trusting it.
- DharaFS itself for ordinary file storage (staging the new image, keeping a backup copy) — this is where
  the *bulk* bytes of both images belong, not in more raw reserved blocks.

**Missing, and this is the actual scope of the feature:**
- Nothing in this codebase understands the FAT32 boot partition's own structure (boot sector, FAT, root
  directory) — DharaFS and the boot partition are two completely separate, mutually-unaware regions on the
  card by design (see `docs/HARDWARE_IN_LOOP.md` §4.2). To overwrite `kernel.img` in place, something needs
  to parse the FAT32 structures *once* to find which physical blocks currently hold that file's bytes.
- No fallback/rollback mechanism exists. This is the part that actually matters for safety.

## The hard constraint: there is no second boot stage

A real A/B update system (U-Boot's own `bootcount`/`bootlimit`, ChromeOS's kernel A/B slots) works because a
small, essentially-frozen bootloader stage runs *before* the OS and decides which slot to boot, independent
of whatever the OS itself does. DhruvaOS has no equivalent: `bootcode.bin`/`start.elf` are closed-source
Broadcom firmware that reads `config.txt`'s static `kernel=` line once and loads exactly that file — no
concept of trying a new image and falling back.

This means any boot-time decision about "did the last update actually work" has to live *inside*
`kernel.img` itself — specifically in a tiny, very-early, deliberately almost-never-changed prologue that
runs before anything that could plausibly crash. If a new image is broken badly enough that it can't even
reach that prologue (corrupted entry point, hung before it's reached), nothing here saves it — the watchdog
just reboots into the same broken image, forever, until someone physically re-flashes the card. **This
residual risk is real and this design does not eliminate it** — it meaningfully reduces the common case
(an update that boots far enough to run real code, then fails or hangs) without claiming to solve the
pathological case (an update that can't execute at all).

## Design

**New reserved raw-block region**: one status block at **block 4200** (clear of DharaFS's own 1-2048 and the
crypto-metadata region at 4000-4128, same unpartitioned gap before the FAT32 partition starts at block
16384) — holds: `pending_flag` (an update was just written, not yet confirmed healthy), `boot_attempt_count`,
and a fixed marker/version so the self-check prologue can tell a freshly-formatted card from "a real
in-progress update." Deliberately a raw block, not a DharaFS file — the self-check prologue that reads it
must not depend on DharaFS's own init/traversal having already run correctly.

**Bulk images live in ordinary DharaFS files**, reusing existing, proven infrastructure — no new raw-block
convention for anything that's actually kilobytes in size:
- `/update/kernel.new` — staged incoming image, written via a new `kernelupdate chunk <hex>`/`commit` shell
  command pair, same shape as `wifikey chunk`/`commit`. Verified (size + SHA-256) before anything below runs.
- `/update/kernel.bak` — a copy of the *currently live* kernel.img bytes, captured right before the first
  write to the boot partition. This is the recovery source.

**Size constraint for v1**: the new image must fit within the FAT32 directory entry's already-allocated
cluster chain for `kernel.img` — i.e., new size ≤ currently-allocated size. No FAT table writes, no directory
entry changes, no cluster allocation — the overwrite is a pure "replace these N already-allocated blocks'
contents" operation, which is exactly what the proven raw block-write primitive already does. Flashing the
card with `kernel.img` padded to a fixed, generous size from the start (e.g. 2MB) avoids ever hitting this
ceiling in practice. Rejecting an oversized update cleanly (before touching anything) is a hard requirement,
not a nice-to-have.

## Phased plan

- **Phase 0 — FAT32 locator (read-only).** Parse the boot sector + FAT + root directory once to find
  `kernel.img`'s starting cluster and the block range its content occupies. Verify by reading those blocks
  back and comparing their SHA-256 against a normally-mounted copy of the same file — proves the locator is
  correct without writing anything. Zero risk: this phase never writes to the boot partition.
- **Phase 1 — Staging over UART.** `kernelupdate chunk`/`commit`, landing the new image in `/update/
  kernel.new` via DharaFS, verified by size + SHA-256 before Phase 2 ever runs. Zero risk to the boot
  partition — purely a DharaFS write, the same class of operation this project already trusts.
- **Phase 2 — Backup capture.** Before any write to the boot partition, copy the *currently live*
  `kernel.img` bytes (via the Phase 0 locator) into `/update/kernel.bak`, and verify its checksum matches
  what's about to be overwritten. Still read-only with respect to the boot partition.
- **Phase 3 — The actual overwrite.** Enforce the size ceiling, then write the staged image's blocks over
  the live `kernel.img`'s already-located blocks via the existing raw block-write primitive. First real-HW
  test of this phase should overwrite `kernel.img` with a byte-identical copy of itself and confirm the
  board still boots normally afterward — proving the write path before ever trying genuinely different
  content.
- **Phase 4 — Rollback mechanism.** The block-4200 status flag/counter; a tiny, frozen early-boot prologue
  (present in every build, old and new) that checks it; an explicit `kernelupdate confirm` shell command (or
  automatic trigger once boot self-tests all pass) that clears the pending flag; and the actual rollback
  path — if the flag is still pending after N `watchdog_arm`-forced reboots, restore `/update/kernel.bak`'s
  bytes over the live blocks and force one more reboot into the restored image.
- **Phase 5 — Real-HW fault-injection drill.** Deliberately stage a broken image (e.g. one that hangs
  immediately after the prologue, or fails the boot self-tests) and confirm the rollback mechanism actually
  recovers without physical intervention — the only way to know Phase 4 really works, same discipline as
  this project's own task #279/#280 fault-injection work for the scheduler.

## Open questions for whoever picks this up

- Exact format of the block-4200 status word — needs real values once Phase 4 is designed in detail, not
  guessed here.
- Whether `config.txt` itself ever needs updating by this mechanism (currently out of scope — v1 only
  touches `kernel.img`'s own bytes).
- WiFi/BLE as the transport instead of UART is a separate question entirely, gated on those transports
  being proven reliable first (WiFi TX/RX is still task #197, in-progress; BLE is earlier-stage) — not
  blocking this roadmap, but not assumed either.
