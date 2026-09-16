# Raspberry Pi 1 Model B: DhruvaOS Boot Sequence

Real, current boot path for the Pi 1B target (BCM2835, ARM1176JZF-S,
ARMv6), from cold power-on through `kernel_main` reaching its idle
loop. Register names/values and the checkpoint numbering below match
`boot/rpi1/boot.S`, `kernel/kernel_main.vani`'s SD driver
(`sdhost_init`/`sdhost_read_block`/`sdhost_write_block`), and the
`BOOT DIAG`/`SD DIAG` UART instrumentation added during the 2026-09-15
real-hardware timing investigation (see project memory
`project_dhruva_pi1b_sd_reliability_investigation_2026_09_15`).

## Why this only covers SD, not USB/NVMe/eMMC/NAND as *boot* media

The BCM2835's mask ROM (baked into silicon, not updatable) hard-codes
exactly one boot source: the SD card, read via the GPU's own low-level
SD driver before the ARM core is ever released. There is no OTP
bootloader/EEPROM boot-mode selector on this SoC — that capability was
added on later Raspberry Pi boards (3B+ onward), not this one. So for
Pi 1B specifically:

- **NVMe**: not applicable at all — BCM2835 has no PCIe controller,
  full stop.
- **NAND flash**: not applicable — there is no dedicated NAND
  controller on this SoC; the only non-volatile storage path is the
  external SD card via SDHOST.
