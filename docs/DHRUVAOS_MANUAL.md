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
  mutex demo this needed, not oversights.

**Known, current limitations (not design goals — see `TODO.md`):**

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

### System / diagnostic commands

| Command | Usage | Notes |
|---|---|---|
| `eval` | `eval <expr>` | Small arithmetic expression evaluator (`+ - * / ( )`), traps on overflow and division by zero. |
| `id` | `id` | Shows the active uid/gid for the current shell session. |
| `su` | `su <uid> <gid>` | Switches the active permission context. uid 0 is root (bypasses all permission checks) — there is no login/authentication of any kind, `su` is unconditional. |
| `diagnose` | `diagnose` | One-shot health report: uptime ticks, scheduler ready count, heap usage (current == high-water mark, since the allocator never frees), CPU frequency + governor history, allocation count, FS commit count, context switch count, IRQ count, and `dhruva_prio_lock` call count. |
| `fault` | `fault alloc <n>` | **Deliberately triggers a real, unrecoverable OOM-fatal halt** after the Nth subsequent heap allocation, for testing the OOM path itself. There is no confirmation prompt and no way to undo it once armed — this is the intended behavior, not a bug. |

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
