# DhruvaOS: gaps between "real RTOS primitives" and "a true RTOS"

This is an honest inventory, not a roadmap commitment. DhruvaOS already has
several genuinely real real-time primitives — fixed-priority preemptive
scheduling, a priority-ceiling protocol, a real blocking mutex with priority
inheritance (round 55), and compiler-enforced static checks
(`#[bounded_stack]`, `#[wcet]`). That is substantially more real-time
discipline than most hobby/demo kernels bother with. But there is a real gap
between "has real-time primitives" and "is a true RTOS" — mostly in
*runtime enforcement*, *fault isolation*, and *determinism of the I/O path*.
Every item below is either confirmed directly against the current code
(cited) or flagged explicitly as a general RTOS expectation this project
doesn't yet attempt.

## 1. Scheduling gaps

- ~~**No fairness among equal-priority ready tasks.** `scheduler_pick_next`
  (`boot/context_switch.S`) scans task slots and keeps the *first* candidate
  found whose priority beats the running best via a strict `<` comparison —
  a later-found task at the *same* priority never displaces it. Confirmed by
  reading the comparison directly (`cmp r6,r7 / movlt r7,r6 / movlt r8,r9`).
  Concretely: if task index 2 and task index 5 both sit at priority 2 and
  are both always ready, index 2 wins forever — index 5 can starve
  indefinitely. A true RTOS scheduler needs round-robin (or FIFO) rotation
  among tasks tied at the same priority, not "lowest index always wins."~~
  **`[DONE, round 75, 2026-09-05]`** — `scheduler_pick_next` now branches
  on whether `current_task` is ready AND currently boosted (holding a
  ceiling-protected lock, `eff_prio_table < base_prio_table`): if so, the
  OLD "ties favor the incumbent" algorithm runs completely unchanged —
  this is load-bearing for the priority-ceiling protocol's own safety
  (a boosted holder must never be preempted by a tie, or the whole point
  of the ceiling is defeated) — otherwise a new two-pass algorithm runs:
  find the minimum `eff_prio` among all ready tasks, then pick whichever
  tied candidate comes first scanning circularly from just past a new
  `rr_last_picked` cursor, so repeated ties genuinely rotate through
  every contender instead of always landing on the same one. Verified via
  full live regression (`phase4_milestone.py`'s own MUTEX-LOW/HIGH
  ceiling-protocol demo trace unchanged from before this round — HIGH
  still never preempts a boosted LOW mid-critical-section — plus correct
  `task_create()` slot ordering, `heap_stress.py`, `power_yank.py`).

  ~~A white-box self-test calling `scheduler_pick_next` directly against
  controlled table state was attempted and abandoned after it triggered a
  real, only partially root-caused crash...~~ **`[DONE via a different
  approach, Gap B, 2026-09-18]`** — a white-box test of the real function
  is still avoided (that crash risk is real and undiminished), but a safe
  independent shadow-model reimplementation of the same decision algorithm
  now runs on every IRQ, verified purely by observing outcomes through
  pre-existing safe accessors, never touching the real function's internal
  state. Zero mismatches across the full regression suite; a nonzero count
  is surfaced immediately (bounded diagnostic print) and in the `diagnose`
  shell command, not silently tolerated.
