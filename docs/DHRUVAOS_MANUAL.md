# DhruvaOS User Manual

DhruvaOS is a bare-metal, fixed-priority preemptive RTOS written in
the vāṇी language, currently targeting the Raspberry Pi 1 family
(BCM2835 / ARM1176JZF-S) under QEMU's `raspi1ap` machine model, with
an early boot-only port started for Pi 4 (see `PORTING.md`).

This manual describes what DhruvaOS actually does today, including
its current limitations — it is written to be accurate, not
aspirational. Where something is a known gap rather than a design
choice, it says so explicitly, with a pointer to `TODO.md`.

## 1. What kind of RTOS this is (and isn't) today

**Real, load-bearing RTOS mechanisms:**

- **Fixed-priority preemptive scheduling.** Tasks are ranked by a
  static priority (lower number = higher priority); the scheduler
  always runs the highest-priority *ready* task, preempting a
  lower-priority one the instant a higher-priority task becomes ready
  (via the timer tick or a voluntary wake).
- **Priority-ceiling protocol** for mutual exclusion
  (`dhruva_prio_lock(ceiling)` / `dhruva_prio_unlock(base_priority)`).
  A task raises its own effective priority to the resource's ceiling
  before touching it, and restores its base priority after — this
  *prevents* priority inversion by construction (a lower-priority
  holder can never be preempted by a task that would need the same
  resource, because its effective priority is already at least as
  high as anything that could contend for it). It does not use a
  runtime lock/wait-queue at all; see `dhruva_prio_lock`'s own comment
  in `boot/context_switch.S`.
- **Compiler-enforced timing bounds.** The vāṇी compiler supports
  `#[bounded_stack(bytes=N)]` (a hard build failure if the compiler's
  own static worst-case stack depth for that function exceeds N) and
  `#[wcet(cycles=N)]` (worst-case execution time bound, checked the
  same way). Both are used throughout `kernel_main.vani`, including on
  every task and on `irq_dispatch`. This is a real static-analysis
  guarantee, not a runtime measurement or a comment-only convention.
- **Hardware-timer-driven preemption**, not cooperative scheduling —
  a task that never yields still gets preempted by the timer tick.
- **A real blocking mutex with priority inheritance**
  (`dhruva_mutex_lock(mutex_id)` / `dhruva_mutex_unlock(mutex_id)`,
  round 55) — a second, different synchronization primitive alongside
  priority-ceiling protocol, for the case where a critical section's
  ceiling isn't known statically in advance. Unlike ceiling protocol,
  this genuinely blocks: a lower-priority holder really can delay a
  higher-priority waiter, and the waiter's own priority is temporarily
  lent to the holder for exactly as long as it holds the mutex
  (restored on unlock) to recover from that delay. Direct ownership
  handoff on unlock — a waiting task never re-checks anything, it
  already owns the mutex the moment it resumes. Live-verified over
  QEMU: `task_mutex_demo_high` genuinely blocks in
  `dhruva_mutex_lock` while `task_mutex_demo_low` holds it (a real,
  multi-tick gap between "requesting" and "acquired" in the UART
  trace), and `task_mutex_demo_low`'s own effective priority reads 0
  (boosted from its base priority 2) for the duration, provable via
  `current_eff_prio()`. No recursion support and no nested-mutex
  inheritance stacking (unlock always restores the full base priority
  unconditionally) — both deliberately out of scope for the single-
  mutex demo this needed, not oversights. Round 59 added the
  instrumentation this primitive's own existence finally makes
  possible: `mutex contentions` (genuine blocks only, not every lock
  call) and `mutex worst-case wait` (in ticks, from blocking to
  actually being handed ownership), both in `diagnose`'s output —
  live-verified growing correctly (2 → 7 contentions, a stable 3-tick
  worst case) against the same deterministic demo.
- **Packet filtering (round 60)**: a single hook in `netif_recv_frame`
  (all three backends) checks an 8-rule fixed table
  (`proto`/`src_ip`/`dst_port`/`action`, first-match-wins, a
  `default_policy` fallback — `boot/fw_state.S`) before a frame is ever
  handed to a caller. `fw add/list/flush/default` manage it from the
  shell. Live-verified over the real CDC-ECM link: a real `ping
  10.0.2.2` genuinely stops getting replies once `fw add deny icmp
  10.0.2.2 any` is issued (zero leaks across repeated live attempts),
  and resumes after `fw flush`.
