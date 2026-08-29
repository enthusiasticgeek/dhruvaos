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

### Correction (round 40, 2026-08-29): a Pi 4 QEMU target *does* exist

An earlier version of this note claimed there is no QEMU target for
Pi 4/5 at all. That was checked properly for the first time in round
40 and is **wrong for Pi 4** — it was an assumption carried over from
`raspi1ap` being Pi-1-only, never actually verified against QEMU's
full machine list:

- `qemu-system-arm -M help` (the 32-bit emulator this whole project
  has used exclusively) indeed lists no Pi 4/5 model.
- `qemu-system-aarch64 -M help` (the **64-bit** emulator, a separate
  binary, already installed on this machine) lists `raspi4b`
  (revision 1.5) alongside `raspi0`/`raspi1ap`/`raspi2b`/`raspi3ap`/
  `raspi3b`. No `raspi5` yet in this QEMU version — Pi 5 still has no
  emulation target.
- Verified live, not just from `-M help` output: a minimal bare-metal
  AArch64 stub (raw `_start`, no exception vectors, no MMU) built with
  the already-installed `aarch64-linux-gnu-gcc` (`-mgeneral-regs-only
  -nostdlib`, linked at `0x80000` like the standard Linux arm64 kernel
  load address) boots correctly under
  `qemu-system-aarch64 -M raspi4b -nographic -kernel <elf>` and
  successfully polls/writes a PL011 UART at **`0xFE201000`**
  (BCM2711's low-peripheral-mode base `0xFE000000` + the same
  `0x201000` UART0 offset every earlier BCM2835/2837 SoC in this
  project's history has used). QEMU accepts the ELF directly via
  `-kernel`, the same convention `dhruva.elf` already relies on for
  Pi 1.
- Also checked: QEMU's `raspi4b` starts execution at **EL3** (Secure
  Monitor), confirmed via a live `mrs x0, CurrentEL` read printed over
  the UART. Real Pi 4 firmware normally does EL3→EL2→EL1 handoff via
  ARM Trusted Firmware before jumping to an OS; QEMU's raw `-kernel`
  boot skips that firmware entirely and drops straight into EL3, so a
  real port's boot code must do that EL3→EL1 (or EL3→EL2→EL1) drop
  itself — `SCR_EL3`/`HCR_EL2`/`SPSR_EL3` setup + `eret`, nothing like
  ARM1176's single flat mode-switch model in `boot/rpi1/boot.S` today.

**Toolchain is also not a blocker**, contrary to what might be
assumed from `vani-compiler`'s history of only ever targeting 32-bit
ARM/x86 for this project: `vani-compiler`'s `--backend=c` /
`--backend=llvm` pipelines already contain generic bare-metal
cross-compilation logic keyed off the `--target=<triple>` string
(`is_bare_metal_triple`/`cross_cc_for_triple` in `src/main.rs`), with
explicit `aarch64` handling already present (QEMU-dispatch, NEON
vectorize-width hints in `backend_llvm.rs`). A bare-metal triple like
`aarch64-none-elf` would make the compiler look for a
`aarch64-none-elf-gcc` cross-compiler, which is **not** installed —
but the `CROSS_CC` environment variable override (already supported)
can point it at the `aarch64-linux-gnu-gcc` toolchain that **is**
installed on this machine; that toolchain works fine for freestanding
bare-metal AArch64 output with `-nostdlib -ffreestanding`, exactly as
used for the spike above. No changes to `vani-compiler` itself appear
to be needed to start emitting AArch64 object code.

**What this changes**: the "no safety net, real-hardware-only"
framing below no longer applies to Pi 4 (it still applies to Pi 5,
which has no QEMU model at all). A Pi 4 port can keep this project's
entire existing verification discipline — self-tests, `phase4_
milestone.py`-style smoke tests, `heap_stress.py`, `power_yank.py` —
run headless under `qemu-system-aarch64 -M raspi4b`, the same as
every round of this project has done under `qemu-system-arm -M
raspi1ap`. This makes a real Pi 4 port a dramatically more tractable,
iterable effort than previously scoped; Pi 5 remains real-hardware-
only until QEMU grows a BCM2712/RP1 model.

### Round 43: real EL3→EL1 boot skeleton, checked in

Round 40's spike was research/validation only, deliberately left in
`/tmp`. Round 43 replaced it with real, permanent code:
`boot/rpi4/boot.S` (EL3→EL1 privilege drop — `HCR_EL2.RW`, `SCR_EL3`
(NS/RES1/HCE/RW), `SPSR_EL3` targeting EL1h with DAIF masked,
`ELR_EL3` + `eret`), `boot/rpi4/vectors.S` (a real 16-entry AArch64
exception vector table, `VBAR_EL1`-installed, each entry a diagnostic
handler reporting `ESR_EL1`/`ELR_EL1`/`FAR_EL1` over the PL011 UART
before halting — same "never silently loop forever on a fault"
convention round 38 established for the Pi 1 MMU work), and
`boot/rpi4/link.ld`. Built via the new `build_rpi4.sh` (a deliberately
separate script from `build.sh` — different instruction set, different
cross-compiler, no vani-compiled kernel code yet), verified via the
new `test/rpi4_boot_smoke.py`.

Both halves live-verified, not just asserted: the EL3→EL1 drop prints
`CurrentEL=1` (read AFTER the drop, at EL1 — the actual regression
check `rpi4_boot_smoke.py` runs), and the vector table was proven to
genuinely dispatch by deliberately executing a `udf` instruction and
confirming the correct vector (4 — Current EL, SPx, Synchronous) fires
with an architecturally-correct `ESR_EL1` value (`0x02000000`: EC=0
"Unknown reason" — the real classification for an undefined encoding,
not a separate "undefined instruction" code as might be assumed;
IL=1, correctly reflecting that AArch64 instructions are always
32 bits). That same fault-injection test caught a real bug during
development: `uart_puts_rpi4_el` made two nested calls without saving
its own return address, silently corrupting it and jumping to garbage
on return — fixed before this round closed.

v1 scope is deliberately narrow: hand-written assembly only, no vani-
compiled kernel code yet (a real `kernel_main.vani`-style AArch64 port
needs its own round once this boot layer exists), no MMU, no GIC, no
timer. Real work still ahead, now precisely scoped rather than
assumed: ARMv8-A MMU (radically different from ARMv6's short-
descriptor sections — TTBR0_EL1/TCR_EL1, 4-level or folded page
tables), GICv2 or GICv3 interrupt controller in place of BCM2835's
simple IC, BCM2711 timer peripheral (still the same generic ARM timer
core the existing scheduler code assumes, but at new addresses), then
only after all of that: EMMC2 (storage) and XHCI (USB) drivers from
scratch, both already flagged above as substantially larger than
their Pi 1 SDHOST/DWC2 counterparts, and — the largest remaining
unknown — porting `kernel_main.vani` itself (or a fresh AArch64-native
rewrite of its boot-facing pieces) to this target at all.

QEMU's `raspi1ap` machine model remains Pi-1-only; there is still no
QEMU target for Pi 5.

See `docs/TODO.md` for the backlog entries and effort estimates.
