# Hardware-in-Loop Testing: Real Raspberry Pi 1 Model B + SD Card

This project's default test method is QEMU (`qemu-system-arm -M
raspi1ap`), and that stays the default — see `docs/TODO.md`'s own
"Hardware-in-loop testing" section for why: everything QEMU can catch
should be caught there first, with real hardware as an *additive*
final pass, not a replacement. This document is that additive pass:
concrete, verified steps for connecting a real Pi 1 Model B and SD
card to this PC, written from this project's own source code, not
copied from a generic Raspberry Pi tutorial. Two details below
(§3.2's UART clock, §4.2's SD partition layout) are things a generic
tutorial would get wrong for THIS specific kernel — read those before
doing anything else.

**Confirmed target hardware (2026-09-04)**: a real Raspberry Pi 1
Model B, **revision 2.0, 512MB RAM** (the 26-pin-header board, GPU
firmware/BCM2835 identical to revision 1.0 — the only hardware change
between revisions is the I2C ID pins, GPIO0/1 → GPIO2/3 plus the added
P5 header, neither of which this project's UART wiring in §3 touches).
Everything below applies to it as written.

## 1. What you need

- A real Raspberry Pi 1 Model B (BCM2835, the board `raspi1ap` in
  QEMU emulates — **not** a B+, Zero, or Pi 2/3/4/5; those need a
  different boot firmware set and, for anything past Pi 1, a
  different SoC this project doesn't target). Revision 1.0 or 2.0
  both work identically for everything in this document.
- A microSD card (SDSC or SDHC both work — `sd_state_get_is_sdhc()`
  in `kernel/kernel_main.vani` handles both addressing modes). A
  small, reputable card (2-8GB) is plenty; this project's own log
  region is a bounded 1MB (see §4.2).
- An SD card reader for this PC (to write the card from here, then
  move it to the Pi).
- **A 3.3V USB-to-TTL-serial (UART) adapter.** This is how you'll see
  any output at all — this project has no HDMI/framebuffer code
  whatsoever, it is UART-console-only by design (matches
  `-nographic`/`-serial stdio` under QEMU). **Must be 3.3V logic
  level, not 5V** — see the safety warning in §3.1; a 5V adapter can
  permanently damage the Pi's GPIO.
- 3 male-to-female jumper wires (TX, RX, GND).
- A separate 5V/microUSB power supply for the Pi (the USB-serial
  adapter's own 5V line is not a reliable way to power the whole
  board — power it properly and separately).
- Optional, only if you want to exercise the real NIC/network paths:
  a USB Ethernet or Bluetooth/WiFi dongle matching what
  `DHRUVAOS_MANUAL.md` §1 already documents as write-to-spec
  (CDC-ECM, the real SMSC LAN9512 onboard port, USB Bluetooth HCI,
  Realtek RTL8188CU/RTL8192CU).

## 2. Safety notes (read before connecting anything)

- **UART voltage: 3.3V only.** The Pi 1's GPIO header is not 5V
  tolerant. Double-check your USB-serial adapter has a 3.3V (not 5V)
  I/O jumper/setting before ever connecting it to the GPIO pins.
- **Never connect the adapter's own 5V or 3.3V power pin to the Pi.**
  Power the Pi from its own separate microUSB supply; the serial
  adapter should carry TX/RX/GND only. Powering two sources into the
  same rail at once is how boards get damaged.
- **Cross TX/RX**: adapter TX → Pi RX (GPIO15), adapter RX → Pi TX
  (GPIO14), adapter GND → Pi GND. Get this backwards and you'll just
  see no output (harmless, but confusing) rather than damage anything
  — it's a receive/transmit swap, not a voltage issue.
- **SD card write-cycle awareness**: this filesystem is log-structured
  and append-only (`DHARAFS_MANUAL.md` §1) — every write goes to a
  *new* location, never in-place. A card that already has real data
  on it you care about should not be reused here without a backup;
  §4.2 below has you repartition it.
- **Power the Pi down (unplug) before ever removing/reinserting the SD
  card.** Never hot-swap it.

## 3. Wiring the UART console

### 3.1 GPIO pins

Raspberry Pi 1 Model B's 26-pin header, UART0 (PL011) pins — confirmed
directly from `gpio_uart_alt_init()`/`uart_init()` in
`kernel/kernel_main.vani`, which mux GPIO14/15 onto UART0's TX/RX:

| Pi GPIO pin | Header pin # | Function | Connect to |
|---|---|---|---|
| GPIO14 | Pin 8 | UART0 TXD (Pi transmits) | Adapter's RX |
| GPIO15 | Pin 10 | UART0 RXD (Pi receives) | Adapter's TX |
| GND | Pin 6 (or any GND pin) | Ground | Adapter's GND |

Do **not** connect the adapter's 5V or 3.3V pin to anything on the Pi.

### 3.2 The UART clock — critical, and easy to get silently wrong

`uart_init()`'s own comment in `kernel/kernel_main.vani` says it
plainly: *"115200 baud @ **assumed** 3MHz UART clock: IBRD=1,
FBRD=40."* That word "assumed" matters. The PL011's baud-rate divisor
only produces 115200 baud if the UART's reference clock genuinely *is*
3MHz — and on real Raspberry Pi hardware, the GPU firmware does not
guarantee that by default; the core clock (which UART0 derives from)
can vary for power management unless pinned. **If the real clock
differs from 3MHz, every byte this kernel sends will decode as
garbage on your terminal — not silence, garbage** — which looks like a
dead/miswired board even though the Pi is booting and running
correctly underneath.

**Fix**: your SD card's `config.txt` (§4.3) must include
`init_uart_clock=3000000` to pin the UART reference clock to exactly
what this kernel assumes. This is the single most likely reason a
first bring-up attempt would appear completely dead — check this
before suspecting wiring or the board itself.

### 3.3 Terminal settings

115200 baud, 8 data bits, no parity, 1 stop bit (8N1), no flow
control — matches `uart_init()`'s own `UART_LCRH` programming (`0x70`
= 8 bits, FIFOs enabled, no parity). Any of `screen`, `minicom`, or
`picocom` work:

```sh
# find the device first (usually /dev/ttyUSB0 or /dev/ttyACM0)
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