- **A real, previously-undiscovered long-running crash, found and
  fixed (round 60 follow-up)**: `task_custom_demo`/`task_mutex_demo_
  low`/`task_mutex_demo_high` (rounds 54/55's dynamically-created demo
  tasks) were each allocated exactly 512 bytes of stack — matching
  their own compiler-verified `#[bounded_stack]` budget with zero
  headroom, unlike every other task in this project. A genuine stack
  overflow after several minutes of continuous scheduling, proven (not
  just inferred) by deliberately shrinking the same stacks further and
  watching the identical crash reproduce in ~60s instead of minutes.
  Fixed by giving all three the same generous headroom (4096 bytes)
  every other task already gets. Also surfaced a genuine vani-compiler
  soundness gap (`#[bounded_stack]` silently charged 0 bytes for any
  `extern "C"` callee), fixed upstream as BUG-233. See `TODO.md` for
  the full investigation writeup.
- **Real authentication (round 61)**: `su <uid> <gid> [password]` and
  a new `passwd <uid> <new_password>` command, backed by new
  `hmac_sha256`/`pbkdf2_hmac_sha256` primitives (`boot/auth_state.S`
  holds the salt+hash user table). A uid with no password ever set
  keeps the original unconditional `su` behavior; once a password is
  set, it's genuinely required and checked, with 3-strike lockout.
  Live-verified end to end (weak-password rejection, correct/incorrect
  password handling, lockout, an unconfigured account's unchanged
  behavior). Corrected a stale claim from this feature's own original
  scoping note: this shell does not actually echo any typed
  characters today, for any command — checked directly against
  `irq_dispatch`'s code, not assumed.
