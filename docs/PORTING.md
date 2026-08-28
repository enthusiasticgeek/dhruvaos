# Porting notes: Raspberry Pi 4 / Pi 5, USB 3.x, non-SD storage

Dhruva currently targets exactly one platform: BCM2835 (Raspberry Pi 1
Model B), tested exclusively via QEMU's `raspi1ap` machine model. This
note captures what changes for a Pi 4 / Pi 5 (and Compute Module)
port, so the scope is written down before any of it is built.

## Storage: current coupling, and what's actually portable

`fs_init`/`fs_append_raw`/`fs_find_latest_block_raw`/`fs_compact`/
`fs_read_raw` (kernel/kernel_main.vani) call `sdhost_read_block` /
`sdhost_write_block` directly. Those two functions are BCM2835
SDHOST-specific — register layout, command sequencing, FIFO drain/fill
all live in `sdhost_cmd`/`sdhost_init` and friends, none of which
exist on later SoCs:

- **Pi 4** (BCM2711): SD/eMMC goes through the EMMC2 controller, a
  different peripheral entirely.
- **Pi 5** (BCM2712): storage is mediated through the RP1 southbridge,
  different again.
- **Compute Module 4/5**: on-module eMMC, or an external NVMe drive
  over PCIe — neither is SDHOST.

So *some* new low-level block driver is required for any of these
targets, regardless of the storage media. The reassuring part: eMMC,
NVMe, and microSD all already present a block interface via their own
on-device controller/FTL. None of Dhruva's realistic targets are raw
parallel NAND, so the filesystem itself does not need to grow
wear-leveling or bad-block management — it only needs to stop knowing
its block driver is SDHOST specifically.

**Plan**: insert a block-device abstraction between the FS layer and
the driver — a small struct of function pointers (vani supports
fn-typed parameters, used elsewhere in this project already):
`read_block(dev, lba, buf) -> i64`, `write_block(dev, lba, buf) -> i64`,
`block_count(dev) -> i64`. `sdhost_read_block`/`sdhost_write_block`
become the first (only, for now) backend registered behind it; the ~5
FS call sites switch from calling SDHOST directly to calling through
the abstraction. Fully buildable and testable on the existing Pi
1/QEMU target today, with zero new hardware — the whole existing
self-test + `phase4_milestone.py` + `power_yank.py` battery already
exercises every code path this touches.

Deliberately **not** doing this speculatively ahead of time: the right
shape of the abstraction is easiest to get right once there's a real
second backend (EMMC2, or an NVMe driver) to shape it against, not
from guessing alone.

## USB: connector type is irrelevant; host controller silicon is everything

Type-A vs micro-USB vs USB-C is a physical/electrical concern only.
What actually determines the driver is the host controller:

- **Pi 1** (current target): DWC2, a USB 2.0 OTG controller — this is
  what `hal`'s DWC2 driver and the enumeration/hub code in
  kernel_main.vani target today.
- **Pi 4**: VL805, an XHCI (USB 3.0) controller behind PCIe.
- **Pi 5**: USB is mediated through RP1, also XHCI-class but a
  different integration again.

XHCI is a substantially larger, more complex specification than DWC2
(ring-based command/event/transfer queues, larger context structures,
different enumeration state machine) — this is a new driver written
from scratch, not an extension of the DWC2 code, and the existing
mass-storage/network device-class handling built on top of DWC2's
enumeration would need to be re-plumbed onto it too.

## Bigger picture: this is a new-SoC port, not an incremental feature

Storage and USB are the two pieces directly relevant to the question
that prompted this doc, but a real Pi 4/5 port touches far more:
BCM2711/2712 use ARM Cortex-A72/A76 (ARMv8-A) rather than this
project's ARM1176JZF-S (ARMv6) — different exception model, different
MMU, likely EL2/EL1 handling that doesn't exist in `boot/rpi1/boot.S`
today — plus a GIC-based interrupt controller in place of BCM2835's
simple interrupt controller (`timer_ic_init` and friends), and a
different timer peripheral. None of that is in scope for this note;
it's flagged here so the storage/USB estimates below aren't read as
"the whole port."

QEMU's `raspi1ap` machine model is Pi-1-only — there is no equivalent
QEMU target for Pi 4/5 at the fidelity this project currently relies
on for its whole verification discipline (self-tests, `phase4_
milestone.py`, `heap_stress.py`, `power_yank.py`, all run headless
under QEMU every round). A Pi 4/5 port loses that safety net and
needs real-hardware bring-up, which is a slower iteration loop than
anything this project has done so far.

See `docs/TODO.md` for the backlog entries and effort estimates.