screen /dev/ttyUSB0 115200
# or: picocom -b 115200 /dev/ttyUSB0
# or: minicom -D /dev/ttyUSB0 -b 115200
```

## 4. Preparing the SD card

### 4.1 Get the Pi 1 boot firmware

The Pi's own GPU boot ROM needs three firmware files it loads before
ever touching Dhruva's own code — this project doesn't (and can't)
provide these, they come from the official Raspberry Pi firmware
repository: `bootcode.bin`, `start.elf`, `fixup.dat`. Use the
**original-generation** files (not the `_x`/`4` variants built for
later boards) — the ones named exactly `bootcode.bin`/`start.elf`/
`fixup.dat` with no suffix, from
`https://github.com/raspberrypi/firmware/tree/master/boot` (or
whatever source you trust for these — this project has no opinion on
firmware provenance beyond "must be the Pi 1/Zero-generation files").

### 4.2 Partition layout — critical, avoids real data corruption

**Do not simply format the whole card as one FAT32 filesystem.**
DharaFS (`dharafs_init` in `kernel/kernel_main.vani`) talks to the SD
card via raw block numbers with **zero partition-table awareness** —
confirmed directly from `sdhost_card_addr(block_num)`, which maps a
block number straight to a card address with no offset applied at
all. `dharafs_init` scans (and later writes into) blocks **1 through
2048** (a bounded ~1MB region, `kernel_main.vani`'s own comment) —
starting from the *very front* of the physical device. If a FAT32
boot partition's own filesystem metadata occupies that same physical
region, DharaFS writing there will corrupt the boot partition (and
vice versa) — silently, since neither side has any idea the other
exists.

**The fix is the same convention standard Raspberry Pi OS images
already use, which is not a coincidence** — create a real MBR
partition table with the FAT32 boot partition starting well clear of
the first 1MB. Recommended: start it at sector 16384 (8MiB) for a
comfortable safety margin beyond DharaFS's own 1MB ceiling, not the
bare minimum:

```sh
# CAUTION: this WILL ERASE the target device. Triple-check the
# device path (e.g. /dev/sdX or /dev/mmcblkX) before running anything
# here — an SD card reader can enumerate differently machine to
# machine and session to session. Run `lsblk` first and confirm size/
# mountpoints match what you expect. NEVER guess.
lsblk

# Replace /dev/sdX with your card's actual device (not a partition,
# the whole device).
sudo parted /dev/sdX --script mklabel msdos
sudo parted /dev/sdX --script mkpart primary fat32 16384s 100%
sudo mkfs.vfat -F 32 /dev/sdX1
```

This leaves sectors 0-16383 (8MiB) entirely unpartitioned — DharaFS's
own 1MB (blocks 1-2048, i.e. sectors 2-4096 at 512 bytes/sector) sits
safely inside that gap, and the FAT32 partition never touches it.

### 4.3 config.txt

Mount the new FAT32 partition and create `config.txt` at its root:

```
kernel=kernel.img
init_uart_clock=3000000
enable_uart=1
disable_splash=1
```

(`init_uart_clock` is the critical one — see §3.2. `enable_uart=1` and
`disable_splash=1` are harmless, standard hygiene; this project has no
HDMI/display code to disable.)

### 4.4 Building and copying the kernel image

```sh
cd /path/to/dhruvaos
./build.sh                                      # produces build/dhruva.elf

# Convert to a raw binary at the Pi's own real load address, 0x8000
# -- boot/rpi1/link.ld's own comment explicitly chose that address
# "so this script doesn't need to change when this eventually runs
# on the real board", i.e. this project was already built expecting
# this exact step.
arm-none-eabi-objcopy -O binary build/dhruva.elf kernel.img
```

Copy `bootcode.bin`, `start.elf`, `fixup.dat` (§4.1), `config.txt`
(§4.3), and the newly-built `kernel.img` (§4.4) to the FAT32
partition's root. Unmount cleanly, remove the card, insert it in the
Pi (powered off).

## 5. First boot

Power on the Pi with the serial terminal (§3.3) already connected and
listening. You should see the exact same boot self-test sequence this
project's own QEMU runs already produce — `Dhruva Phase 2:
fixed-priority scheduling + priority ceiling`, the SD/DharaFS
self-tests, the full crypto suite, and eventually `PASS` followed by
live multitasking output (`HIGH:`/`MEDIUM:`/`LOW:`/`idle` etc.).

**If you see nothing at all**: check §3.2 (`init_uart_clock`) first,
then wiring (§3.1 — TX/RX swapped is the next most common cause),
then that `kernel.img` and `config.txt` are actually present at the
FAT32 partition's root (not in a subdirectory).

**If you see garbage/mojibake instead of text**: this is the §3.2
UART clock issue almost certainly — the board is booting and sending
real bytes, just at a rate your terminal isn't decoding correctly at
115200 relative to what the Pi is actually outputting.

## 6. What to specifically verify (the actual point of hardware-in-loop)

Everything QEMU already covers doesn't need re-verifying here — that
would defeat the point of a fast local loop. Focus on what `docs/
TODO.md`'s own "Hardware-in-loop testing" section names as QEMU's
real fidelity gaps:

- **USB mass storage real-device timing/quirks** — the driver is
  QEMU-verified against `usb-storage`; real flash drives have real
  quirks QEMU's model doesn't reproduce.
- **The real SMSC LAN9512** (this board's actual onboard wired Ethernet
  chip) — written to spec (`DHRUVAOS_MANUAL.md` §1), never live-tested;
  no QEMU model of this chip exists at all.
- **USB Bluetooth HCI transport** — same situation: written to spec,
  the QEMU device that once modeled this (`usb-bt-dongle`) was removed
  from modern QEMU years ago.
- **USB WiFi (RTL8188CU/RTL8192CU) enumeration + vendor register I/O**
  — stops deliberately short of firmware upload (`DHRUVAOS_MANUAL.md`
  §1's own explanation); real hardware is the only way to confirm even
  the enumeration/register-read layer behaves as expected against a
  genuine chip.
- **The real hardware watchdog** (`watchdog_arm`/`_init`/`_kick`,
  `DHRUVAOS_MANUAL.md` §1) — confirmed that QEMU's `raspi1ap` model
  doesn't honor `PM_WDOG`'s timeout at all (an armed reset fires
  immediately regardless of the configured value). Real silicon may
  honor it correctly — this is the one item on this list actually
  worth *wiring in and testing* here, not just observing, since it's
  been deliberately left unwired specifically because it was untestable
  under QEMU (see `TODO.md`'s "Incident/flight-recorder capture on
  watchdog reset" entry for the follow-on feature this would unblock).
- **Memory-ordering barriers and governor/wattage behavior** — named in
  `docs/TODO.md`'s own hardware-in-loop section as real-hardware-only
  concerns; that section doesn't elaborate further (a referenced
  "Feature Ledger" document with more detail no longer exists in this
  repo), so real-hardware testing is genuinely the first place these
  get characterized at all, not just re-confirmed.
- **The MMU's XN (execute-never) enforcement** — `boot/mmu_init.S`'s
  own header comment documents that write-protection (W^X's other
  half) was live-verified under QEMU, but XN enforcement specifically
  could **not** be confirmed working under this project's QEMU
  version despite real, repeated testing — flagged there as a genuine
  open question real hardware could settle either way.

## 7. See also

- `docs/DHRUVAOS_MANUAL.md` — the system this hardware runs.
- `docs/DHARAFS_MANUAL.md` — the filesystem whose SD-card block layout
  §4.2 above is about.
- `docs/TODO.md` — the "Hardware-in-loop testing" section (philosophy)
  and every "written to spec, not live-verified" item this document's
  §6 checklist draws from.