- **Media (at-rest) encryption (round 62, AEAD upgrade round 69)**:
  DharaFS block encryption hooked in transparently at
  `dharafs_block_read`/`dharafs_block_write` (every higher FS layer
  keeps operating on plaintext). Key derived once at boot via
  PBKDF2-HMAC-SHA256. Off by default; toggle live with `crypto
  on|off|status` (§3), no reboot needed. FIXED (round 69,
  2026-09-04): now real ChaCha20-Poly1305 AEAD, not a bare stream
  cipher — every block carries a Poly1305 tag (AAD = block number),
  and `dharafs_block_read` fails closed on any mismatch instead of
  returning corrupted bytes as if they were valid. The original
  two-time-pad weakness (nonce = pure function of block number, so
  overwriting the same block twice reused the same keystream) is also
  fixed: a dedicated per-block metadata region (blocks 4000+, clear of
  the log region) tracks a monotonically increasing write-counter per
  block, folded into the nonce, so the same block written twice now
  always produces different ciphertext. Uses dedicated AEAD scratch
  buffers, separate from TLS 1.3's own, to avoid a reentrancy hazard
  (DharaFS I/O is reachable from any task and could preempt a
  `tlsecho` task's own in-progress AEAD computation). Verified via an
  in-memory AEAD round trip, an explicit two-time-pad-fixed check, an
  explicit tamper-rejection check, a host-harness ASAN/UBSAN twin of
  all of the above, and a real SD-image end-to-end run — all on every
  boot now (`CRYPTO: DharaFS ...` lines), not just a one-time manual
  check.
- **A full TLS 1.3 + broader crypto/security suite (round 67, all
  same day, 2026-09-02).** Built out from scratch, each primitive
  verified against a real independent reference (Python + the
  `cryptography` library, or a third-party implementation) before any
  vāṇी code was written: Poly1305, X25519 (RFC 7748), SHA-512,
  Ed25519 (RFC 8032) — completing the Curve25519 EC foundation both
  for key exchange and signatures — then a compile-time-pinned-key PKI
  substitute (`verify <path>`, see §3), AES-128 (constant-time,
  table-free S-box — deliberately built despite this project's earlier
  ChaCha20-over-AES choice, since TLS's own standard cipher suites
  expect it available), ChaCha20-Poly1305 AEAD + HKDF (TLS's actual
  key-schedule/record-layer primitives), Keccak-f[1600]/SHA-3/SHAKE,
  and — by explicit request, overriding this backlog's own earlier
  "not recommended yet" scoping call — a full ML-KEM-512 (FIPS 203)
  post-quantum KEM, byte-exact against the third-party `kyber-py`
  reference. All of that fed into a real RFC 8446 TLS 1.3 handshake +
  record-layer state machine (`TLS_CHACHA20_POLY1305_SHA256`, X25519,
  RFC 7250 raw public keys — no X.509), wired into the live TCP
  transport (a real three-way handshake, every message fragmented
  through `tcp_conn_send_data`'s own real 64-byte cap and reassembled
  on the other end). Try it: `tlsecho <text>` (§3) runs a complete
  live `tls_connect`/`tls_accept` handshake and encrypted echo, both
  roles, over loopback. See `TODO.md` round 67 for the full,
  primitive-by-primitive verification writeup — every one of these
  landed correct on its first real ARM build.
- **A full BLE stack (rounds 57/66)**: HCI transport (written to spec,
  pending real-hardware verification — no QEMU BLE device model
  exists), then, on top of that, real GATT client discovery
  (service/characteristic enumeration) and read/write, a full GATT
  SERVER role with its own attribute database, 128-bit custom UUID
  decoding, notifications/indications, and L2CAP Connection Parameter
  Update signaling. No shell commands expose this yet — it's an
  internal API surface (`boot/gatt_state.S`/`boot/gatt_server_state.S`)
  a future round would need to wire into the shell to actually drive
  interactively.
- **FIXED (round 65, 2026-09-01) — a long-running synchronous
  computation on any task could crash into a silent runtime trap under
  the real scheduler.** Found while tuning real authentication's own
  PBKDF2 iteration count — forced it down to 200 iterations (measured
  to reliably complete; 500+ eventually crashes). What "stall" turned
  out to mean: `dprintf()` (the backing implementation of vani's
  compiler-inserted bounds/overflow/shift-range trap path) was a total
  no-op, so the CPU spinning forever in `exit()`'s halt loop looked
  identical to a frozen scheduler — this is now fixed (`dprintf` prints
  for real over UART), a permanent diagnostic improvement independent
  of the underlying bug. With that fix, the real panic text is now
  visible (`"shift amount out of range"`, and separately a Data Abort
  at higher iteration counts). Confirmed NOT simple priority starvation,
  NOT argument corruption, NOT a scheduler malfunction, and — via a
  real experiment raising `task_f`'s stack 8x — NOT simply insufficient
  stack headroom either (the crash relocated to a higher iteration
  count instead of disappearing). A round-62c follow-up extended
  `fault_data_abort` to report the faulting instruction's own r0-r3
  (a permanent diagnostic improvement) and live-captured two crashes
  with it: both land on the same `buf_read_u32`/`buf_write_u32`
  accessor pair, and both times specifically the BASE-POINTER argument
  is corrupted (once to exactly NULL, once to unrelated ~2.3GB
  garbage) while the offset argument stays intact. Rounds 62d-f then
  corrected the original "probably IRQ-timing-dependent" working
  hypothesis with real, direct evidence: a live GDB breakpoint proved
  the corruption is NEVER present in any saved/restored IRQ context
  frame (rules out interrupt save/restore as the mechanism), it
  reproduces (rarely, ~1/30) even with interrupts fully masked and zero
  concurrency, and it looks like genuine stack-smash/control-flow
  corruption rather than one bad pointer (a compile-time-constant
  checkpoint argument came back wrong too, immediately followed by a
  Prefetch Abort at a wild PC). IRQ timing is confirmed NOT the root
  mechanism, but does amplify whatever the true cause is by roughly
  10x under live multitasking (~20-30% vs ~1/30). Round 63 then audited
  every function in the `sha256`/`hmac`/`pbkdf2`/`dharafs_buf.S`/
  `sdcard_state.S` call chain for a buffer-bounds violation or an AAPCS
  callee-saved-register violation and found neither. Round 64 caught a
  live crash under a GDB hardware watchpoint on `sha256_compress`'s
  own saved-return-address stack slot — the watchpoint never fired
  across the whole run despite the crash, which is a real, direct
  (not inferred) negative result: **the corruption is conclusively NOT
  a write to that specific stack slot**, ruling out round 62f's
  stack-smash theory for that location specifically. Round 65 switched
  from GDB to QEMU TCG plugins (near-native-speed in-process register/
  memory tracing) and bisected the corruption to `sha256_compress`
  holding its `w` message-schedule pointer live in one register (r8)
  across its whole ~64-round loop body — a wild memory write to the
  scratch-pointer table was ruled out (a dedicated write-watch plugin
  proved nothing writes there at runtime except the expected boot
  init), and `irq_entry.S`'s own save/restore was manually re-derived
  against the actual compiled bytes three times and found correct each
  time, so no single corrupting instruction was ever pinned down.
  Fixed defensively instead: `sha256_compress`/`sha256_h_init` no
  longer hold `h`/`w`/`k` live in a register across the whole
  function — they re-fetch each scratch pointer fresh via
  `sha256_h/w/k_scratch_get()` at every point of use, closing the
  whole class regardless of the exact mechanism. Verified with 100
  consecutive `passwd`/`su` attempts, zero crashes (the prior build
  crashed 3 times in as many verification runs). See `TODO.md` for the
  complete investigation, including a reverted first attempt
  (interrupt-masking) that caused a serious unrelated performance
  regression.
- **FIXED (round 66, 2026-09-01) — a second, separate bug of the same
  broad class: even one extra real SD block read or write during boot
  could intermittently (~20-30%) corrupt unrelated state, surfacing
  minutes later as a genuine Data Abort inside `task_e`'s background
  DharaFS compaction.** Found live while building media encryption's
  own self-check (round 62) — bisected to confirm it was independent
  of the encryption feature's own logic (a version doing zero extra
  real SD I/O was 100% reliable across 16+ repeated runs). Round 66
  re-added the original trigger as a temporary diagnostic and ran 20
  consecutive full boots watching for the delayed crash — zero
  crashes, confirming this was fixed as a side effect of round 65's
  task_f fix (specifically the general scheduler hardening in
  `boot/context_switch.S`, not the SHA-256-specific part), exactly as
  suspected since round 62d/62e first found the two bugs shared a
  trigger and symptom shape. Media encryption's own on-target
  self-test still deliberately avoids real SD I/O for now (a
  conscious choice — see `TODO.md`'s own round-66 follow-up note on
  reconsidering that); the real end-to-end path is verified via the
  host harness and a one-time manual live run. See `TODO.md` for the
  full writeup.
