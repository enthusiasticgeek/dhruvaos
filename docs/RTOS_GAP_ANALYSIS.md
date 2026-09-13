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

  A white-box self-test calling `scheduler_pick_next` directly against
  controlled table state was attempted and abandoned after it triggered a
  real, only partially root-caused crash (see `boot/context_switch.S`'s
  own comment on `scheduler_pick_next`, right above the function, for the
  full incident and warning for any future attempt) — the algorithm fix
  itself was independently verified via the live regression above instead,
  judged safer than shipping a self-test that could crash the system.
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
- **No formal schedulability analysis.** Priorities are hand-assigned; there
  is no tool computing a utilization bound (rate-monotonic) or running a
  response-time analysis across the declared task set's periods/WCETs.
  `#[wcet(cycles=N)]` bounds a single function's cost — nothing ties that
  into "is this whole task set actually schedulable."
- **No aperiodic/sporadic server.** Interrupt-triggered, non-periodic work
  (e.g. UART RX) runs directly in `irq_dispatch`, not budgeted against any
  task's own time allowance.

## 2. Interrupt handling gaps

- **One flat interrupt priority level.** `irq_dispatch` (`kernel_main.vani`)
  checks the timer-tick pending bit, then the UART RX pending bit, in a
  single non-nested, non-prioritized sequence — confirmed by reading the
  function directly. There is no interrupt controller priority scheme: a
  lower-importance interrupt source can never be preempted by a
  higher-importance one arriving mid-handler, because there is only one
  handler and it runs to completion regardless of what arrives next. A true
  RTOS on real hardware with a real interrupt controller (BCM2835's own is
  more capable than what's wired up here) would assign interrupt priorities
  that mirror task priorities.
- **No measured/bounded worst-case interrupt latency.** Nothing in this
  project computes or asserts "an interrupt is serviced within N cycles of
  assertion, worst case."
- **Watchdog-triggered recovery is deliberately disabled.** `irq_dispatch`'s
  own comment explains `watchdog_kick()` isn't actually called because doing
  so resets QEMU immediately, breaking the only test method this project
  has. Correct call for a dev/demo target; a genuine gap for anything meant
  to run unattended on real hardware, where a hung task should be
  recoverable without human intervention.

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
- **No fault containment between tasks.** A bug in one task can freely
  corrupt another task's state or global kernel memory; there is no
  hardware boundary a task's own bug is contained by.

## 4. Timing analysis / determinism gaps

- **`#[bounded_stack]`/`#[wcet]` are compile-time-only.** They produce a
  *static* estimate and reject a build that provably exceeds it — but
  nothing at runtime detects or traps an actual deadline miss or budget
  overrun. If a task's real execution time exceeds its declared WCET for any
  reason the static model didn't capture, there is no runtime safety net at
  all.
- **The static model itself has a known, recently-found soundness gap.**
  `#[bounded_stack]`'s checker used to charge exactly 0 bytes for any
  `extern "C"` (hand-written assembly) callee — fixed this session
  (vani-compiler BUG-233) to a conservative nonzero default, but that's
  still an approximation, not a real per-function measured cost. A
  genuinely trustworthy WCET/stack story needs either real per-extern-fn
  cost annotations or a way to measure hand-written assembly's actual cost
  and feed it back into the checker — neither exists yet.
- **No deadline-miss detection or logging.** Ties directly into
  `docs/TODO.md`'s own already-open "Per-task runtime histograms + a real
  deadline/budget model" and "'Why is my task late' query" items — both
  correctly scoped there as not-yet-started and blocked on a real workload
  to make the numbers meaningful, not duplicated here.

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
- **No priority- or deadline-aware I/O ordering** (already an open,
  correctly-scoped `docs/TODO.md` item — "Priority/deadline-aware FS request
  queue"). Today, FS operations run in strict call order: a low-priority
  task's large write can delay a high-priority task's small, urgent one with
  no way to preempt or reorder.
- **No pre-reserved, guaranteed-bounded allocation path.** A hard-real-time
  filesystem generally wants a worst-case-bounded write path (e.g.
  pre-committed block regions for known-critical writers), not the current
  "scan the log, append, maybe compact" model, whose per-operation cost can
  vary with fragmentation and log state.
- **SD command-level timeouts exist but aren't tied into a documented
  worst-case latency contract.** `sdhost_cmd_timed_out` already detects a
  hung command at the hardware-register level — a real, existing building
  block — but no one has computed or documented "a full read/write/compact
  call takes at most N ticks, worst case," the number an RTOS scheduling
  analysis would actually need.

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
7. Tickless or higher-resolution timer.
8. A real interrupt-priority scheme (needs BCM2835's fuller interrupt
   controller capability wired up, not just the two pending-bit checks used
   today).
9. Formal schedulability analysis tooling (utilization bound / response-time
   analysis) over the declared task set.
10. Close BUG-233's remaining gap: real per-extern-fn stack-cost annotations
    instead of a conservative constant.
11. Watchdog-triggered recovery for a real (non-QEMU) deployment target.

See `docs/TODO.md` for the items above that already have their own tracked
entry (per-task histograms/deadline model, "why is my task late", FS
priority queue) — this document exists to name the gaps that *aren't*
tracked yet (scheduler fairness, DharaFS concurrency, per-task memory
protection, bounded compaction) and to give the already-tracked ones the
concrete "why this matters" grounding found while investigating this
session's own real stack-overflow bug.
