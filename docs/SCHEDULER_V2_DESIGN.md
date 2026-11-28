# DhruvaOS Scheduler v2: design

Status: **proposed** (2026-11-28). Goal: a faster, snappier system, with
**no loss** of the current scheduler's safety properties. Each phase
below ships on its own, behind its own tests, and can be reverted on its
own.

## 1. Why: the measured problems

| Symptom | Cause in the current scheduler |
|---|---|
| A typed shell command waits up to **1 s** before it starts | `task_f` idle-sleeps `task_sleep_ticks(2)` while no line is ready, and nothing wakes it early |
| Every sleep or poll is rounded **up to 500 ms** | The tick is 500 ms (`scheduler_tick_interval_us`), and sleeps are counted in ticks |
| Background work runs at 0.1–2 Hz (GC: 1 block every 20 ticks = 10 s) | Periods are written as tick counts |
| Three attempts to shorten the tick (100 ms and 250 ms; rounds 191, #243, #288) all failed | Every period and timeout is **denominated in ticks**, so a finer tick silently multiplied the real-time rate of GC critical sections, status prints and heartbeats, which swamped the system and the harness's fixed `SETTLE_S` waits |
| Equal-priority tasks rotate only at tick boundaries | The round-robin quantum is the tick (500 ms) |

None of these is a bug in the policy itself. The policy is sound and
proven on hardware. The problem is the **time base** and the lack of
**event wake-ups**.

## 2. What must not change (safety invariants)

These are load-bearing today. v2 keeps every one of them, and each has a
regression test (section 7):

1. **Priority policy.** Run the lowest `eff_prio` among ready tasks, with
   16 levels. Round-robin among genuine ties, **except** when the
   incumbent holds a ceiling (`ceiling_depth_table[current] > 0`): then
   the tie favors the incumbent. This is what makes the immediate
   priority-ceiling protocol (`dhruva_prio_lock`/`unlock`) sound.
2. **Immediate priority ceiling protocol** for every shared resource
   (DharaFS ceiling 2, and so on). It is bounded, deadlock-free and has
   no chained blocking.
3. **Aging.** Starvation is closed (round 184).
4. **Temporal isolation.** WCET-budget eviction, deadline-miss and
   stuck-task accounting, and per-task heartbeats.
5. **Spatial isolation.** USR-mode tasks, per-task 1 MB memory domains,
   guard pages and stack canaries.
6. **Sporadic-server bound on UART RX** (the interactive-traffic budget),
   bypassed only by the kernel-upload raw mode.
7. **The idle task never sleeps.** The picker always has a ready
   candidate.
8. **The picker stays O(MAX_TASKS = 16)** with a statically known WCET.
   It runs with IRQs masked.

## 3. Design

### 3.1 Time base: microseconds, not ticks (the structural fix)

- **All time is absolute microseconds** from the free-running 1 MHz
  system timer (CLO, plus CHI for 64-bit extension). The tick period
  becomes an implementation detail that nothing outside the scheduler
  can observe.
- `task_sleep_ticks(n)` becomes `task_sleep_us(us)`, with
  `task_sleep_ms(ms)` as a helper. `sleep_until_table` stores an
  **absolute µs deadline**. Wrap-safe comparisons use `wrapping_sub`
  against the current time, as today.
- **Every period and timeout is converted to ms or µs:**
  - the 15 `task_sleep_ticks(N)` sites,
  - the 55 `scheduler_get_tick_count()` timeout comparisons (DHCP lease
    timers, `MAINTENANCE_MODE_STALE_TICKS`, kernel-upload inactivity,
    heartbeat bounds, deadline tables, aging thresholds),
  - the scheduler's tick-denominated assembly tables.

  Once that's done, changing the tick rate no longer changes any task's
  real-time behavior. This is exactly the property all three earlier
  attempts lacked.
- `tick_count` survives only as a **statistic** ("ticks elapsed"), so
  existing diagnostics keep working.

### 3.2 Finer tick: 1 ms (1 kHz) on the existing FIQ timer channel

- **The timer interrupt** stays on system-timer channel C1 (FIQ), as
  today. The compare is reprogrammed from CLO each tick, as
  `scheduler_tick` already does, so a late tick never drifts.
- **Catch-up must be computed from time, not counted.** An SD write
  masks interrupts for up to about 42 ms (measured worst case, task
  #284/#285). At 1 kHz that delays up to about 42 ticks. The tick
  handler therefore derives "now" from CLO and wakes everything whose
  deadline has passed. It never assumes one interrupt equals one tick.
  This also fixes the masking interaction that hurt the 100 ms attempt.
- **Cost budget.** The pick is O(16) with IRQs masked, measured today by
  `irq_tick_worst_us`. The gate: tick handler plus pick must stay under
  **2% CPU at 1 kHz** (that is, under 20 µs) on real hardware with the
  stack cache on. If it doesn't, fall back to 4 ms (250 Hz), which is
  still 125× finer than today.
- **The round-robin quantum** becomes its own constant, `RR_QUANTUM_US`
  (default 10 ms), independent of the tick.

### 3.3 Event wake-ups: no more poll-and-sleep for interactive paths

New primitive: **event objects.**

```
event_wait(ev, timeout_us) -> bool    // task context: sleep until signalled or timeout
event_signal(ev)                       // task OR interrupt context: wake the waiter(s)
```

- **Implementation.** An event is a small table entry (`waiter_mask` and
  `pending` bits). `event_signal` sets `pending` and clears the waiter's
  `sleep_until` deadline (`sleep_until_table_set_at(task, now)`). Because
  **every IRQ and FIQ already exits through `scheduler_switch_from_irq`**
  (`irq_entry.S`, `fiq_entry.S`), a task signalled from an interrupt is
  switched to **on that interrupt's exit** whenever it outranks the
  current task. That needs no new reschedule path, only the wake.
- **First users:**
  - **The shell:** the UART RX handler signals `EV_SHELL_LINE` when it
    completes a line. `task_f` does `event_wait(EV_SHELL_LINE, 1 s)`
    instead of `task_sleep_ticks(2)`. Command start latency goes from up
    to 1000 ms down to the interrupt exit, typically under 1 ms.
  - **Kernel-upload raw mode:** the RX ring push signals the drain task,
    replacing its busy-poll.
  - **WiFi, LAN and BLE RX pollers:** these use USB polling, because
    DWC2 runs with its interrupt off. v2 makes their idle sleep
    `task_sleep_ms(2)` instead of 1 tick (500 ms). A DWC2
    channel-halted interrupt with an event is a later option.
- **Safety.** A waiter is still an ordinary sleeping task, scheduled by
  the unchanged priority policy. An event never bypasses priority or
  ceilings, and a signal from an interrupt only makes a task *ready*.
  The timeout keeps every wait bounded, which keeps it WCET-analyzable.

### 3.4 Unchanged pieces

These change only their time unit (ms or µs):
- the picker algorithm and its ceiling exception,
- mutex ownership and waiters,
- heartbeat and deadline monitors, WCET eviction and aging,
- the USR/SVC split, the SWI ABI, and domain switching.

### 3.5 Later, optional: tickless idle

When the only ready task is idle, program C1 for the earliest
`sleep_until` deadline instead of the next 1 ms tick, and `WFI`. This
saves power and changes no policy. It is deferred until 3.1–3.3 are
proven on hardware.

## 4. Boot time (companion work)

- **Done (`a68de19`):** the DharaFS media-key PBKDF2 (25 s of a 29 s
  real-hardware boot) is now lazy. Expected real-hardware boot is about
  4 s, pending verification.
- **Next:**
  - measure the remaining real-hardware boot phases: stage0's SHA-256 of
    the 4 MB slot, DharaFS init (1.8 s), USB bring-up (1.1 s);
  - enable the stack data cache at boot once the cache soak passes;
  - make the RTL8188CU firmware probe run in the background, which
    partly happens already.

## 5. Migration plan (each step behavior-gated)

| Phase | Change | Behavior change | Gate |
|---|---|---|---|
| **P1** | Introduce `sched_now_us()`, `task_sleep_ms/us`, and ms/µs constants; convert every period and timeout site; tick still 500 ms | **None**: same real-time values | phase4 18/18 identical; a new test asserts the time-based helpers give the same results as before |
| **P2** | Tick 500 ms → 1 ms, with time-based catch-up | Lower wake and preemption latency only | phase4 18/18; `irq_tick_worst_us` and CPU-share gate (3.2); real-hardware 1-hour soak with zero deadline misses or stuck tasks beyond baseline |
| **P3** | Event objects; shell, kernel-upload and RX pollers converted | Interactive latency under 10 ms | Latency test (7); phase4; real-hardware soak |
| **P4** | Optional tickless idle | Power only | Same as P2 |

**Test-harness fix in P1**, because flaky timing caused the earlier
failures: `phase4_milestone.py` and the QEMU tests wait for each
command's own reply (prompt or marker) instead of a fixed `SETTLE_S`.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Interrupt overhead at 1 kHz | Measured gate in 3.2; 250 Hz fallback |
| A missed period or timeout conversion | P1 lands first with **zero** behavior change; one grep-enforced rule (no raw tick literals outside the scheduler), checked in the build like `asm_safety_audit.py` |
| SD-write interrupt masking delays ticks | Time-based catch-up (3.2); no "one interrupt = one tick" assumption |
| Event signalled with no waiter, or lost | A sticky `pending` bit; `event_wait` checks it before sleeping, with IRQs masked around check-and-sleep |
| An event used to bypass priority | Impossible by construction: signal only makes a task ready; the picker is unchanged |

## 7. Verification

- **Existing:** phase4, heap stress, power-yank, and the scheduler
  self-tests (16 priority levels, aging, ceiling).
- **New (QEMU + real hardware):**
  - **Wake latency:** a UART line to the start of `shell_dispatch`,
    measured on the board with TIMER_CLO. Target under 10 ms; today up
    to 1 s.
  - **Ceiling-tie regression:** a ceiling-holding incumbent is never
    preempted by an equal-priority arrival.
  - **Aging:** a low-priority task makes progress under constant
    high-priority load.
  - **Catch-up:** a forced 40 ms interrupt-masked region, after which
    every expired sleeper wakes within one tick.
  - **Real-time invariance:** a periodic task's real-time rate is the
    same at a 500 ms and a 1 ms tick. This is the property the three
    earlier attempts broke.

## 8. Privilege model: USR tasks, SVC kernel (added 2026-11-28)

Tasks run in **USR mode**, which is right for isolation. But much
kernel-side code was written as if it always ran privileged. Three live
bug classes came from that on 2026-11-27, and all are now fixed:

| Assumption | Reality in USR mode | Fix |
|---|---|---|
| `cpsid`/`mrs`-`msr cpsr` brackets give a critical section | `cpsid` is a **silent no-op**: the allocator was not atomic across tasks (and masked IRQ only, not the FIQ tick) | SWI #9/#10 `crit_enter`/`crit_exit` set I+F in the task's saved CPSR; `dhruva_crit_enter/exit` choose direct `cpsid if` when privileged or the SWI from USR (`46c5415`) |
| A panic or FATAL that spins halts the machine | The scheduler keeps running the other tasks, whose `watchdog_kick()` (74 sites) re-armed it forever | Fatal-halt kick flag (`901fd51`) plus SWI #11 `fatal_halt` (`46c5415`) |
| CP15 can be written from anywhere | Undefined-instruction trap (the first `cachectl` attempt hung) | SWI #8 (`2b29787`) |

**Rule from here on:** task-reachable code never executes `cps*`,
`msr cpsr*`, `mcr`/`mrc p15` or privileged MMIO. Privileged operations
go through the SWI table only. **Enforcement:** extend
`asm_safety_audit.py`, which already gates every build, to flag those
instructions in any function reachable from a task entry point, unless
it is the SWI dispatcher or an exception handler.

## 9. Dynamic tasks (P5, P6), added 2026-11-28

Today there are `MAX_TASKS = 16` fixed slots:
- 0–5: the built-in tasks;
- 6–15: given out by `task_create`.

There is **no exit or delete**, so a slot, its stack domain and its
table entries are used once and never reused. 16 is also the ARMv6 MMU
**domain** count, and every task gets a private domain (1–15; 0 is the
kernel) for stack isolation.

### P5: full lifecycle inside the 16 slots

- **Slot states:** FREE → READY ⇄ RUNNING ⇄ SLEEPING/BLOCKED → ZOMBIE →
  FREE.
- **Handles:** `task_create(entry, stack_bytes, prio)` returns a
  **handle**: slot index plus a per-slot generation counter, so a stale
  handle to a reused slot is rejected (no ABA).
- **API:** `task_exit(code)`, `task_kill(handle)` (root or owner),
  `task_join(handle, timeout_us)` (uses P3 events), and
  `task_stat(handle)`.
- **What exit releases:**
  - The domain-window stack: zeroed and its guard page re-armed before
    reuse.
  - Every per-task table entry: `eff_prio` sentinel, sleep, heartbeat,
    deadline, WCET counters, canary, `usr_sp`, SPSR and PC.
  - Event registrations.
- **Safety rule:** exiting while holding a mutex or ceiling is a
  *fault*. Locks are released and the owner is flagged, never silently
  dropped, and the condition is reported. The built-in tasks (0–5)
  cannot be killed.
- **Reaping** runs in the exiting task's own SWI context, with I+F
  masked, so no half-dead slot is ever scheduled.

### P6: more than 16 tasks

Two independent limits have to go:
1. **Table sizes.** Every per-task assembly table becomes sized from one
   `.equ MAX_TASKS`. Hard-coded `#16` loop bounds get audited. Target 64.
2. **Isolation without one domain per task.** Use ARMv6's split
   **TTBR0/TTBR1 with ASIDs**, which the ARM1176 supports:
   - each task gets a small private TTBR0 table for its user region
     (stack plus private data), tagged with an 8-bit ASID;
   - the kernel and shared regions live in TTBR1;
   - a context switch writes TTBR0 and CONTEXTIDR, needing no TLB flush
     thanks to the ASID tag.

   This is the standard ARMv6 process model and scales to 255 address
   spaces. Domains then go back to coarse use: kernel, devices, user.

### Picker at N up to 64

The O(N) scan stays correct but grows. Replace it with a **16-bit
ready-priority bitmap** (`clz` picks the highest ready level in O(1))
plus a **FIFO ready queue per level**. That keeps round-robin among
ties, and keeps the ceiling-incumbent tie rule exactly: a
ceiling-holding incumbent is not rotated to the tail.

### Gates

- **P5:** create, exit, reuse churn of 10,000 cycles with no slot,
  stack or heap leak (allocation counter flat); a stale handle is
  rejected; a killed lock holder is detected and reported; phase4 18/18.
- **P6:** isolation tests (a task cannot read or write another task's
  stack: data abort), 64-task soak, picker WCET measured at N = 64.

### Updated order

P1 → P2 → P3 → P5 → P4 (tickless) → P6.

P5 needs P3's events for `task_join`. P6 is the largest change and comes
last, behind a stable P1–P5.

### P5b: retire the demo tasks (added 2026-11-28, per the owner's direction)

The always-on demo tasks are `task_a` (HIGH), `task_b` (MEDIUM),
`task_c` (LOW), `task_custom_demo`, `task_mutex_demo_low` and
`task_mutex_demo_high`. They exist only for demonstration and as targets
for the `fault stuck / stuckceiling / stuckmutex` injectors. Removing
them frees 6 of the 16 slots, plus their periodic wake-ups and prints.
That print volume is one of the things that broke the earlier
finer-tick attempts.

**Kept:** `task_d` (idle: `WFI` and the governor; the picker needs an
always-ready task), `task_e` (DharaFS GC), `task_f` (shell) and
`task_fsq` (DharaFS request queue).

**Safety coverage is not given up.** The fault injectors exist to prove
that the watchdog, heartbeat, WCET-eviction and ceiling enforcement
catch a misbehaving task. With P5's lifecycle each test spawns a
short-lived **test task** on demand (`selftest sched stuck|ceiling|
mutex`), checks the expected detection, and the task exits. So:

1. Land P5.
2. Convert the injectors to spawn-on-demand, with the same assertions.
3. Delete the demo tasks.
4. Replace the fixed-index assumptions with handles: the deadline table
   keyed to indices 0–2, `task_f`'s hard-coded heartbeat slot 5, and the
   "indices 0–5 are fixed" comments and checks.

**Gate:** every `fault` injector still reports its detection; phase4
18/18. The test harness's dependency on demo-task output is removed
first.

## 10. P1 status and the P2 checklist (2026-11-28)

**P1 batch 1 is done (`9410722`).** These are now stated in real time,
through `sched_ms_to_ticks` and `task_sleep_ms`:
- all 9 literal task sleeps;
- the GC cadence;
- every heartbeat bound and declared deadline;
- maintenance staleness;
- kernel-upload inactivity.

DHCP, TCP retransmit and the `su` lockout were already derived from the
tick interval. The remaining `scheduler_get_tick_count()` uses are
timestamps (crash log, management log, diagnostics), the shadow
predictor, and test-only seeds. None of them is a period or timeout.

**P2 must also rescale these scheduler-internal tick semantics**, found
in the P1 audit:

| Item | Today | At a 1 ms tick, unless rescaled | Rule |
|---|---|---|---|
| `AGING_SHIFT = 4` (context_switch.S) | 16 passed-over ticks earn one priority level of boost: about **8 s** | about **16 ms**, which collapses priority separation | Derive from the tick rate: keep about 8 s per level (shift about 13 at 1 kHz) |
| `UART_RX_IRQ_BUDGET_PER_TICK` | per-tick byte budget (sporadic server) | 500× more bytes per second | Bytes **per second**, replenished by elapsed µs |
| `SPN_SHADOW_AGING_SHIFT = 4` | mirrors `AGING_SHIFT` | same | Keep equal to `AGING_SHIFT` (the shadow predictor must match the real picker) |
| `task_run_ticks_table`, stuck and deadline counters | tick-granular statistics | finer granularity (fine) | Report in ms in `ps` |