- **ROOT-CAUSED AND FIXED (round 68, 2026-09-04) — the actual
  mechanism behind round 65/66's own "still not fully root-caused"
  corruption class, found while chasing a new, unrelated `tlsecho`
  crash.** `irq_entry.S`'s saved task-context frame used a single word
  to hold both "the value to restore into r14" and "the address to
  resume execution at" — the same value for a *voluntary* switch
  (`task_sleep_ticks`/`dhruva_mutex_lock`), but genuinely different
  values for an *interrupt*-driven one. The interrupted task's real
  r14 was never actually saved anywhere for that path — it got
  silently overwritten by `irq_dispatch`/`scheduler_switch_from_irq`'s
  own calls before the task resumed. A task resumed while executing
  one of this project's ~300 hand-written two-instruction `bx lr`
  accessor leaves (every `boot/*_state.S` `*_get`/`*_set`, `buf_read_
  u32`/`buf_write_u32` among them) would come back with `r14 == pc`:
  the single load/store re-executes fine, then `bx lr` jumps back into
  its own entry instead of returning, repeatedly treating whatever it
  just read as a new pointer until it dereferences something unmapped
  — a real hardware Data Abort whose "wild" address is just wherever
  that chase happened to end. Fixed by giving the saved frame a 17th
  word so the true return address and the resume point are restored
  independently (ARM's standard `ldmia {...,lr,pc}^` exception-return
  idiom) across all four save/restore sites. A 190-boot black-box
  sweep plus a direct re-run of round 63's own scoped hardware-
  watchpoint check (56,708 `sha256_compress` calls, 1.1B+ memory
  stores, zero hits) both found nothing — round 62f's separate
  zero-interrupt PBKDF2 corruption is believed resolved as a side
  effect of round 65's own fix, though not independently re-verified
  with dedicated instrumentation. With the underlying bug fixed,
  `passwd`/`su`'s PBKDF2 iteration count was raised from 200 to a real
  20,000 (~13s interactively on this hardware — a measured, deliberate
  tradeoff, not the old bug's own ceiling; see `TODO.md` for the full
  timing data and reasoning). Also added a permanent per-task
  stack-overflow canary (`boot/stack_canary.S`) as independent
  hardening alongside the actual fix, not a replacement for it. See
  `TODO.md` round 68 for the complete mechanism writeup.