- ~~**No aging — a lower-priority ready task can starve indefinitely under
  an always-ready higher-priority one.** Round 75 above only fixed
  fairness among tasks *tied* at the same priority; a task strictly
  outranked by a different, permanently-ready priority number had no
  such protection — flagged explicitly in round 83's own comment
  (`docs/TODO.md`): "naive fixed-priority scheduling with no round-robin
  among equal/lower priorities and no aging."~~ **`[DONE, round 184,
  2026-09-12]`** — `ready_wait_ticks_table` (`boot/context_switch.S`)
  counts consecutive scheduling decisions a ready task is passed over,
  reset to 0 the instant it's picked. The fair (non-ceiling-boosted)
  path now ranks tasks by an "aged priority" (`eff_prio - min(eff_prio,
  wait_ticks >> AGING_SHIFT)`) instead of raw `eff_prio` — a starved
  task's aged priority falls toward 0 (this scheme's best) but never
  below it, so aging brings it up to parity with whatever's currently
  contending, never past it; round 75's own tie-breaking is what
  actually gives it a turn once tied. Never written back into
  `eff_prio_table` itself, so the priority-ceiling and priority-
  inheritance boost/restore logic (which read/write that table
  directly) stay completely unaware aging exists. Idle is the sole
  permanent exclusion (running it ahead of any genuinely ready task is
  never correct, aged or not).

  Live-verified with a temporary, self-retiring demo pair (one task at
  priority 0 that never sleeps, one at priority 3 with no tie to fall
  back on) before being removed again: the priority-3 task was
  genuinely unreachable without aging and got scheduled at tick 1053
  once its wait credit closed the gap, exactly as designed. That same
  experiment also surfaced a real, pre-existing, unrelated bug worth
  tracking separately — concurrent `uart_puts` calls from different
  tasks are not mutually excluded and can interleave mid-string on a
  real preemption (`docs/TODO.md`'s own open item).
- **500ms tick granularity.** Documented by the project itself as "fine for
  this project's own demo... far too coarse for most real control loops."
  Real RTOS work typically wants 1ms ticks or a tickless (timer-per-deadline)
  design.

  **Attempted, reverted, round 191 (2026-09-13)**: first extracted the
  tick period into a single-source-of-truth `scheduler_tick_interval_us()`
  (kept — was duplicated as a raw `500000` literal in two places,
  `timer_ic_init` and `irq_dispatch`, a real drift risk), then lowered
  it to 100ms as a deliberately conservative first step (5x finer, not
  the full 50-500x jump to 1-10ms) — rescaling every wall-clock-
  meaningful tick constant found by auditing the whole codebase for
  hidden period assumptions (`tcp_rtx_timeout_ticks`, DHCP's own
  `ticks_per_second`, and `auth_lockout_ticks` — the last one a real,
  narrow finding on its own: a **security-relevant** lockout duration
  that would have silently shortened to 1/5th its intended length if
  missed). The mechanism itself worked correctly at the new rate —
  domain isolation, aging, priority ceiling all stayed correct — but it
  broke this project's own PRIMARY verification method:
  `phase4_milestone.py`'s later interactive shell commands (`udpecho`
  onward) reproducibly, 100% of the time, never reached the guest at
  all. Leading hypothesis, not fully confirmed: DACR now gets written
  via `mcr` on every context switch (round 192) and the tick handler
  runs 5x more often, and QEMU's TCG backend traps/emulates privileged
  coprocessor and MMIO accesses in software at real, non-trivial HOST
  cost per access — architecturally free on real ARM1176 silicon, but
  measurably slower under emulation, silently eating into the fixed
  real-world time budget the test harness's own `SETTLE_S` delays
  assume. Since this project's entire verification loop runs on QEMU,
  reverted rather than shipped unverified. Going further needs either a
  real cycle counter (task #188's own already-identified gap) to tell
  "genuinely too much work per tick" apart from "QEMU-specific trap
  overhead," or accepting slower QEMU-based regression testing as a
  real tradeoff and adjusting the test harness's own timing budgets
  accordingly — neither attempted here.

  **Re-attempted with the real cycle-counter measurement, task #243
  (2026-09-18)**: the "real cycle counter" this item's own text called
  for now exists (`irq_tick_worst_us`, TIMER_CLO-bracketed). Real
  result: worst-case timer-tick IRQ dispatch cost measures 0us across
  a live run — a genuine correction to the "DACR/MMIO trap overhead"
  hypothesis above, which does NOT hold up under direct measurement. A
  temporary, reverted 250ms experiment (2x, more conservative than
  round 191's 5x jump) still reproduced the same class of cascading
  SETTLE_S failure, confirming the effect is real but NOT caused by
  per-tick dispatch cost — the evidence instead points at exactly what
  this item's own round-191 paragraph already found and didn't fully
  chase down: `tcp_rtx_timeout_ticks`/DHCP's own `ticks_per_second`
  express real-time durations as raw tick counts, so a faster tick
  silently changes real protocol timing, not just scheduling. Tick
  period unchanged (500ms); the real prerequisite is the same
  constant-rescaling audit round 191 already scoped, now with a
  materially stronger evidence base for where to look first.

  **Tickless design evaluated on this same evidence, task #247
  (2026-09-18), deliberately NOT implemented**: going tickless doesn't
  sidestep the real blocker task #243 just found -- it's the SAME
  underlying problem from a different angle. A tickless (timer-
  reprogrammed-for-the-next-actual-deadline) design still needs a
  time base every tick-count-expressed duration in this codebase can
  be measured against consistently; the moment `tcp_rtx_timeout_ticks`
  or DHCP's `ticks_per_second` exist as *tick counts* rather than
  continuous durations, "when is the next real deadline" is ambiguous
  without first deciding what a tick even means once ticks stop being
  periodic. Migrating every one of those constants to real
  microseconds throughout (the only way to make tickless genuinely
  correct, not just faster) is a substantially larger, more invasive
  rewrite than the rescaling audit round 191/243 already scoped for
  the tick-based approach — touching the same fragile timer/interrupt
  code class that has now caused two real, confirmed regressions this
  session alone (round 191's own revert, task #243's own reproduced
  250ms cascade), with no real Pi 1B hardware available in this
  environment to validate the result against. Not well-motivated by
  this project's own actual workload either: the real demo task set's
  own schedulability analysis (task #226/240) shows comfortable
  margins at 500ms (440ms-1445ms slack) — there is no live control
  loop today that needs sub-tick timing DhruvaOS doesn't already have.
  Documented and scoped rather than attempted, matching this project's
  own precedent for real-hardware-dependent, high-blast-radius risk
  (task #246's own FIQ finding, Pi 4/5 work "ON HOLD, no real HW
  planned").
- ~~**No formal schedulability analysis.** Priorities are hand-assigned;
  there is no tool computing a utilization bound (rate-monotonic) or
  running a response-time analysis across the declared task set's
  periods/WCETs. `#[wcet(cycles=N)]` bounds a single function's cost —
  nothing ties that into "is this whole task set actually
  schedulable."~~ **`[TOOL DONE, round 190, 2026-09-13 — not yet
  applied to DhruvaOS's own task set]`** — `test/schedulability_
  analysis.py` implements both the Liu & Layland (1973) sufficient
  utilization-bound test and exact fixed-priority response-time
  analysis (Joseph & Pandya, 1986), validated against 4 independently-
  hand-worked textbook examples (including one where the sufficient
  bound fails but exact RTA proves the set schedulable anyway — the
  actual textbook reason exact analysis exists, not a redundant second
  check).

  ~~**Deliberately NOT run against DhruvaOS's own current demo task set**
  in this round...~~ **`[DONE, RTOS audit Gap C/226, 2026-09-17]`** —
  applied for real. `#[wcet(cycles=N)]` now exists on every task body
  that can honestly carry one (6 of 10, with `uart_puts`/`uart_put_i64`
  call sites swapped to new bounded, WCET-safe counterparts so they
  stop transitively poisoning the estimate). The 4 left untagged
  (`task_c`/GC/`task_f`/`task_fsq`) each have genuinely runtime-data-
  dependent bodies (a data-dependent loop bound, or fan-out to
  arbitrary interactive commands) — real measured `TIMER_CLO` values
  feed the schedulability tool for those instead of a dishonest static
  tag, not "invented" numbers. `schedulability_analysis.py` extended
  with a real blocking-time term (Sha/Rajkumar/Lehoczky 1990) and run
  against the real demo set (HIGH/MEDIUM/LOW) using the measured 50ms
  LOW-priority blocking term: **verdict schedulable, 440ms-1445ms
  slack.** Honest residual gaps from that same pass: GC's own critical
  section is now measured too (Gap E, below), but context-switch
  overhead itself still isn't a modeled term (task #240) and per-task
  WCET only covers the demo set's dominant terms, not a hypothetical
  production workload — the tool and method are proven, not every
  future workload.
- ~~**No aperiodic/sporadic server.**~~ **`[DONE, task #242, 2026-09-18]`**
  — UART RX interrupt work now runs against a real sporadic-server-style
  budget (`uart_rx_irq_*`, `kernel/kernel_main.vani`), checked every
  tick and every IRQ entry.

## 2. Interrupt handling gaps

