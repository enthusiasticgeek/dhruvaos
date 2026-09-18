#!/usr/bin/env python3
"""Task #190 (docs/RTOS_GAP_ANALYSIS.md, "No formal schedulability
analysis"): a real utilization-bound (Liu & Layland) and exact
response-time analysis (Joseph & Pandya) checker for a fixed-priority,
periodic task set -- the piece #[wcet(cycles=N)] alone was always
missing (it bounds one function's own cost, not "is the whole task
set actually schedulable").

Deliberately NOT applied to DhruvaOS's own current demo task set
(HIGH/MEDIUM/LOW/etc., kernel_main.vani) in this file. That set has no
declared WCET anywhere -- #[wcet(cycles=N)] exists on exactly one
function in the whole project (irq_dispatch, an interrupt handler, not
a task), and every demo task body calls the BLOCKING uart_puts (not
the WCET-safe uart_putc_nonblocking irq_dispatch itself uses
specifically to stay analyzable), so it likely couldn't even pass a
real WCET check without first being rewritten. docs/TODO.md's own
"Per-task runtime histograms + a real deadline/budget model" entry
already made this exact call for the sibling deadline-detection
problem: "assigning them an invented budget... would be fabricating a
number, not observing one, and actively misleading." The same
reasoning applies here -- this tool is validated against real, known
worked examples instead (see main() below), and is meant to be pointed
at DhruvaOS's own task set the round a real timing-constrained task
(a genuine sensor poll loop, a real network deadline) actually needs
it, per that same TODO entry's own "build it when a real workload
exists" plan.

Usage as a library:
    from schedulability_analysis import Task, utilization_bound_ok, response_time_analysis
    tasks = [Task("A", priority=0, period=10, wcet=3), ...]
    ok, bound = utilization_bound_ok(tasks)
    results = response_time_analysis(tasks)  # {name: (response_time, meets_deadline)}

Run directly to execute this file's own correctness self-tests against
known textbook examples (not DhruvaOS-specific):
    python3 test/schedulability_analysis.py
"""
from dataclasses import dataclass
from math import ceil


@dataclass
class Task:
    name: str
    priority: int   # lower number = higher priority, matching this
                     # project's own convention (eff_prio_table etc.)
    period: float    # T_i
    wcet: float      # C_i, worst-case execution time
    deadline: float = None  # D_i; defaults to period (implicit-deadline model)
    blocking: float = 0.0  # B_i -- ROUND 2026-09-17 (RTOS/DharaFS safety-
                     # certification audit) addition: worst-case time this
                     # task can be blocked by a LOWER-priority task holding
                     # a resource whose priority-ceiling/inherited priority
                     # is >= this task's own priority. The original tool
                     # (task #190) deliberately covered only pure fixed-
                     # priority preemptive interference (Joseph & Pandya
                     # 1986) -- correct for a task set with no shared
                     # resources, but DhruvaOS's own scheduler is built
                     # specifically AROUND priority-ceiling/inheritance
                     # locking (dhruva_prio_lock/dhruva_mutex_lock,
                     # boot/context_switch.S), so any real application of
                     # this tool to DhruvaOS's own task set without a
                     # blocking term would silently ignore exactly the
                     # mechanism this RTOS's own scheduler exists to
                     # demonstrate. Standard extension (Sha/Rajkumar/
                     # Lehoczky 1990, "Priority Inheritance Protocols":
                     # An Approach to Real-Time Synchronization" -- the
                     # same "at most one lower-priority critical section"
                     # bound both dhruva_prio_lock's ceiling protocol and
                     # dhruva_mutex_lock's inheritance protocol are
                     # designed to guarantee): R_i = C_i + B_i +
                     # sum_{j in hp(i)} ceil(R_i/T_j)*C_j -- see
                     # response_time_analysis below for where this is
                     # actually added in.

    def __post_init__(self):
        if self.deadline is None:
            self.deadline = self.period
        if self.wcet <= 0:
            raise ValueError(f"{self.name}: wcet must be positive")
        if self.period <= 0:
            raise ValueError(f"{self.name}: period must be positive")
        if self.blocking < 0:
            raise ValueError(f"{self.name}: blocking cannot be negative")
        if self.wcet > self.deadline:
            raise ValueError(f"{self.name}: wcet ({self.wcet}) exceeds its own deadline ({self.deadline}) -- cannot ever meet it even alone")