- **6 fixed compile-time tasks, plus up to 10 dynamically-created
  ones (MAX_TASKS=16).** The original 6 slots (HIGH, MEDIUM, LOW — a
  priority-ceiling demonstration — IDLE, GC/`task_e`, and
  SHELL/`task_f`) still exist unchanged at indices 0-5. Indices 6-15
  are free slots handed out by `task_create(entry_fn, stack_base,
  stack_bytes, priority) -> u32` (`boot/context_switch.S`), which
  returns the new task's slot index, or `0xFFFFFFFF` if all 10 are
  already taken. There is still no task-*deletion* API, so a slot is
  never reclaimed once handed out. `task_table_init()` must run once,
  before the first `task_create()` call and before
  `start_multitasking` — `kernel_main.vani`'s boot sequence already
  does this; a function passed to `task_create` as a value needs
  `#[no_mangle]` (see §5).
- **The timer tick is 500ms** — fine for this project's own demo and
  self-tests, far too coarse for most real control loops (a typical
  RTOS runs 1ms or tickless).
- **A real hardware watchdog exists (`watchdog_arm`/`_init`/`_kick`,
  targeting the real BCM2835 PM peripheral) but is deliberately NOT
  wired into the live boot/scheduler path.** Confirmed empirically:
  QEMU's `raspi1ap` model doesn't honor `PM_WDOG`'s configured timeout
  at all — writing `PM_RSTC` with a full-reset config resets the
  emulated machine immediately regardless of what's armed, which would
  make this project's only test method permanently unable to boot.
  Revisit once real Pi 1B hardware-in-the-loop testing is available
  (see `docs/HARDWARE_IN_LOOP.md`) — real hardware may honor the
  timeout correctly where QEMU's emulation doesn't.
- **No deadline/budget model, and no contention instrumentation for
  the new blocking mutex yet** (contention count, worst-case wait) —
  the primitive itself exists and is live-verified (see above), but
  measuring it is not built yet. See `TODO.md`.
- **Networking has a real NIC path now (round 56), but with real
  caveats.** `netif_send_frame`/`netif_recv_frame` dispatch to one of
  three backends based on what USB device was enumerated: CDC-ECM (a
  standard USB class QEMU's own `usb-net` device and real USB Ethernet
  dongles both speak — **live-verified**: real ARP + `ping` round
  trips to an external host over the actual USB link, a fetched MAC
  matching an independently-specified value, QEMU packet-capture-
  confirmed real frames on the wire), a real SMSC LAN9512 backend (the
  actual chip every Pi 1 Model B's onboard wired port uses —
  **written to spec, NOT live-verified**: no LAN9512 QEMU device model
  exists, pending real Pi 1B hardware-in-loop testing), or the
  original loopback queue (when neither is present). **Found via live
  testing**: `dhcp_client_poll` (and likely other netif-layer callers)
  pass a hardcoded `max_len=512` inherited from the loopback-era
  design — a real external DHCPOFFER with several options routinely
  exceeds that and gets silently dropped. Not yet fixed (needs
  auditing every 512-sized buffer across netif/ARP/IPv4/UDP/TCP/DHCP
  consistently, not a point fix) — see `TODO.md`.