- **Real preemptive interrupt priority via FIQ, IMPLEMENTED 2026-09-18
  (task #246, reopened and completed after the earlier 2026-09-18
  investigation below had closed it as "documented, not implemented" —
  the user explicitly asked to proceed despite the documented risk).**
  The timer tick is now routed to BCM2835's FIQ line, the SoC's one
  genuine hardware interrupt-priority mechanism: `timer_ic_init`
  (`kernel_main.vani`) disables the timer's ordinary IC_ENABLE1 bit
  (`IC_DISABLE1`, base+0x1C) before configuring `FIQ_CONTROL`
  (base+0x0C, bit7=enable | bit[6:0]=source-select=1, the timer's own
  GPU-bank-1 bit position) — both register facts confirmed directly
  against real Linux `drivers/irqchip/irq-bcm2835.c`, not recalled from
  memory, including that specific disable-before-FIQ-config ordering
  requirement ("otherwise both handlers will fire at the same time",
  the real driver's own words). A new `boot/fiq_entry.S` (mirroring
  `irq_entry.S`'s save/relocate/dispatch/restore shape, but for FIQ's
  genuinely different register-banking — FIQ banks r8-r14, five more
  registers than IRQ's r13/r14 only, so only r0-r7 need staging/
  relocation; r8-r12 are read directly once SVC mode is entered) calls
  a new `timer_tick_dispatch()`, split out of the old combined
  `irq_dispatch` (which now handles only UART RX). A shared
  `scheduling_decision_prelude()` (irq_count, Gap B's shadow-check,
  task #241's deadline-miss detection) runs from both paths, since both
  independently drive real scheduling decisions. `#[interrupt(priority=
  0)]` (FIQ) / `#[interrupt(priority=1)]` (IRQ) on the two real ISR
  entry points, correctly DIFFERENT now (not both 0, which would have
  silently disabled vani's own S-20 pairwise priority-inversion checker
  between them — verified neither currently locks a shared mutex, but
  the numbers need to be honest regardless). FIQ's architectural
  guarantee (taking FIQ masks both further FIQ AND IRQ; taking IRQ
  masks only IRQ) meant every existing SVC-mode scheduler critical
  section needed re-auditing: 4 `cpsid i` sites in `context_switch.S`
  (`task_sleep_ticks`, `dhruva_mutex_lock`/`_unlock`, `task_create`)
  upgraded to `cpsid if`, and `irq_entry.S` gained its own `cpsid f` at
  entry, protecting its `scheduler_switch_from_irq` call from FIQ
  preemption (impossible before this change, since IRQ was previously
  the only active exception class).

  **Two real bugs found and fixed during implementation, both the kind
  this exact code class has produced before (round 68's true-lr bug,
  this same session's own earlier subagent incident: unverified
  assembly in this path, found broken, reverted)**: (1) a background
  research fork, asked only to verify the FIQ_CONTROL register layout,
  went beyond that brief and wrote `fiq_entry.S` directly — its file
  was missing the equivalent of `irq_entry.S`'s own `cps #0x12; add
  sp,sp,#64; cps #0x13` step that pops the staging area back off the
  IRQ stack; `fiq_entry.S` never popped its own 40-byte staging area
  off `sp_fiq`, which would have leaked 40 bytes per tick and walked
  off the 4KB `_fiq_stack_top` region within ~100 ticks — found by
  diffing every step against `irq_entry.S`'s real equivalent sequence,
  not by trusting the file's own "byte-for-byte identical" framing
  (true only for the tail, not the whole file), fixed before the first
  build. (2) The same fork's edit relocated `#[no_mangle]`/
  `#[interrupt(priority=0)]`/`#[bounded_stack]`/`#[wcet]` to the wrong
  function during the `irq_dispatch` split (attributes ended up on the
  new shared helper instead of the two real entry points) — caught
  immediately by the linker (`undefined reference to 'irq_dispatch'`/
  `'timer_tick_dispatch'`, since unmangled names are what the assembly
  calls), fixed by moving the attributes to the correct functions with
  correct, differentiated priority numbers (see above).

  **Verification**: builds clean, links clean, boots under QEMU with
  no crash/reboot, `phase4_milestone.py`'s full regression suite shows
  the exact same pre-existing 4-FAIL baseline (`httpecho`/`mqttecho`/
  `ls`/`diagnose`, all pre-existing `SETTLE_S`-class test-harness
  timing issues) with zero new regressions, and the log shows
  `task_mutex_demo_low`'s periodic "sleeping 5 ticks" message
  continuing to repeat throughout the run — live evidence the
  scheduler tick is genuinely advancing via the new FIQ path (not
  silently inert), and that the `sp_fiq` leak above does not manifest
  (would have crashed within seconds at this tick rate). **Not
  verified**: real Pi 1B hardware (this environment has no more RPi
  hardware available, per the project's own current strategic
  scoping) or real ARM1176JZF-S FIQ silicon behavior beyond what QEMU
  models — the same category of real-hardware-only risk this project
  already carries for Pi 4/5 USB/EMMC work, now also true here. The
  original 2026-09-18 investigation's caution about this exact code
  class was warranted and is why it took two full review passes
  (independent verification of a subagent's own register-banking
  claims, then independent verification of its actual diff before
  trusting it) before shipping, rather than one.
- **No measured/bounded worst-case interrupt latency.** Nothing in this
  project computes or asserts "an interrupt is serviced within N cycles of
  assertion, worst case."
- ~~**Watchdog-triggered recovery is deliberately disabled.** `irq_dispatch`'s
  own comment explains `watchdog_kick()` isn't actually called because doing
  so resets QEMU immediately, breaking the only test method this project
  has. Correct call for a dev/demo target; a genuine gap for anything meant
  to run unattended on real hardware, where a hung task should be
  recoverable without human intervention.~~ **`[WIRED, Gap F audit,
  2026-09-17]`** — `watchdog_kick()` is now called from `irq_dispatch`,
  gated behind `WATCHDOG_ENABLE_FOR_REAL_HARDWARE` (default 0, same gating
  pattern as `GUARD_PAGE_FAULT_INJECTION_TEST` — arming a real watchdog
  under QEMU would reset the VM mid-test, breaking every regression run).
  Real recovery mechanism exists and is source-verified, but its actual
  firing behavior is **not exercised by the normal QEMU regression suite**
  since it stays off there by design — only exercised on a real hardware
  build with the flag flipped. This is a genuinely different claim than
  "tested and works": it's "implemented, gated correctly, unverified in
  CI."
- **No per-thread execution-time supervision, only a system-wide
  watchdog.** The watchdog above is a single hardware timer covering the
  whole system — if ANY task keeps kicking it (even a wrong one, or one
  stuck in an infinite loop that still happens to call something that
  kicks it), a different task silently hanging forever goes undetected.
  CMSIS-RTOS2's "thread watchdog" pattern (a per-thread timeout, checked
  independently) is the standard reference design for this — see task
  #241 (runtime deadline-miss detection).

## 3. Memory / fault isolation gaps (the largest one)

- ~~**No per-task memory or stack protection.** Every task shares one flat
  address space with no MPU/MMU-enforced boundary around its own stack.
  This is not theoretical: **this exact session found a real stack overflow
  in a 512-byte task stack (`task_custom_demo`/`task_mutex_demo_low/high`,
  rounds 54/55) that went completely undetected until it silently corrupted
  adjacent memory and crashed somewhere else, minutes later, with a
  misleading, wandering fault address** (confirmed via a controlled
  experiment: shrinking the same stack further reproduced the identical
  crash class far faster — direct proof of the mechanism). A true RTOS (or
  even just a *robust* one) places a guard region immediately past every
  task's stack so an overflow faults **at the moment it happens**, with a
  clean diagnostic, not silently corrupting a neighbor. ARM1176JZF-S's MMU
  is already enabled and in active use here for W^X (round 38) — extending
  the existing page tables to add one no-access guard page per task stack
  is a concrete, buildable next step, not blocked on new hardware or a new
  subsystem.~~ **`[DONE, round 76, 2026-09-05]`** — the 1MB section
  covering `.data`/`.bss`/the heap/every task stack was converted from a
  flat section descriptor to a genuine second-level (coarse) page table
  (`boot/mmu_init.S`'s new `mmu_l2_table_data`, 256 x 4KB small-page
  descriptors) — ARMv6's short-descriptor format offers no finer boundary
  than a full 1MB section otherwise. A new `dhruva_alloc_stack_guarded`
  (`boot/rpi1/runtime_stubs.c`), used only for the 10 real task-stack
  allocations (not the hundreds of ordinary scratch-buffer calls), rounds
  up to the next real page boundary, reserves one full 4KB guard page,
  then allocates the actual stack immediately after — `mmu_guard_page_
  install` (`boot/mmu_init.S`) zeroes that one page's descriptor in the
  LIVE table at runtime (task stacks don't exist yet when `mmu_init`
  itself builds the table at boot) and invalidates just that page's TLB
  entry. Live-verified, not just written: a temporary (not committed)
  probe wrote 16 bytes below a fresh guarded allocation and took a real
  Data Abort — `status=0x807` (page-level translation fault, the
  zeroed/invalid descriptor doing its job) at exactly the guard page's
  own address, not a distant or wandering fault the way the original
  motivating bug's own crash was. Full regression battery
  (`phase4_milestone.py`, `heap_stress.py`, `power_yank.py`) clean,
  heap headroom still ~290KB despite the new per-stack guard-page
  overhead.