def utilization_bound_ok(tasks: list[Task]) -> tuple[bool, float]:
    """Liu & Layland (1973) sufficient-but-not-necessary RM schedulability
    bound: sum(C_i/T_i) <= n(2^(1/n) - 1). Returns (passes_bound, total_
    utilization). A True result guarantees schedulability; a False result
    does NOT prove unschedulability -- exact response_time_analysis below
    is the only sound way to determine that (this is the textbook reason
    exact analysis exists at all, not a redundant second check)."""
    n = len(tasks)
    if n == 0:
        return True, 0.0
    utilization = sum(t.wcet / t.period for t in tasks)
    bound = n * (2 ** (1.0 / n) - 1)
    return utilization <= bound, utilization


def response_time_analysis(tasks: list[Task]) -> dict[str, tuple[float, bool]]:
    """Exact fixed-priority response-time analysis (Joseph & Pandya,
    1986), extended with a blocking term (Sha/Rajkumar/Lehoczky 1990) for
    priority-ceiling/inheritance-protected critical sections. For each
    task i, iterates the fixed-point recurrence
        R_i^(0) = C_i + B_i
        R_i^(k+1) = C_i + B_i + sum_{j in hp(i)} ceil(R_i^(k) / T_j) * C_j
    until it converges (R_i^(k+1) == R_i^(k)) or exceeds D_i (provably
    unschedulable, no point iterating further -- the recurrence is
    monotonically non-decreasing, so once it passes the deadline it
    can only get worse). hp(i) = every task with priority number
    STRICTLY LESS than task i's own (this project's own "0 is highest"
    convention, matching eff_prio_table throughout context_switch.S).
    B_i defaults to 0 (pure Joseph & Pandya, no shared resources) --
    only load-bearing when the caller has actually supplied a real,
    measured worst-case blocking time for a task set that uses
    dhruva_prio_lock/dhruva_mutex_lock.

    Returns {task_name: (response_time_or_None, meets_deadline)} --
    response_time is None if the iteration was aborted early because it
    already exceeded the deadline (the exact overshoot value isn't
    meaningful once that's already been decided)."""
    results = {}
    for i, task in enumerate(tasks):
        higher_priority = [t for t in tasks if t.priority < task.priority]
        r = task.wcet + task.blocking
        while True:
            interference = sum(ceil(r / hp.period) * hp.wcet for hp in higher_priority)
            r_next = task.wcet + task.blocking + interference
            if r_next > task.deadline:
                results[task.name] = (None, False)
                break
            if r_next == r:
                results[task.name] = (r, True)
                break
            r = r_next
    return results


def _assert_close(actual, expected, tol=1e-9, msg=""):
    if abs(actual - expected) > tol:
        raise AssertionError(f"{msg}: expected {expected}, got {actual}")