- **A USB Bluetooth HCI transport exists (round 57), entirely
  written to spec, NOT live-verified.** USB Bluetooth HCI is an
  official, standardized USB class (0xE0/0x01/0x01), detected the same
  way mass storage's own class check works. HCI commands go over the
  control endpoint (`dwc2_hci_send_command`), events arrive via a
  dedicated interrupt endpoint (`dwc2_hci_interrupt_in` — this
  driver's first use of the interrupt transfer type), and ACL data
  uses bulk endpoints, same primitives as the NIC driver. On
  enumeration, `hci_reset_and_scan` sends HCI_Reset, then
  LE_Set_Scan_Parameters, then LE_Set_Scan_Enable. Unlike CDC-ECM,
  there is no QEMU stand-in at all: `usb-bt-dongle` (which implemented
  exactly this transport) was deprecated in 2018 and removed from
  modern QEMU, so nothing in this transport has ever received a real
  HCI event. The packet building/parsing math is pure and has real
  host-harness test coverage; the transport itself is pending real Pi
  1B hardware-in-loop testing. GATT/ATT/L2CAP (the layers an
  application actually uses to read/write BLE characteristics) don't
  exist yet — see `TODO.md`.
- **USB WiFi (round 58) stops at enumeration + vendor register I/O,
  by design.** Realtek RTL8188CU/RTL8192CU family dongles (VID
  `0x0bda`, PID `0x8176`) are detected the same way LAN9512 is
  (idVendor:idProduct, since this chipset's own USB interface is
  entirely vendor-specific — class `0xFF`, no standard class to key
  off the way CDC-ECM/Bluetooth HCI have). `rtl_reg_read8/16/32` and
  `rtl_reg_write8/16/32` implement the chip's own vendor register
  protocol (confirmed against Linux's `rtl8xxxu` driver — a different
  wire format from LAN9512's own). `rtl8188cu_probe` runs on
  enumeration and reads two registers as a structural demonstration,
  then **stops**: every real USB WiFi chipset requires uploading a
  proprietary firmware blob to an embedded MCU before the radio does
  anything at all, and that blob isn't something this project can
  derive from a public spec or fabricate — it comes from the
  `linux-firmware` project, a legally separate, redistributable binary
  collection under the vendor's own terms. This project fetched the
  real firmware temporarily to verify the header-format claims in
  `rtl8188cu_probe`'s own comment are accurate rather than copied
  blind from driver source, then deleted it — never committed to this
  repository, and never will be; see that comment for the exact URL
  and verified byte-level details for whoever continues this with real
  hardware. The 802.11 MAC-layer state machine and WPA2/AES (this
  project's own crypto foundation deliberately chose ChaCha20 over AES
  for ARMv6-specific reasons — see round 44) remain untouched, far
  larger separate efforts — see `TODO.md`.

## 2. Boot process

1. `boot/rpi1/boot.S` — CPU reset entry, initial stack setup, BSS
   zeroing, then jumps into vāṇी's `fn_main`.
2. `boot/mmu_init.S` — sets up the ARMv6 short-descriptor MMU with
   Normal/Device memory types and W^X enforcement (see round 38's own
   history for why XN can't be fully hardware-verified under this
   project's QEMU version).
3. `kernel_main.vani`'s own `fn_main` runs the full boot-time self-test
   battery (currently 45 self-tests spanning the FS layer, networking,
   crypto, bignum arithmetic, the evaluator, and more), then:
   - Initializes DharaFS (`dharafs_init` — scans the SD card's log for
     the real append cursor and highest sequence number; see
     `DHARAFS_MANUAL.md`).
   - Allocates each task's stack and every persistent scratch buffer
     (`dhruva_alloc_bytes` — see §4).
   - Enables interrupts (`enable_irqs`) and calls `start_multitasking`,
     which never returns — from this point on, everything runs as one
     of the 6 scheduled tasks.

A full self-test PASS/FAIL summary prints over UART before
multitasking starts; a genuine self-test FAILURE or a hardware fault
(`boot/rpi1/vectors.S`'s `fault_data_abort`/`fault_prefetch_abort`)
halts with a diagnostic rather than continuing into a possibly-corrupt
state.

## 3. The shell (task_f)

An interactive command line over the UART console (visible under QEMU
via `-serial stdio`/`-nographic`). Type a command and press Enter.

### Filesystem commands

| Command | Usage | Notes |
|---|---|---|
| `ls` | `ls [prefix]` | Flat listing of every live path starting with `prefix` (or everything, if omitted). |
| `cat` | `cat <path>` | Read and print a file's content, permission-checked as the current shell user. |
| `catv` | `catv <path>` | Like `cat`, but also verifies a companion SHA-256 digest if one was written with `writev`. Reports `INTEGRITY FAILURE` if the digest doesn't match; a file with no digest reads normally (verification is opt-in per path). |
| `write` | `write <path> <text>` | Create or overwrite a file. New files default to mode 0644, owned by the current shell user. |
| `writev` | `writev <path> <text>` | Like `write`, but also stores a SHA-256 digest at a companion `<path>.sha256` file for later verification via `catv`. |
| `rm` | `rm <path>` | Delete a file (write permission required). |
| `mv` | `mv <old-path> <new-path>` | Rename, permission-checked on both sides. Atomic across a crash — see `DHARAFS_MANUAL.md`'s transaction section. |
| `log` | `log <name> <text>` | Append-only log API: writes to `/logs/<name>-NNNN.log`, rolling over to a new numbered file automatically once the current one nears 3584 bytes. |
| `chmod` | `chmod <path> <mode-decimal>` | e.g. `chmod /f 420` for `rw-r--r--` (420 = 0644 octal). Owner or root only. |
| `chown` | `chown <path> <uid> <gid>` | Root only — even a file's own owner cannot give it away. |
| `attr` | `attr <path>` or `attr <path> <immutable\|append\|system> <on\|off>` | Query or set the immutable/append-only/system attributes. A non-root owner can set either protective attribute but never clear it once set; only root can undo them. `system` has no enforcement of its own (informational). |

### Networking commands (loopback-only — see §1)

| Command | Usage | Notes |
|---|---|---|
| `ping` | `ping <a.b.c.d>` | ICMP echo. Only ever succeeds against `0.0.0.0`/self under QEMU — no real second host exists on the loopback-only netif. |
| `ifconfig` | `ifconfig` | Shows the interface MAC and current DHCP client state. |
| `netstat` | `netstat` | Dumps the ARP cache and both TCP connection slots' current state. |
| `tcpecho` | `tcpecho <text>` | Full TCP three-way handshake + data + close round trip, self-talking over loopback. |
| `udpecho` | `udpecho <text>` | UDP send/receive round trip, self-talking over loopback. |
| `tcprtx` | `tcprtx` | Deliberately drops the first SYN and proves the real 2-second retransmission timer recovers the connection. |
| `tlsecho` | `tlsecho <text>` | Full TLS 1.3 handshake (`tls_connect`/`tls_accept`, both roles) + AEAD-encrypted echo, self-talking over loopback (round 67). |
| `fw` | `fw add\|list\|flush\|default ...` | Packet filtering (round 60, see §1) — manage the 8-rule table from the shell. |

### System / diagnostic commands

| Command | Usage | Notes |
|---|---|---|
| `eval` | `eval <expr>` | Small arithmetic expression evaluator (`+ - * / ( )`), traps on overflow and division by zero. |
| `id` | `id` | Shows the active uid/gid for the current shell session. |
| `su` | `su <uid> <gid> [password]` | Switches the active permission context. uid 0 is root (bypasses all permission checks). Unconditional for a uid that has never had a password set (round 61); once `passwd` sets one, it's genuinely required and checked, with 3-strike lockout. |
| `passwd` | `passwd <uid> <new_password>` | Sets/changes a uid's password (round 61) — root or the uid itself only. Stores a fresh salt + PBKDF2-HMAC-SHA256 output, never the password. Min 8 characters, checked against a small weak-password blocklist. 20,000 PBKDF2 iterations as of round 68 (~13s), up from the original bug-limited 200. |
| `verify` | `verify <path>` | Verifies `<path>` against a companion `<path>.sig` (a raw 64-byte Ed25519 signature) using a compile-time-pinned public key (round 67) — the "smaller substitute" for secure boot this project's own hardware ceiling rules out (see §1/`TODO.md`). |
| `crypto` | `crypto on\|off\|status` | Toggles DharaFS media (at-rest) encryption live, no reboot needed (round 69). AEAD (ChaCha20-Poly1305) with real tamper detection and a per-block write-counter closing the original two-time-pad weakness — see `DHARAFS_MANUAL.md` §8. |
| `diagnose` | `diagnose` | One-shot health report: uptime ticks, scheduler ready count, heap usage (current == high-water mark, since the allocator never frees), CPU frequency + governor history, allocation count, FS commit count, context switch count, IRQ count, `dhruva_prio_lock` call count, mutex contention count + worst-case wait ticks (round 59), and (round 66) up to the last 32 ticks (~16s) of recent history — tick/context-switch/IRQ/prio-lock-count as of each real timer tick, oldest first, for a "what was activity like recently" view alongside the running totals above. |
| `fault` | `fault alloc\|write\|irqburst\|netdrop <n>` | Fault injection (round 51 + round 62). `alloc <n>`: triggers a real, unrecoverable OOM-fatal halt after the Nth heap allocation — no confirmation, no undo, by design. `write <n>`: the Nth subsequent real SD write fails (a real I/O error, no hardware touched). `irqburst <n>`: the next timer tick jumps the clock forward by n extra ticks (a time-warp, not a real preemption-burst simulation — see `TODO.md`). `netdrop <n>`: the next n outgoing network frames are silently dropped while still reporting success, exercising TCP retransmission on demand. |

Type anything unrecognized to see the full command list echoed back.

## 4. Memory model

- **`dhruva_alloc_bytes(n)`** is a 256KB bump allocator that **never
  frees**. This is deliberate, not a bug: every real allocation in
  this codebase is either a one-time boot-time scratch buffer or a
  persistent, reused-forever buffer for a function that's called
  repeatedly (see `feedback_dhruva_never_free_heap_pattern` in project
  memory, or just: if you're adding a new function that will be called
  more than once at runtime, give it a *persistent* scratch buffer —
  allocated once at boot — rather than calling `dhruva_alloc_bytes`
  inside the function body itself).
- **Exhaustion is a clean, loud, whole-system halt**, not silent
  corruption. `dhruva_alloc_bytes` prints a diagnostic (requested
  size, bytes used, capacity) and halts with interrupts disabled — a
  genuine stop, not just the calling task freezing. `heap_usage_self_
  test` (part of the boot self-test battery) is the real, permanent
  early-warning canary: it checks for at least 16KB of headroom after
  every self-test allocation has already happened, specifically so a
  future change that eats into that margin fails loudly at boot
  instead of manifesting as an unexplained runtime halt later.
- You can deliberately exercise the OOM-fatal path with `fault alloc
  <n>` (see §3) rather than only via the host-side test harness's
  synthetic constructions (`test/host_harness/`, which tests DharaFS
  and crypto logic under ASAN/UBSAN as an ordinary host process — see
  its own `README.md`).

## 5. Extending the kernel today

Editing `kernel/kernel_main.vani` directly is still how you add most
things:

- **A new shell command**: add a new `if shell_word_matches(line_buf,
  0, cmd_end, "yourcommand") == 1 { ... return 0; }` block inside
  `shell_dispatch()`. Use a **persistent** scratch buffer (§4) for any
  working memory the command needs, not `dhruva_alloc_bytes` directly,
  if the command might reasonably be run more than once in a session.
- **A new self-test**: add a `fn your_thing_self_test() -> i64`
  function and call it from the boot sequence alongside the existing
  ~45. Report PASS/FAIL via `uart_puts`, matching the existing
  convention.
- **A new task** (round 54): call `task_create(entry_fn, stack_base,
  stack_bytes, priority) -> u32` — see §1. The entry function must be
  declared `#[no_mangle]` (passing a function as a *value*, as opposed
  to calling it directly, requires the compiler to resolve the exact
  same symbol name at both the definition and the reference; a plain
  vāṇी fn is mangled to `fn_<name>` at its definition, and — before a
  real vani-compiler bug found and fixed alongside this feature — the
  function-pointer-*value* reference kept the mangled name while
  looking up a call kept the bare name, an LLVM/C-backend symbol
  mismatch that failed to link. `#[no_mangle]` sidesteps this by
  giving the function one stable bare name used consistently
  everywhere). Give it its own `#[bounded_stack(bytes=N)]` bound like
  any other task. Allocate its stack with a one-time
  `dhruva_alloc_bytes` call, matching every fixed task's own stack
  allocation. See `task_custom_demo` in `kernel_main.vani` for a
  complete worked example.

## 6. Building and running

```sh
./build.sh                                   # produces build/dhruva.elf
python3 test/qemu_run.py build/dhruva.elf    # quick boot smoke test (no SD image)
python3 test/phase4_milestone.py build/dhruva.elf   # full live shell/network milestone, with a real SD image
```

For interactive use:

```sh
qemu-system-arm -M raspi1ap -kernel build/dhruva.elf -serial stdio -display none \
    -drive file=<sd-image>,if=sd,format=raw,cache=writethrough
```

Regression battery (see `test/*.py`): `phase4_milestone.py` (live
milestone), `heap_stress.py` (reboot-loop heap growth detection),
`power_yank.py` (DharaFS crash-consistency sweep — also, incidentally,
the most sensitive detector this project has for a corrupted UART byte
stream, since it does a strict decode of the raw serial capture; see
`feedback_aapcs_callee_saved_registers_asm` in project memory for why
that matters). `test/host_harness/` runs DharaFS + crypto logic under
ASAN/UBSAN as an ordinary host process — see its own `README.md`.

## 7. See also

- `docs/DHARAFS_MANUAL.md` — the filesystem, in full.
- `docs/TODO.md` — the honest, currently-open backlog (task-creation
  API, real NIC/BLE/WiFi drivers, priority-inversion detection, and
  more), each item sized against what actually exists today.
- `docs/PORTING.md` — the Pi 4/5 port's current state.
- `docs/HARDWARE_IN_LOOP.md` — connecting and testing against a real
  Pi 1 Model B + SD card, on top of (not instead of) this project's
  QEMU-based regression battery.
