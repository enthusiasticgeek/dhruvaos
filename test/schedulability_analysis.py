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

    def __post_init__(self):
        if self.deadline is None:
            self.deadline = self.period
        if self.wcet <= 0:
            raise ValueError(f"{self.name}: wcet must be positive")
        if self.period <= 0:
            raise ValueError(f"{self.name}: period must be positive")
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
    1986). For each task i, iterates the fixed-point recurrence
        R_i^(0) = C_i
        R_i^(k+1) = C_i + sum_{j in hp(i)} ceil(R_i^(k) / T_j) * C_j
    until it converges (R_i^(k+1) == R_i^(k)) or exceeds D_i (provably
    unschedulable, no point iterating further -- the recurrence is
    monotonically non-decreasing, so once it passes the deadline it
    can only get worse). hp(i) = every task with priority number
    STRICTLY LESS than task i's own (this project's own "0 is highest"
    convention, matching eff_prio_table throughout context_switch.S).

    Returns {task_name: (response_time_or_None, meets_deadline)} --
    response_time is None if the iteration was aborted early because it
    already exceeded the deadline (the exact overshoot value isn't
    meaningful once that's already been decided)."""
    results = {}
    for i, task in enumerate(tasks):
        higher_priority = [t for t in tasks if t.priority < task.priority]
        r = task.wcet
        while True:
            interference = sum(ceil(r / hp.period) * hp.wcet for hp in higher_priority)
            r_next = task.wcet + interference
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

    print()
    if all_ok:
        print("ALL SELF-TESTS PASS")
        return 0
    else:
        print("SOME SELF-TESTS FAILED")
        return 1


if __name__ == "__main__":
    import sys
    sys.exit(main())