def main() -> int:
    """Correctness self-test against known, worked examples -- the
    "live-verified, not just written" bar this project holds every
    other feature to, applied to a pure host-side analysis tool: these
    numbers are independently checkable by hand against the textbook
    formulas above, not just "the code ran without crashing"."""
    all_ok = True

    # Example 1: classic 3-task set where the Liu&Layland BOUND fails
    # (a false negative for the sufficient-only test) but EXACT RTA
    # proves the set is actually schedulable -- this is the textbook
    # motivating example for why exact analysis exists at all, not a
    # redundant second check. T=(4,5,20), C=(1,1,4), utilization =
    # 1/4+1/5+4/20 = 0.25+0.2+0.2 = 0.65; 3-task bound =
    # 3*(2^(1/3)-1) ≈ 0.7798 -- 0.65 < 0.7798, so this particular set
    # actually PASSES the bound too; use a tighter set to force a bound
    # failure while still being exactly schedulable.
    # T=(4,5,20), C=(1,2,4): U = 0.25+0.4+0.2 = 0.85 > 0.7798 (bound
    # fails) but exact RTA: R_A=1 (no higher prio, C=1, <=4 OK).
    # R_B: r=2; interference=ceil(2/4)*1=1; r=3; ceil(3/4)*1=1; r=3
    # converged; 3<=5 OK. R_C: r=4; ceil(4/4)*1+ceil(4/5)*2=1+2=3; r=7;
    # ceil(7/4)*1+ceil(7/5)*2=2+4=6; r=10; ceil(10/4)*1+ceil(10/5)*2=3+4=7;
    # r=11; ceil(11/4)*1+ceil(11/5)*2=3+6=9; r=13;
    # ceil(13/4)*1+ceil(13/5)*2=4+6=10; r=14;
    # ceil(14/4)*1+ceil(14/5)*2=4+6=10; r=14 converged; 14<=20 OK.
    tasks1 = [
        Task("A", priority=0, period=4, wcet=1),
        Task("B", priority=1, period=5, wcet=2),
        Task("C", priority=2, period=20, wcet=4),
    ]
    bound_ok1, util1 = utilization_bound_ok(tasks1)
    _assert_close(util1, 0.85, msg="Example 1 utilization")
    if bound_ok1:
        print("[FAIL] Example 1: expected the sufficient bound to fail here")
        all_ok = False
    else:
        print(f"[PASS] Example 1: utilization bound correctly fails (U={util1:.4f} > bound)")

    rta1 = response_time_analysis(tasks1)
    expected1 = {"A": (1, True), "B": (3, True), "C": (14, True)}
    if rta1 != expected1:
        print(f"[FAIL] Example 1 exact RTA: expected {expected1}, got {rta1}")
        all_ok = False
    else:
        print(f"[PASS] Example 1 exact RTA correctly proves schedulable despite the bound failing: {rta1}")

    # Example 2: a genuinely UNSCHEDULABLE set -- lowest-priority task's
    # own WCET already exceeds what's left after higher-priority
    # interference. T=(2,5), C=(1,4): A always preempts every 2 ticks;
    # B needs 4 ticks of C but only gets non-A time, and its own
    # deadline (5) can't absorb enough of A's interference.
    # R_B: r=4; interference=ceil(4/2)*1=2; r=6>5 -> fails.
    tasks2 = [
        Task("A", priority=0, period=2, wcet=1),
        Task("B", priority=1, period=5, wcet=4),
    ]
    rta2 = response_time_analysis(tasks2)
    if rta2["B"][1] is not False or rta2["B"][0] is not None:
        print(f"[FAIL] Example 2: expected B to be provably unschedulable, got {rta2}")
        all_ok = False
    else:
        print(f"[PASS] Example 2 exact RTA correctly proves B unschedulable: {rta2}")

    # Example 3: trivial single task, always schedulable if C<=D.
    tasks3 = [Task("Solo", priority=0, period=10, wcet=10)]
    rta3 = response_time_analysis(tasks3)
    if rta3["Solo"] != (10, True):
        print(f"[FAIL] Example 3: expected exactly (10, True), got {rta3}")
        all_ok = False
    else:
        print(f"[PASS] Example 3 (trivial single task, C==D): {rta3}")

    # Example 4: explicit deadline tighter than period (constrained-
    # deadline model, not just implicit-deadline) -- proves the
    # `deadline` field is actually load-bearing, not silently ignored.
    tasks4 = [
        Task("A", priority=0, period=10, wcet=2),
        Task("B", priority=1, period=10, wcet=3, deadline=4),  # too tight
    ]
    rta4 = response_time_analysis(tasks4)
    if rta4["B"][1] is not False:
        print(f"[FAIL] Example 4: expected B's own tight deadline (4) to fail, got {rta4}")
        all_ok = False
    else:
        print(f"[PASS] Example 4 correctly honors an explicit deadline tighter than period: {rta4}")

    # Example 5 (ROUND 2026-09-17, blocking-term extension): a task
    # that's trivially schedulable with C alone (R=2<=6) becomes
    # provably UNSCHEDULABLE once a real blocking term is added -- the
    # exact scenario dhruva_prio_lock's own ceiling protocol produces
    # for any task sharing a ceiling with a long-held lower-priority
    # critical section. Top priority (0), so no interference term at
    # all -- isolates the blocking term as the only thing that changed
    # between the two checks.
    tasks5 = [Task("A", priority=0, period=6, wcet=2, blocking=5)]
    rta5 = response_time_analysis(tasks5)
    if rta5["A"][1] is not False:
        print(f"[FAIL] Example 5: expected blocking (5) + wcet (2) > deadline (6) to fail, got {rta5}")
        all_ok = False
    else:
        print(f"[PASS] Example 5 blocking term correctly flips an otherwise-schedulable task to unschedulable: {rta5}")
        tasks5b = [Task("A", priority=0, period=6, wcet=2, blocking=0)]
        rta5b = response_time_analysis(tasks5b)
        if rta5b["A"] != (2, True):
            print(f"[FAIL] Example 5 control (blocking=0): expected (2, True), got {rta5b}")
            all_ok = False
        else:
            print(f"[PASS] Example 5 control (blocking=0) confirms the SAME task set is fine without it: {rta5b}")

    print()
    if all_ok:
        print("ALL SELF-TESTS PASS")
        return 0
    else:
        print("SOME SELF-TESTS FAILED")
        return 1