- **eMMC**: same silicon, same SDHOST controller, same driver code
  path as SD (see `is_mmc` fork below, task #186) — not a boot-media
  option on the ORIGINAL Pi 1B specifically (no eMMC is wired to this
  board), but relevant on eMMC-equipped siblings (e.g. Compute
  Module) sharing this same SoC family.
- **USB mass storage**: DhruvaOS has a working USB MSD driver
  (`usb_msd_read10`/`usb_msd_write10`, rounds 33-35) but it is a
  **runtime** block-device backend only — the Pi 1B mask ROM has no
  USB-boot capability whatsoever, so this path is never part of the
  actual boot sequence on this board.

## ASCII diagram: power-on to idle

```text
================================================================
 STAGE 0 -- SoC mask ROM (fixed silicon, GPU side, undocumented
            beyond behavior; ARM core still held in reset)
================================================================

  [ power applied ]
         |
         v
  +-------------------------+
  | BCM2835 boot ROM        |   ARM core: held in RESET the whole
  | reads SD card's own     |   time -- everything in this stage
  | first-stage loader      |   runs on the VideoCore/GPU side only.
  +-------------------------+
         |
         v
  +-------------------------+
  | bootcode.bin loaded     |   Must be the FAT32 partition's
  | from FAT32 partition,   |   FIRST partition-table entry --
  | executed on VideoCore   |   only entry the ROM ever scans.
  +-------------------------+
         |
         v
  +-------------------------+
  | bootcode.bin loads      |   start.elf reads config.txt,
  | start.elf + fixup.dat   |   sets up SDRAM timing/clocks,
  +-------------------------+   GPU memory split, etc.
         |
         v
  +-------------------------------------------------+
  | start.elf reads config.txt (this project's own: |
  |   kernel=kernel.img                              |
  |   init_uart_clock=3000000                        |
  |   enable_uart=1                                  |
  |   disable_splash=1                                |
  |   uart_2ndstage=1  <-- GPU's own diagnostic log   |
  | )                                                 |
  +-------------------------------------------------+
         |
         v
  +-------------------------+   GPU-side MESS: log lines appear on
  | start.elf reads         |   UART starting here IF                |
  | kernel.img from the     |   uart_2ndstage=1 -- e.g.:
  | FAT32 partition, loads  |     MESS:00:00:00.xxx: Raspberry Pi
  | it flat at 0x00008000   |            Bootcode
  +-------------------------+     ...
         |                        MESS:00:00:02.68: arm_loader:
         v                            Starting ARM with 448MB
  +-------------------------+
  | GPU releases ARM core   |   <-- ARM starts fetching at 0x8000.
  | reset; ARM begins       |       This is timestamp ~2.7s on the
  | executing at 0x8000     |       GPU's OWN free-running clock.
  +-------------------------+

================================================================
 STAGE 1 -- boot_entry (boot/rpi1/boot.S), ARM core, no UART yet
            (this is the file/region the 2026-09-15 investigation
            is actively instrumenting -- see "Known gaps" below)
================================================================

  0x8000: .vectors (16 words, copied down to 0x0 below --
          ARMv6 has no VBAR, hardware always reads exceptions
          from address 0; real flat kernel.img loading means
          they can't be linked AT 0x0 directly, only copied there
          at runtime)
         |
         v
  boot_entry:                              [[ SNAP_TIMER 0 ]]
         |  force SVC mode, mask IRQ+FIQ unconditionally
         |  (real firmware handoff state isn't fully trusted --
         |   found necessary 2026-09-13, matching Linux's own
         |   safe_svcmode_maskall)
         v
   copy .vectors (0x8000) -> address 0x0 (16 words / 64 bytes)
         |
         v
   GPIO16 (ACT LED) configured as output
         |
         v
   SCTLR: clear M (MMU) / A (align-fault) / C (dcache) / I (icache)
   invalidate I+D cache, unified TLB, branch-predictor array
   data sync barrier + prefetch-buffer flush
         |
         v                                  [[ SNAP_TIMER 1 ]]
   >>> CHECKPOINT 1 <<<  (1 LED blink)
   cache/MMU/TLB/branch-predictor forced to a known-clean state
         |
         v
   sp (SVC) = _stack_top
   switch to IRQ mode, sp_irq = _irq_stack_top
         |
         v                                  [[ SNAP_TIMER 2 ]]
   >>> CHECKPOINT 2 <<<  (2 LED blinks)
   IRQ mode entered, its own banked stack set
         |
         v
   switch to Abort mode, sp_abt = _abort_stack_top
         |
         v                                  [[ SNAP_TIMER 3 ]]
   >>> CHECKPOINT 3 <<<  (3 LED blinks)
   Abort mode entered, its own banked stack set
         |
         v
   switch back to SVC mode, sp restored
         |
         v                                  [[ SNAP_TIMER 4 ]]
   >>> CHECKPOINT 4 <<<  (4 LED blinks)
   back in SVC mode, mode-switching/stack setup fully done
         |
         v
   clear_bss: zero __bss_start..__bss_end
   (QEMU's ELF loader does this for free; real flat kernel.img
    loading does NOT -- must be done here, in software)
         |
         v                                  [[ SNAP_TIMER 5 ]]
   >>> CHECKPOINT 5 <<<  (5 LED blinks)
   .bss cleared
         |
         v
   bl mmu_init   (builds the page table INTO .bss -- must run
                  after the clear above, or the zero-fill would
                  wipe the descriptors mmu_init just wrote)
         |
         v                                  [[ SNAP_TIMER 6 ]]
   >>> CHECKPOINT 6 <<<  (6 LED blinks)
   mmu_init returned, page tables live
         |
         v
   bl kernel_main   ------------------------------------------>>

   (hang: BLINK_N 7, repeating -- crash sentinel if kernel_main
    ever somehow returns; it never should, it runs forever)

================================================================
 STAGE 2 -- kernel_main (kernel/kernel_main.vani), UART now live
================================================================

   uart_init()
         |
         v
   uart_puts("Dhruva Phase 2: ...")
   uart_puts("BOOT DIAG: kernel_main entry, TIMER_CLO=0x...")
   uart_puts(7x "BOOT DIAG: checkpoint N ..., TIMER_CLO=0x...")
         |     (reads boot_checkpoint_0..6 back out of the .data
         |      words boot.S's SNAP_TIMER wrote -- .data, NOT
         |      .bss, so checkpoint 5's clear can't wipe them)
         v
   scratch buffers allocated (FS/shell/eval/uart_put_i64)
         |
         v
  +----------------------------------------------------------+
  | sdhost_init()                          "SD DIAG: ..." x N |
  +----------------------------------------------------------+
         |
         v
   gpio_sdhost_alt_init()  -- mux GPIO48-53 onto SDHOST alt function
         |
   mem_barrier()  -- cross-peripheral write ordering (GPIO -> SDHOST)
         |
         v
   SDVDD: power off, delay, power on, delay
   (known-clean starting FSM state, not whatever reset left behind)
         |
         v
   SDCDIV = 0x148 (ident-speed clock), SDTOUT = 0xF00000
   SDHBCT = 0, SDHBLC = 0, SDHCFG = 0 (interrupts stay disabled --
   this driver polls SDCMD/SDHSTS directly)
         |
         v
   CMD0  (GO_IDLE_STATE)  -----> timeout = hard failure, abort init
         |
         v
   CMD8  (SEND_IF_COND, 0x1AA)
         |
    times out?  ---- yes ---->  is_mmc = 1  (real eMMC/MMC path,
         |                       untestable under QEMU: no MMC
         no                      card model exists to attach)
         v
   is_mmc == 0 (SD path):
     loop: CMD55 (APP_CMD) + CMD41 (SD_SEND_OP_COND, HCS set)
           until OCR busy bit (bit 31) sets, capped iterations
   is_mmc == 1 (MMC/eMMC path):
     loop: CMD1 (SEND_OP_COND) until busy bit sets, capped
         |
         v
   CMD2  (ALL_SEND_CID, long response)
   CMD3  (SD: SEND_RELATIVE_ADDR, card publishes RCA)
         (MMC: SET_RELATIVE_ADDR, host assigns RCA=1, U-Boot-style)
         |
         v
   CMD9  (SEND_CSD, addressed by RCA)
   CMD7  (SELECT_CARD, addressed by RCA -- card enters transfer state)
         |
         v
   sd_state_set(rca, is_sdhc)   -- persisted for later read/write calls
         |
         v
   "SD/MMC: init done, RCA=0x... is_sdhc=... SDHSTS=... SDEDM=..."
   "SD DIAG: sdhost_init total elapsed t=...us"
         |
         v
  +----------------------------------------------------------+
  | 8-block round-trip self-test sweep (blocks 2100-2107)     |
  +----------------------------------------------------------+
         |
         v
   for each block: sdhost_write_block -> sdhost_read_block -> compare
         |
    on failure (NEW_FLAG stuck, or FSM never idle):
         |    -> sdhost_init() re-run in full (2026-09-15 fix --
         |       see "Known gaps" below for why this exists and
         |       why it's scoped to exactly these two failure
         |       modes, not a third one)
         v
   "SD DIAG: 8-block sweep elapsed t=...us"
         |
         v
  +----------------------------------------------------------+
  | DharaFS mount / recovery / compact                        |
  +----------------------------------------------------------+
         |
         v
   read /config/mode, /config/name; compact log; ls /config/
         |
         v
  +----------------------------------------------------------+
  | Full self-test suite (in-source order):                   |
  |  DharaFS multi-block/crash-consistency/compact/perms/dirs  |
  |  shell input-echo, eval, uart_put_i64                      |
  |  scheduler governor replay                                 |
  |  netif/firewall/ARP/IPv4/ICMP/UDP/TCP/DHCP(client+server)   |
  |  crypto: SHA-256/1, HMAC, PBKDF2, AES-CCMP, EAPOL-Key,      |
  |    WPA2 PTK/4-way-handshake/nonce-gen, 802.11 mgmt frames,  |
  |    ChaCha20/Poly1305, X25519, SHA-512, Ed25519, PKI,        |
  |    RTL8188CU descriptor/LLT self-tests, AES-128, AEAD+HKDF  |
  +----------------------------------------------------------+
         |
         v
   idle loop (scheduler governor steps, dynamic priority aging)
```

## Known real-hardware gaps and findings (as of 2026-09-15)

**Pre-`kernel_main` boot delay (open investigation).** A real Pi 1B
has shown a reproducible 5-10 minute pause, with the ACT LED blinking
a *fixed* count on repeat the whole time (not a reset loop -- no
repeated GPU `Bootcode` text), before `kernel_main`'s first UART
output ever appears. A hardware log already proved this delay is
entirely pre-`kernel_main`: `TIMER_CLO` (BCM2835 free-running 1MHz
timer, same clock the GPU's own `MESS:` timestamps are drawn from)
read ~359 seconds at `kernel_main` entry, against the GPU's own
`Starting ARM` timestamp of ~2.7 seconds on the same clock -- while
everything from `kernel_main` onward (SD init, the 8-block sweep, the
entire self-test suite) completes in well under a minute. The 7
`SNAP_TIMER` checkpoints shown in the diagram above were added
specifically to localize this further, to one of the 6 named
transitions inside `boot_entry`. Not yet resolved with a checkpoint-
by-checkpoint hardware log at time of writing.

**SD controller FSM wedge (found and partially fixed 2026-09-15).**
Real hardware showed `sdhost_wait_transfer_complete` reaching an
unrecognized `SDEDM` FSM state (`0x3` = `WRITEDATA`, confirmed against
Linux's own `drivers/mmc/host/bcm2835.c` `SDEDM_FSM_*` enum) that
this driver had no escape hatch for (it only knew how to force out of
`READWAIT`/`WRITESTART1`). Once wedged, the controller never
recovered on its own -- every subsequent block in the same sweep
showed the *identical* stuck `SDEDM` value, and DharaFS's own
mount/self-test code (which runs immediately after the sweep in the
boot sequence) then failed against that same wedged controller,
producing 5 DharaFS test failures (multi-block round trip,
crash-consistency, compact-resume, permissions, directory hierarchy)
that looked like independent DharaFS bugs but were actually SD-layer
fallout. Fix: `sdhost_read_block`/`sdhost_write_block` now re-run
`sdhost_init()` in full (proven power-cycle + re-identification
sequence, ~6-11ms) whenever `sdhost_cmd`'s `NEW_FLAG` never clears or
the FSM never returns to idle. Deliberately **not** extended to the
third failure mode (a real `SDHSTS` error bit) -- QEMU's own SD card
model leaves `SDHSTS` persistently set in a way this driver's
write-1-to-clear never actually clears under that model, and
resetting on that path turned a harmless pre-existing QEMU-only test
failure into a repeating reset loop that never reached `idle`; real
hardware's own failures never hit that path at all.

**Boot-media recovery-logic scope.** SD/eMMC (same SDHOST driver,
same code path) now has the reset-on-wedge recovery above. USB mass
storage (`usb_msd_read10`/`usb_msd_write10`) has **no equivalent
recovery logic** -- a transport failure just logs and propagates the
error with no retry or re-init. This is a real, currently-open gap,
but it does not affect Pi 1B *boot* reliability, since USB is never
boot media on this board (see the "why this only covers SD" section
above) -- it would only matter if something at runtime relies on USB
MSD as a block-device backend.