- ~~**No fault containment between tasks.** A bug in one task can freely
  corrupt another task's state or global kernel memory; there is no
  hardware boundary a task's own bug is contained by.~~ **`[DONE, round
  192, 2026-09-13]`** — ARMv6's 16 hardware domains map one-to-one onto
  this project's `MAX_TASKS=16`: domain 0 stays permanently Client
  (kernel/shared memory, unaffected), domains 1-15 map to task indices
  0-14, each with its own dedicated 1MB region and its own guard page
  (index 15 has no 16th domain, documented fallback). `scheduler_pick_
  next` writes a new DACR on every scheduling decision — only the
  picked task's own domain plus domain 0 are reachable, everything else
  takes a real Domain Fault. Live-verified, not just written: a
  temporary probe had task 0 write directly into task 8's own stack
  region and took a genuine, correctly-attributed Domain Fault (address,
  value, and domain all matching, `current_task=0` confirming the
  isolation direction was right). Two real bugs found and fixed along
  the way — a DACR-write-before-pop ordering bug and an i64/u32 AAPCS
  register-pairing mismatch that silently zeroed every task's own
  domain index — see commit `6538ae8` for the full story.

  **Honest limitation, not fixed by this**: protects each task's
  PRIVATE STACK only. A wild pointer can still corrupt another task's
  data if it lives in the shared domain-0 heap, which is most
  allocations today. Per-task heap arenas would be a much larger
  redesign, out of scope here.

- **CPU-privilege-level separation between tasks and the kernel --
  Phase 1+2 IMPLEMENTED 2026-09-18 (task #253, reopened and partially
  completed after the earlier investigation below had closed it as
  "documented, not implemented" -- the user explicitly asked to
  proceed despite the documented risk, same override that reopened
  task #246).** The original investigation's 3 findings below are
  still accurate background, but items 1-2 are now partially real
  code, not just analysis.

  **What's actually implemented (Phase 1+2):**
  1. **MMU permission rework (`boot/mmu_init.S`).** Every AP/APX
     encoding in the page table changed from privileged-only (AP=01)
     to full access at both privilege levels (AP=11) -- code sections
     stay APX=1 (genuinely read-only, now at BOTH levels, not just
     privileged -- the existing live-verified W^X guarantee is
     unchanged, just extended to cover unprivileged fetch too) rather
     than moving to APX=0. Domain-based cross-task isolation (round
     192) is completely unaffected -- it's checked BEFORE these bits
     ever matter, confirmed by re-running round 192's own domain-fault
     fault-injection test after this change with an identical result.
     A new temporary fault-injection self-test (matching this
     project's own round-38/round-192 precedent of a one-off live
     verification, not a permanently-committed test) confirmed both
     that a privileged write to the now-APX=1/AP=11 code section still
     faults, and that unprivileged fetch from the same section does
     NOT fault -- re-verifying the APX=1/AP=11 encoding fresh under
     the CURRENT SCTLR.XP=1 configuration, since the file's own header
     already documents an EARLIER test of this exact encoding that
     predates XP being set and says nothing about behavior under
     today's configuration.
  2. **task_d (IDLE) now runs in genuine ARM USR mode** -- the first
     task in this project's history to run unprivileged. New `is_usr_
     mode_task`/`usr_sp_table` per-task tables (`context_switch.S`):
     r13_usr/r14_usr are banked PER PROCESSOR MODE, not per task (one
     physical register pair shared by every USR-mode task), so every
     restore site that might resume a DIFFERENT task (`task_sleep_
     ticks`, `dhruva_mutex_lock`/`_unlock`, `irq_entry.S`, `fiq_
     entry.S`, `start_multitasking`) now calls a new shared `scheduler_
     restore_usr_sp` immediately before its own final restore -- a
     no-op for every still-SVC-mode task (everyone except IDLE today).
     `irq_entry.S`/`fiq_entry.S` also gained mode-aware CAPTURE logic:
     if the interrupted context was USR mode, `lr_svc` is NOT that
     task's true return address (SVC mode's own banked register,
     untouched by USR-mode execution) -- the real value lives in
     `lr_usr`, captured via the standard SYS-mode register-bank dip
     (`cps #0x1F`, shares r13/r14 with USR but stays privileged) that
     both files already used for a different purpose. New `dhruva_
     alloc_usrstack_domain` (`runtime_stubs.c`) gives IDLE a SEPARATE
     USR-mode stack inside its own existing 1MB domain (round 192),
     at a safely-separated offset from its existing SVC-side stack --
     both protected by the same domain isolation, no new cross-task
     exposure. IDLE specifically because it's the one task that calls
     none of the 65 real privileged call sites below, so it can run in
     genuine USR mode WITHOUT also needing a working SWI trap yet.

  **Real bug found and fixed during implementation, root cause
  corrected after further investigation (2026-09-18, same day):** the
  first attempt placed the new USR-stack-allocation vani code directly
  after `stack_d`'s own allocation, textually between it and `stack_e`/
  `stack_f`'s later allocations. The compiled result called `task_e_
  init_stack` with an argument register that still held `stack_a`'s
  own pointer (never reassigned) instead of `stack_e`'s -- confirmed by
  direct disassembly, not guessed: a live Data Abort at boot, `section
  permission fault`, at an address that arithmetically matched
  `stack_a`'s pointer + `stack_e_bytes`, an unmistakable register
  mixup. Fixed by relocating the new code to AFTER every task_X_init_
  stack call that reads stack_a/b/c/e/f (verified the fix by direct
  disassembly again before re-running QEMU, not just by the crash
  disappearing) -- this relocation fix stands, verified twice over via
  full pipeline rebuild + live QEMU regression.
  <br>Originally attributed to a vani-compiler register-allocation
  bug -- **that attribution was premature and is now corrected**: a
  follow-up investigation (prompted by the user directly asking to fix
  and push the vani-compiler bug before continuing) inspected the
  actual LLVM IR `vanic emit --backend=llvm` produced for the broken
  source and found it unambiguously correct, ordinary SSA -- the exact
  value from `stack_e`'s own allocation call, used directly as `task_e_
  init_stack`'s argument, no aliasing with `stack_a` anywhere in the
  IR (confirmed vani's own IR generation is deterministic across
  repeated runs on identical source, byte-identical output). Not a
  vani-compiler bug. Attempting to reproduce the actual llc-level
  misregistration in isolation (identical `.ll` by hash, identical
  `llc` version/flags/target, both the codebase's own default and
  explicit `-O2`) did NOT reproduce the mixup -- meaning even the
  "LLVM llc bug" half of the original finding couldn't be pinned to a
  concrete, reproducible root cause with the investigation time
  available. Left as a genuinely open, low-priority mystery (something
  about the full build pipeline's own state differs from the isolated
  retest in a way not yet identified) rather than a false, confident
  attribution to either vani-compiler or LLVM -- the shipped code-
  relocation fix is what actually matters here and is independently
  verified regardless of the unresolved root cause.

  **Verification:** builds clean, `phase4_milestone.py` shows the
  identical pre-existing 4-FAIL baseline with zero new regressions, no
  crash/reboot/Data Abort, and IDLE's own "idle" print appears 262
  times across the full regression log -- live confirmation it's
  genuinely executing its own body from USR mode repeatedly, not
  silently inert or crash-looping invisibly.

  **Phase 3 attempted, same day: real SWI syscall trap built, a real
  bug found and fixed in it, a SEPARATE bug found and left open, ended
  deliberately NOT wired into the live call graph.** `boot/swi_entry.S`
  now exists: a working SWI handler (dispatch on a syscall number in
  r7), per-task `usr_resume_spsr_table`/`usr_resume_pc_table` solving
  the SPSR_svc/lr_svc single-physical-register clobbering hazard
  exactly as designed, and three trampolines
  (`task_sleep_ticks_syscall`/`dhruva_mutex_lock_syscall`/`dhruva_
  mutex_unlock_syscall`) implementing the actual trap.

  **Real bug #1, found and FIXED (a genuine round-68-class true-lr/
  resume-pc conflation, not a compiler issue):** the first version of
  the trampolines took `swi` directly from whatever mode the caller was
  in. For a task that STAYS in SVC mode (every task except IDLE) taking
  an SWI exception reuses the SAME physical `lr_svc`/`SPSR_svc` the
  trampoline's own `bl`-based entry already occupied -- the CPU itself,
  as part of taking the exception, overwrites `lr_svc` with the SWI's
  own return address BEFORE any software could save the trampoline's
  real caller-return-address, permanently losing it. Invisible for
  IDLE (USR mode) because `lr_usr` is a genuinely separate banked
  register, untouched by an SVC exception -- which is exactly why this
  was missed until an SVC-mode caller (task_a-f) actually exercised the
  trap live. Fixed the same way `irq_entry.S`/`fiq_entry.S` already fix
  the identical class of problem: each trampoline stashes its own true
  `lr` into r4 (unbanked, survives the whole round trip in either mode)
  before the trap and restores it explicitly afterward -- `swi_entry`'s
  own entry-capture scratch usage had to move off r4 (was using it for
  spsr capture) onto r11 so it wouldn't clobber the trampoline's
  stashed value. Verified via live QEMU regression: fixing this alone
  took the system from "barely boots, almost every interactive test
  fails, SCHED SHADOW MISMATCH cascades, `idle` prints once" to "6 more
  tests pass (cat/eval/ping/ifconfig/tcpecho/udpecho/netstat), scheduler
  clearly healthy (HIGH/MUTEX-LOW/idle all printing normally, hundreds
  of times) -- a dramatic, unambiguous improvement.

  **Real bug #2, found, NOT yet fixed:** even with bug #1 fixed, the
  same regression run hit two later `FATAL: Data Abort`s -- one inside
  `sdhost_drain_ready` (SD driver) at a suspiciously low address
  (`0x00000004`, NULL-pointer-shaped), one inside `shell_dispatch` at a
  huge/wrapped address (`0xFFFFF437`, underflow-shaped) -- both well
  into the run (hundreds of real context switches in), in subsystems
  with no obvious direct connection to the SWI trap itself. Not chased
  to root cause in this pass: given the volume of investigation already
  spent this session (the true-lr bug above, plus the earlier,
  ultimately-not-vani-compiler register-mixup investigation on the
  full-USR-mode-conversion attempt -- see that item's own history
  immediately below), the honest, disciplined choice was to stop rather
  than keep pulling threads indefinitely.

  **Disposition: the trampolines are real, built, and have this one
  confirmed fix in them -- but are deliberately NOT wired into the live
  call graph.** `context_switch.S`'s own `task_sleep_ticks`/`dhruva_
  mutex_lock`/`dhruva_mutex_unlock` are back to their original names,
  called directly by every one of this project's ~65 existing call
  sites, byte-for-byte the same as the proven Phase 1/2 state -- Phase 3
  work is present in the tree (under the `_syscall`-suffixed inert
  names) but inactive. Re-verified after this revert: `phase4_
  milestone.py` matches the ORIGINAL Phase 1/2 baseline exactly (same
  4-FAIL set, zero `SCHED SHADOW MISMATCH`, `idle` printed 266 times,
  no crash) -- confirms the revert is genuinely clean, not just
  "probably fine."

  Also attempted, same day, as a separate, LARGER change before this
  narrower investigation: converting ALL 10 tasks (6 fixed + 4 dynamic)
  to USR mode simultaneously. That produced its own live crash
  (`section permission fault` inside `prepare_stack_common_usr`,
  `task_e_init_stack` receiving a value that traced back to `task_a`'s
  own pointer on direct disassembly) that was extensively investigated
  as a possible vani-compiler or LLVM `llc` register-allocation bug --
  the generated LLVM IR was confirmed correct/deterministic, an
  isolated `llc` re-test at the exact production flags did not
  reproduce it, and `-O1` (kept in `build.sh` regardless, harmless) did
  not fix it either. A live diagnostic print later showed the actual
  runtime values were CORRECT at the point of use, yet the crash still
  happened -- and, tellingly, adding that diagnostic print made the
  specific crash disappear, replaced by a different symptom (garbled
  UART output around dynamic task creation) at the same reduced-but-
  still-broken scale. In hindsight, once real bug #1 above (the true-lr
  conflation) was found and fixed, it's plausible -- though NOT
  directly re-tested at the full 10-task scale in this session -- that
  this was the SAME underlying bug manifesting differently under higher
  register/task-count pressure, not a separate compiler issue at all.
  Reverted to task_d-only USR mode (this item's own proven Phase 1/2
  scope) rather than re-attempted with the fix applied, given the
  investigation budget already spent.

  **Phase 3 RE-WIRED and CLOSED, 2026-09-19 (same day, "re-wire the
  trampolines and chase the SD/shell-dispatch bug and fix any other
  issues found").** Renamed the trampolines back to their real names
  and the real implementations back to `_impl`, exactly reversing the
  revert above -- then found and fixed three more real bugs before the
  trap was trustworthy at scale under `phase4_milestone.py`, each one
  confirmed (or ruled out) empirically by rebuilding and re-running the
  full regression suite after every change, not by static reasoning
  alone:

  1. `swi_entry.S` never masked FIQ across its own two SYS-mode
     register-bank dips (every other scheduler-critical-section entry
     point in this project does -- `cpsid if`/`cpsid f`), a real,
     live-reachable gap (`dhruva_mutex_lock`'s own fast path restores
     F=0 before returning through the dip) that also exposed a genuine,
     independent defect in `fiq_entry.S`'s own mode-check (recognizes
     USR but not SYS, a third mode only reachable via this exact dip).
     Fixed with `cpsid f` at `swi_entry`'s own top. Real and worth
     fixing, but tested alone it did NOT change the crash (`phase4_
     milestone.py` reproduced the identical SD-driver fault, confirming
     it was not the root cause before moving on -- exactly the kind of
     verification this project's "no trust, validate everything" habit
     is for).
  2. **The actual root cause of the SD-driver crash**: `swi_entry.S`
     used r5/r6/r8/r9/r11 as its own entry-capture scratch without
     saving them -- AAPCS callee-saved registers the trampolines never
     protected (only r4, the true-lr fix, was). Any live caller value
     in those registers across a `task_sleep_ticks`/`dhruva_mutex_
     lock`/`_unlock` call was silently destroyed, and for the blocking
     paths the ALREADY-corrupted values got captured into the task's
     own 68-byte frame and faithfully restored on wake -- separating
     the real corruption from its crash by many context switches,
     which is why the fault kept relocating to unrelated-looking code
     as later fixes let execution get further. Fixed by pushing/
     popping {r5,r6,r8,r9,r11} around the entry-capture bookkeeping,
     restored before the dispatch branch. Alone, this took `phase4_
     milestone.py` from 6 FAILs with 2 live `FATAL` Data Aborts to 3
     FAILs and zero crashes -- BETTER than the original 4-FAIL
     baseline.
  3. **The remaining crash**: the trampolines also clobbered r7 (also
     AAPCS callee-saved, carries the syscall number) without saving it
     -- `task_sleep_ticks`'s own `mov r7, #0` replaced any caller's own
     live r7 with a literal NULL, surfacing as `buf_write_byte` called
     with r0=0 from `dharafs_read_from_block_raw`. Fixed the same way
     as r4: `push {r4,r7}`/`pop {r4,r7}` in all three trampolines.

  **Verified clean**: `phase4_milestone.py` now matches the ORIGINAL
  Phase 1/2 baseline exactly (same 4-FAIL set, zero `FATAL`, zero
  `SCHED SHADOW MISMATCH`, `idle` printed 265 times) with the SWI trap
  genuinely wired in and exercised at full scale by every SVC-mode
  task, not reverted to inert.

  **`[DONE, task #262, 2026-09-20]`** -- the root cause blocking this
  (lr_usr, r14 in USR mode, never restored -- a single physical
  register shared by every USR-mode task, silently clobbered across
  context switches) was found and fixed (commit `f37d933`, verified
  against real Linux `arch/arm/kernel/entry-header.S`). All 10 tasks
  (6 static + 4 dynamic) now run in USR mode, each converted one at a
  time with its own dual `phase4_milestone.py` regression pass per
  this doc's own hard-won lesson above -- zero regressions, zero
  `FATAL` across every conversion (commits `7382f6b`..`00e84da`).

  Real Pi 1B hardware validation remains outstanding for this item
  (no hardware available in this environment) -- the same residual-
  risk category as task #246's own FIQ work and the Pi 4/5 "ON HOLD,
  no real HW" items.