def dhruvaos_demo_task_set_analysis() -> int:
    """ROUND 2026-09-17 (RTOS/DharaFS safety-certification audit, user
    request: "simulate workload if possible to test... wcet analysis").
    This tool (task #190) was correctly never applied to DhruvaOS's own
    demo task set before now (see this file's own header comment) --
    it had no WCET data to apply. This closes that gap with REAL,
    MEASURED numbers, not invented ones, for the one figure that
    actually matters most: task_c (LOW)'s own delay(3000000) busy-wait,
    held across a dhruva_prio_lock(0) ceiling-0 critical section --
    measured live under QEMU via a new permanent boot-time diagnostic
    (kernel_main.vani's delay_wcet_measure_self_test, TIMER_CLO-based,
    a real 1MHz hardware counter) at 49906us (~50ms). Ceiling 0 means
    this blocks EVERY other task in the system for that whole window,
    by design -- not a resource-specific block like a mutex, the whole
    point of the ceiling protocol's own "prevent inversion by
    construction" guarantee (see context_switch.S's own file header).

    The rest of each task body's own WCET (a handful of uart_puts calls
    plus lock/unlock bookkeeping) is NOT independently measured to the
    same precision -- conservatively rounded up to 5ms per task here,
    labeled as such rather than presented as equally rigorous. This
    tool's own job is to show whether the DOMINANT, MEASURED cost
    (the 50ms critical section) keeps the real demo task set
    schedulable against its own real periods (task_sleep_ticks counts x
    scheduler_tick_interval_us = 500ms/tick) -- it does, comfortably,
    but the margin is worth seeing in real numbers, not just asserted.

    ROUND 2026-09-17 follow-up (gap #237): LOW's own B_LOW was
    previously left at 0 with an explicit "unmeasured" caveat -- GC
    (task_e) holds TWO separate ceiling-2 critical sections (DharaFS
    compaction, and a dhcp_client_poll that reaches into the real netif
    receive path), and LOW's own true priority (2) exactly matches that
    ceiling, so scheduler_pick_next's own tie-break rule (ties favor the
    incumbent when the incumbent is ceiling-boosted) means LOW genuinely
    CAN be blocked by whichever one GC happens to be running. Both are
    now measured live, every real pass, via kernel_main.vani's own
    task_e print lines: DharaFS compaction measured 5741-7689us across
    10 real passes in one test run (consistently small); the DHCP poll
    measured mostly 12-478us under HEALTHY conditions (a working
    virtual network, lease already held) -- but that poll's own real
    worst case is NOT the healthy-path number: it calls into
    dwc2_net_bulk_in, which used to call the SAME shared USB polling
    primitive measured elsewhere at up to 325620us (~325ms) if the link
    genuinely stalls. A rigorous WCET bound has to assume the
    pessimistic case can happen, not just what one test run observed --
    so B_LOW uses a worst-case figure, not the smaller healthy-path
    average, exactly the same "don't trust the optimistic number"
    discipline this audit's own delay()/dwc2 measurements were built on
    in the first place.

    ROUND 2026-09-17 follow-up (gap #238): that 325ms figure was itself
    closed, not just documented, once traced to its real cause --
    dwc2_net_bulk_in (the only caller of the USB polling primitive
    reachable from netif_recv_frame, and therefore from this exact DHCP
    poll and from ssh_real_accept/_deliver_one_frame's own ceiling-2
    lock) has exactly one caller-family, and every one of THOSE callers
    is already a speculative "is a frame ready" poll with its own
    retry-on-nothing-ready contract -- never a "this transfer MUST
    complete" case the way a control transfer or a WiFi/BLE bulk
    transfer is. Gave it its own much shorter poll cap
    (NET_BULK_IN_POLL_CAP=20000 in kernel_main.vani, vs. the shared
    1000000-iteration cap every other USB transfer class still uses
    unchanged) via a new dwc2_wait_chan0_done_bounded sibling function,
    not a change to the shared primitive itself. Real measured new
    worst case (dwc2_net_bulk_in_poll_wcet_measure_self_test, same "no
    device attached, guaranteed full timeout" real-worst-case
    methodology as the original 325620us figure): 6584us (~6.6ms) --
    a ~48x reduction, not a guessed one."""
    MS = 1.0  # working in milliseconds throughout
    TICK_MS = 500.0  # scheduler_tick_interval_us() = 500000us = 500ms

    measured_low_critical_section_ms = 49.906  # delay(3000000), TIMER_CLO-measured
    other_body_estimate_ms = 5.0  # conservative, NOT independently measured
    # ROUND 2026-09-18 (RTOS true-compliance pass, task #240): real
    # measured context-switch/mutex-handoff overhead -- see kernel_
    # main.vani's task_mutex_demo_low/high_wake_body (mutex_handoff_
    # t0/mutex_handoff_worst_us in context_switch.S). "Fixed-time task
    # switching" is a standard RTOS-qualifying property this model
    # previously left completely unmodeled -- a real, honest gap
    # RTOS_GAP_ANALYSIS.md now names. Measured live under QEMU (worst
    # case 182us across a full phase4_milestone.py run, steady-state
    # 14-30us) via the existing MUTEX-LOW/HIGH demo pair's own real
    # unlock-to-running latency (covers the priority-inheritance wake
    # path + scheduler_pick_next + register restore -- the real
    # mechanical cost of one real handoff, not a synthetic benchmark).
    # Folded into every task's own WCET once (the standard simplified
    # RTA treatment: each activation implies being switched INTO,
    # whether via a tick-driven preemption decision or a direct
    # mutex/ceiling handoff) -- conservative given the actual per-tick
    # scheduler_pick_next cost (no mutex handoff involved) is smaller
    # and unmeasured on its own, and this demo set's dominant terms
    # (49.9ms/7.7ms/6.6ms) dwarf it regardless. QEMU-measured, not
    # confirmed identical to real Pi 1B hardware timing (same caveat
    # as every other TIMER_CLO measurement in this codebase).
    measured_ctxsw_handoff_ms = 0.182
    # GC's own two ceiling-2 critical sections -- see this function's
    # own header for why the DHCP-poll one uses a real worst-case
    # figure (12-478us was only ever the healthy-path average across 10
    # real passes in one test run). B_LOW is the larger of the two --
    # LOW blocks on whichever one is in progress when it becomes ready,
    # not both at once (they're separated by a real dhruva_prio_
    # unlock(3)/dhruva_prio_lock(2) pair in task_e's own body, a
    # genuine window where LOW, at priority 2, can preempt GC back at
    # its own true priority 3 normally).
    gc_dharafs_critical_section_ms = 7.689  # measured max, 10 real passes
    # ROUND 2026-09-17 (gap #238): was 325.62ms (dwc2_wait_chan0_done's
    # own shared-primitive worst case) -- now the real measured worst
    # case of dwc2_net_bulk_in_poll_wcet_measure_self_test's own
    # NET_BULK_IN_POLL_CAP-bounded poll, ~48x smaller, not a guess.
    gc_dhcp_poll_worst_case_ms = 6.584
    gc_worst_blocking_ms = max(gc_dharafs_critical_section_ms, gc_dhcp_poll_worst_case_ms)

    tasks = [
        # HIGH (task_a): sleeps 3 ticks, priority 0. Own body has no
        # busy-wait -- its own WCET is the "other_body_estimate" only.
        # Blocked by LOW's ceiling-0 critical section whenever it lands
        # inside one (ties favor the incumbent at equal boosted
        # priority -- see context_switch.S's own scheduler_pick_next
        # comment). NOT blocked by GC's own ceiling-2 sections -- 0 < 2,
        # HIGH preempts a ceiling-2-boosted task outright, no tie-break
        # needed.
        Task("HIGH", priority=0, period=3 * TICK_MS,
             wcet=other_body_estimate_ms + measured_ctxsw_handoff_ms,
             blocking=measured_low_critical_section_ms),
        # MEDIUM (task_b): sleeps 1 tick, priority 1. Same reasoning as
        # HIGH -- blocked by LOW's ceiling-0 section, not by GC's
        # ceiling-2 ones (1 < 2).
        Task("MEDIUM", priority=1, period=1 * TICK_MS,
             wcet=other_body_estimate_ms + measured_ctxsw_handoff_ms,
             blocking=measured_low_critical_section_ms),
        # LOW (task_c): sleeps 2 ticks, priority 2. Its own WCET
        # includes the real measured critical section (it's the one
        # DOING the delay, not waiting on someone else's). Now also
        # carries GC's own worst-case blocking term (see this
        # function's own header) -- the gap this round closes.
        Task("LOW", priority=2, period=2 * TICK_MS,
             wcet=other_body_estimate_ms + measured_low_critical_section_ms + measured_ctxsw_handoff_ms,
             blocking=gc_worst_blocking_ms),
    ]

    print("DhruvaOS demo task set (HIGH/MEDIUM/LOW) -- real measured blocking term:")
    for t in tasks:
        print(f"  {t.name}: priority={t.priority} period={t.period}ms wcet={t.wcet:.3f}ms "
              f"blocking={t.blocking:.3f}ms deadline={t.deadline}ms")
    print()

    bound_ok, util = utilization_bound_ok(tasks)
    print(f"Liu & Layland utilization bound (sufficient, not necessary): "
          f"U={util:.4f}, {'PASSES' if bound_ok else 'fails (exact RTA below is the real answer)'}")
    print()

    results = response_time_analysis(tasks)
    all_ok = True
    for name, (r, ok) in results.items():
        task = next(t for t in tasks if t.name == name)
        margin = task.deadline - r if r is not None else None
        status = f"R={r:.3f}ms <= D={task.deadline}ms (margin {margin:.3f}ms)" if ok else "MISSES DEADLINE"
        print(f"  {name}: {status} -- {'PASS' if ok else 'FAIL'}")
        if not ok:
            all_ok = False

    print()
    if all_ok:
        print("VERDICT: schedulable with real measured blocking data, comfortable margin.")
        print("CAVEAT: 'other_body_estimate_ms' (5ms/task) is a conservative round-up,")
        print("not independently measured to the same rigor as the other figures. LOW's own")
        print(f"B_LOW ({gc_worst_blocking_ms:.3f}ms) now uses GC's real measured worst case")
        print("(the dwc2 USB-poll timeout, not the smaller healthy-path figure actually")
        print("observed across 10 real test passes -- a rigorous bound has to assume the")
        print("pessimistic case can happen). Re-run with real numbers before trusting this")
        print("for any actual production workload, not just this demonstration task set.")
        return 0
    else:
        print("VERDICT: NOT schedulable with real measured blocking data.")
        return 1


if __name__ == "__main__":
    import sys
    rc = main()
    print()
    print("=" * 70)
    print()
    rc2 = dhruvaos_demo_task_set_analysis()
    sys.exit(rc if rc != 0 else rc2)