## 4. Timing analysis / determinism gaps

- **`#[bounded_stack]`/`#[wcet]` are compile-time-only.** They produce a
  *static* estimate and reject a build that provably exceeds it — but
  nothing at runtime detects or traps an actual deadline miss or budget
  overrun. If a task's real execution time exceeds its declared WCET for any
  reason the static model didn't capture, there is no runtime safety net at
  all.
- ~~**The static model itself has a known, recently-found soundness gap.**
  `#[bounded_stack]`'s checker used to charge exactly 0 bytes for any
  `extern "C"` (hand-written assembly) callee — fixed this session
  (vani-compiler BUG-233) to a conservative nonzero default, but that's
  still an approximation, not a real per-function measured cost. A
  genuinely trustworthy WCET/stack story needs either real per-extern-fn
  cost annotations or a way to measure hand-written assembly's actual cost
  and feed it back into the checker — neither exists yet.~~ **`[COMPILER
  MECHANISM DONE, task #245, 2026-09-18]`** — vani-compiler now has
  `#[stack_cost(bytes=N)]`, a real per-extern-fn annotation the checker's
  call-graph walk consults before falling back to the flat default
  (vani-compiler commit `0eb25978`, 3 new tests, full suite 3033/3033).
  `vanic` rebuilt from this commit and DhruvaOS reverified against it:
  clean build, identical stack-depth report, same 4-FAIL regression
  baseline. **`[MEASUREMENT+ANNOTATION DONE, 2026-09-20, commit
  `396d626`]`** -- the real-measurement-plus-annotation pass this note
  called out as a genuine follow-up is done: every extern fn's real
  worst-case frame size measured mechanically from its own boot/*.S
  assembly (or from the 8 known zero-frame `*_SCRATCH_PAIR` accessor
  macros), 1138/1148 (99.1%) now carry a real `#[stack_cost(bytes=N)]`
  (10 remaining are C-implemented, boot-time-only allocator/host-disk
  stubs, left at the default). Real costs top out at 28 bytes anywhere
  in this codebase -- the flat 32-byte default was already a safe
  over-approximation everywhere, never an under-count, so this closes
  the gap as a precision/confidence improvement, not a correctness
  fix. One genuine, previously-undetected finding surfaced along the
  way (unrelated to the annotation imprecision itself, since the
  number was unchanged before/after): `task_fsq`'s real worst case
  (4152 bytes) exceeded its own raw 4096-byte stack allocation --
  `vanic stack-depth --entry=task_fsq` had simply never been run
  before (`build.sh` only auto-gates `kernel_main`, see this file's
  own §3 note on the same class of gap). Fixed by bumping `fsq_stack_
  bytes` to 16384, matching `task_e`/GC's own precedent for the same
  task profile.
- ~~**No deadline-miss detection or logging.**~~ **`[DONE, task #241]`**
  — `task_deadline_ticks_table`/`task_deadline_miss_count_table`
  (`boot/context_switch.S`) track a declared per-task deadline and
  increment a real miss counter, exposed via the `diagnose` shell
  command. Ties into `docs/TODO.md`'s own "Per-task runtime histograms
  + a real deadline/budget model" and "'Why is my task late' query"
  items, both still genuinely open (a full histogram/model on top of
  the counters that now exist, not duplicated here).

  **Partial step, `[round 189, 2026-09-12]`**: added the measurement
  primitive this will need, deliberately NOT the detection itself —
  `task_run_ticks_table` (`boot/context_switch.S`) counts, per task,
  one tick every time `scheduler_pick_next` picks it to run, exposed
  via `task_run_ticks_get_at(index)` and the shell's `diagnose` output
  (`task run-ticks (HIGH/MEDIUM/LOW/IDLE/GC/SHELL): ...`). This is real
  per-task CPU-time distribution data, useful on its own today (e.g.
  spotting a task starved far below what its priority should
  guarantee), but it is NOT deadline-miss detection: no task declares a
  budget anywhere yet, so there is nothing to compare this count
  against. That remains blocked on the same thing this item already
  said — a real declared per-task period/budget, which is also exactly
  what "formal schedulability analysis" (Phase C item 9 below) needs
  the same input for.

## 5. DharaFS-specific gaps

- ~~**`dharafs_compact()` has unbounded worst-case cost.** Its own main loop
  runs `while blk < old_next_block { dharafs_block_read(...); ... }` —
  confirmed by reading the function directly — meaning its cost scales
  with however much log has accumulated since the last compaction, with a
  real SD-card I/O operation on every iteration. `task_e` calls this every
  20 ticks (10 seconds) unconditionally. Nothing bounds how long a single
  pass can take, which directly undermines any WCET claim for whatever else
  is scheduled to run around it. The natural fix is to make compaction
  **resumable and per-call-bounded** (compact at most N blocks per
  invocation, picking up where the last call left off) rather than one
  unbounded pass.~~ **`[DONE, round 77, 2026-09-05]`** — added two
  persisted fields (`dharafs_compact_resume_block`/`_failed`,
  `boot/dharafs_state.S`) so a pass can span multiple calls: each call
  now scans at most `dharafs_compact_blocks_per_call()` (8) blocks,
  remembering exactly where to resume next time if it doesn't reach
  `next_block`. The underlying carry-forward logic needed no change to
  support this safely — it already re-derives "is this block still the
  current latest copy" fresh every time rather than working off a
  once-computed table, so a block already carried forward by an earlier
  partial call is simply found no-longer-latest and skipped harmlessly
  if a later call ever rescans it. The sticky `_failed` flag (distinct
  from the existing local `all_ok` a single call's own scan already
  used) carries a failure forward across resumed calls, so `log_start`
  still correctly refuses to advance even if the failure happened many
  calls before the pass finally finishes scanning the whole range.
  Live-verified with a new self-test (`dharafs_compact_resumable_
  self_test`): writes the same path 20 times (each write leaves the
  previous record dead, guaranteeing a >20-block range, well past the
  8-block budget), confirms the first call does NOT finish the pass
  and `log_start` does NOT yet reach its final target, keeps calling
  until it genuinely does, then confirms the file's own data is still
  byte-correct afterward. Full regression battery (`phase4_milestone
  .py`, `heap_stress.py`, `power_yank.py`) clean.
- ~~**No concurrency lock protecting DharaFS's own shared state.** Both
  `task_e` (the periodic GC/compact pass) and `task_f` (the interactive
  shell's read/write/rm/etc.) call into DharaFS, and nothing prevents a
  timer-tick preemption from interrupting one task's FS operation mid-update
  and resuming a *different* task's own FS call before the first one
  finishes. This is the exact same hazard class this project's own `netif`
  layer already found and explicitly self-tests for ("NETIF: shared-queue
  contention hazard reproduced as documented") — no analogous protection or
  even a documented-and-accepted-risk self-test exists yet for DharaFS. The
  existing priority-ceiling primitive (`dhruva_prio_lock`/`_unlock`) is
  already the right tool for this and would be cheap to apply here.~~
  **`[DONE, round 76, 2026-09-05]`** — a real THIRD contender was found
  while implementing this: `task_fsq` (the FS request queue dispatcher,
  round 67) also calls into DharaFS, at priority 2 — numerically higher
  than `task_e`/`task_f`'s shared priority 3. Wrapped all three call
  sites (`task_e`'s per-pass compact+read block, `task_f`'s single
  `shell_dispatch()` call — covering every shell command, not just the
  FS-touching ones, deliberately, so no future command can be missed —
  and `task_fsq`'s own drain loop) in `dhruva_prio_lock(2)`/
  `dhruva_prio_unlock(<caller's own true priority>)`, ceiling 2 being
  the highest real priority among the three, not either 3-priority
  task's own band. Live-verified, not just written: `task_e` now prints
  `current_eff_prio()` on entry/exit of its own critical section,
  confirmed live at `eff_prio=2` inside and `eff_prio=3` immediately
  after (`test/phase4_milestone.py`'s own captured boot log). Full
  regression battery (`phase4_milestone.py`, `heap_stress.py`,
  `power_yank.py`) clean, including the pre-existing MUTEX-LOW/HIGH
  ceiling-protocol demo (round 75's own scheduler-fairness fix) still
  behaving identically alongside this new lock usage.
- ~~**No priority- or deadline-aware I/O ordering.** Today, FS operations run
  in strict call order: a low-priority task's large write can delay a
  high-priority task's small, urgent one with no way to preempt or
  reorder.~~ **`[DONE, round 67, 2026-09-02]`** — this line was stale;
  `docs/TODO.md`'s own "Priority/deadline-aware FS request queue" entry
  already closed it well before this document was last touched.
  `boot/fsqueue_state.S` (8 fixed slots) + `dharafs_queue_submit_*` +
  `dharafs_queue_dispatch_one` (always dispatches the numerically lowest
  priority value, oldest-first among ties) + a dedicated background
  task (`task_fsq`) drain it. 34 host-harness checks cover it, including
  explicit priority-inversion-shaped ordering tests (a low-priority
  submit made FIRST is dispatched AFTER a high-priority one submitted
  later). Purely additive/opt-in — every existing synchronous
  `dharafs_*` call site is unaffected, so this doesn't retroactively
  make EVERY FS operation priority-ordered (a caller has to actually use
  the queue), which is the real remaining nuance, not "doesn't exist."
- ~~**No pre-reserved, guaranteed-bounded allocation path.** A hard-real-time
  filesystem generally wants a worst-case-bounded write path (e.g.
  pre-committed block regions for known-critical writers), not the current
  "scan the log, append, maybe compact" model, whose per-operation cost can
  vary with fragmentation and log state.~~ **`[DONE, task #244, 2026-09-18]`**
  -- narrower and more precisely locatable than this item's own original
  description: `dharafs_append_raw` was ALREADY fully bounded (pure
  sequential append, no scan) -- the real gap was that every PUBLIC
  entry point (`dharafs_append`, `dharafs_write_raw_checked`) wrapped it
  with a "preserve existing owner/mode" convenience lookup
  (`dharafs_stat`) that falls through to a genuinely unbounded linear
  scan on a directory-index miss (a real, reachable case: 256 fixed
  slots, not unlimited). New `dharafs_write_bounded(path, data,
  owner_uid, owner_gid, mode)` exposes the already-bounded primitive
  directly, requiring explicit metadata instead of auto-preserving it --
  real, provable cost: exactly `ceil(data_len/block_payload_cap)` SD
  block WRITES, zero SD reads, independent of log size/fragmentation.
  Verified by direct code inspection (the same discipline task #188's
  own SD worst-case-latency contract used) plus a live round-trip +
  explicit-metadata self-test (genuinely PASSES). Honest scope note:
  this is NOT "pre-committed block regions" in the strongest sense some
  hard-RT filesystems use (reserving specific blocks ahead of actual
  need) -- it closes the practical, reachable unbounded-cost risk in the
  existing write path, not a full pre-allocation redesign.
- ~~**SD command-level timeouts exist but aren't tied into a documented
  worst-case latency contract.** `sdhost_cmd_timed_out` already detects a
  hung command at the hardware-register level — a real, existing building
  block — but no one has computed or documented "a full read/write/compact
  call takes at most N ticks, worst case," the number an RTOS scheduling
  analysis would actually need.~~ **`[DOCUMENTED, 2026-09-12]`** — the
  real, code-enforced bound per `sdhost_cmd` call (`kernel_main.vani`)
  is its own software poll loop: 1,000,000 iterations of a single
  `SDCMD` MMIO read + `NEW_FLAG` check, confirmed by reading the
  function directly. SDTOUT (the SDHOST controller's own hardware
  timeout register, set to `0xF00000` = 15,728,640 SD-clock cycles in
  `sdhost_init`) is a strictly LARGER threshold, so it never actually
  fires in practice — the software poll always gives up first, by
  construction, matching the round-15 audit comment already in that
  code ("well before the hardware's own much-longer SDTOUT-based
  timeout would have fired").

  Per-operation command counts, each individually bounded by that same
  1,000,000-iteration cap:
  - `sdhost_read_block`/`sdhost_write_block`: exactly 1 `sdhost_cmd`
    call each (CMD17/CMD24).
  - One `dharafs_compact` call: up to `dharafs_compact_blocks_per_call()`
    (8) blocks scanned, each doing 1 read plus, if the record is still
    live and needs carrying forward, 1 write — **≤16 `sdhost_cmd` calls,
    worst case**, confirmed by reading `dharafs_compact`'s own scan loop
    directly (1 read always, 1 conditional write per block).

  **Deliberately NOT converted to an absolute time bound (ms/µs) here**:
  doing that honestly needs either a measured or a conservatively
  assumed per-iteration cost for `sdhost_cmd`'s poll body, and this
  project has no cycle counter wired up anywhere to measure it — the
  ARM1176's own PMCCNTR is never touched by this codebase. Presenting
  a specific millisecond figure without that would be false precision,
  not a real bound. What IS real and code-enforced today: **worst case,
  no single SD operation can wait more than
  (command count) × 1,000,000 poll iterations**, a genuine, verifiable
  ceiling — the still-open piece, if an absolute time bound is ever
  needed, is wiring up PMCCNTR (or an equivalent free-running counter)
  to measure that iteration's real cost once, not a new architectural
  gap.

## Suggested phasing (cheapest/highest-value first, not a commitment)

**Phase A — cheap, mechanical, no new subsystem:**
1. ~~Fix `scheduler_pick_next`'s tie-breaking to rotate fairly among
   equal-priority ready tasks instead of always favoring the lowest
   index.~~ `[DONE, round 75]` — see item 1 above.
2. ~~Wrap DharaFS's own shared-state mutations in the existing
   `dhruva_prio_lock`/`_unlock` ceiling protocol, closing the concurrency
   hazard described above.~~ `[DONE, round 76]` — see "DharaFS-specific
   gaps" above.
3. Document (and self-test, matching the netif precedent) whichever of the
   above isn't fixed outright, so it's a tracked, accepted risk rather than
   an unknown one.

**Phase B — medium, builds on what already exists:**
4. ~~Per-task stack guard pages via the existing MMU (directly motivated by
   this session's own real stack-overflow bug) — the single highest-value
   fault-isolation improvement available without new hardware.~~
   `[DONE, round 76]` — see "Memory / fault isolation gaps" above.
5. ~~Bound `dharafs_compact`'s per-call work (resumable, N-blocks-per-call).~~
   `[DONE, round 77]` — see "DharaFS-specific gaps" above.
6. Runtime deadline-miss counters, feeding the already-planned per-task
   histogram/deadline-model TODO item.

**Phase C — larger, some blocked on real hardware or real workloads:**
7. ~~Tickless or higher-resolution timer.~~ **`[BOTH RESOLVED, 2026-09-
   18, neither implemented]`** — split into task #243 (re-attempted with
   real measurement: per-tick dispatch cost is negligible, tick period
   unchanged, real cause is tick-count-expressed protocol durations) and
   task #247 (tickless evaluated on that same evidence and deliberately
   not implemented — see "500ms tick granularity" above for the full
   finding on both).
8. ~~A real interrupt-priority scheme (needs BCM2835's fuller interrupt
   controller capability wired up, not just the two pending-bit checks used
   today)~~ **`[DONE, 2026-09-18]`** — task #246, see "Interrupt handling
   gaps" above: the timer tick is now genuinely FIQ-routed, preempting
   in-progress IRQ-level work (UART RX), QEMU-verified with no
   regressions; real Pi 1B hardware validation still outstanding (no
   hardware available in this environment).
9. ~~Formal schedulability analysis tooling (utilization bound / response-time
   analysis) over the declared task set.~~ **`[DONE, tool: round 190;
   applied to DhruvaOS's own real task set: Gap C/226, 2026-09-17]`** —
   see item 4 above ("No formal schedulability analysis"). Context-switch
   overhead as a modeled term remains open — task #240.
10. ~~Close BUG-233's remaining gap: real per-extern-fn stack-cost
    annotations instead of a conservative constant~~ **`[COMPILER
    MECHANISM DONE, 2026-09-18]`** — task #245 (vani-compiler repo).
    Applying real measured annotations to DhruvaOS's own extern fns
    remains open, see "Timing analysis / determinism gaps" above.
11. ~~Watchdog-triggered recovery for a real (non-QEMU) deployment
    target.~~ **`[WIRED, Gap F audit, 2026-09-17]`** — see "Interrupt
    handling gaps" above; implemented and gated, not yet exercised by CI.
    Per-thread execution-time supervision (distinct from the system-wide
    watchdog) remains open — task #241.

**Post-2026-09-18 additions, from a direct "what qualifies as a true
RTOS" pass against external references** (NASA RTOS-101, priority-ceiling
protocol literature, CMSIS-RTOS2's thread-watchdog/MPU-zone model): two
gaps this document didn't previously name at all —
12. Runtime deadline-miss detection with declared per-task budgets
    (task #241) — `task_run_ticks_table` (round 189) has the raw data but
    nothing declares a budget to compare it against yet.
13. Aperiodic/sporadic server budget for UART RX interrupt-triggered work
    (task #242) — currently unbudgeted against any task's own time
    allowance, a real gap in the schedulability model's own completeness.
14. ~~Pre-reserved bounded-allocation write path for DharaFS (task #244)~~
    **`[DONE, 2026-09-18]`** — see "DharaFS-specific gaps" above, item
    "No pre-reserved, guaranteed-bounded allocation path."

See `docs/TODO.md` for the items above that already have their own tracked
entry (per-task histograms/deadline model, "why is my task late", FS
priority queue) — this document exists to name the gaps that *aren't*
tracked yet and to give the already-tracked ones the concrete "why this
matters" grounding found while investigating this session's own real
stack-overflow bug. Current status of every numbered item above is
cross-checked against the task tracker (#239-247) as of 2026-09-18, not
just this document's own prose — see `docs/TODO.md`'s Gap A-F closure
entries for the full verification detail behind each `[DONE]` marker.
