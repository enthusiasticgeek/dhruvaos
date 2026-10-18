#!/usr/bin/env python3
"""Automatic per-task stack-depth gate (user request, 2026-10-18).

build.sh's own existing stack-depth gate only ever covered kernel_main's
own boot-time call chain (--stack-depth-entry=kernel_main) -- that
file's own comment admitted every real task entry point (task_a..f,
the 4 dynamically-created demo tasks) was a "documented gap rather
than silently skipped... run manually before any round that adds real
depth to one of those task bodies." That manual-only discipline is
exactly how task_fsq's own real stack overflow (task #245, 4096 bytes
allocated vs a measured 4152-byte worst case) went undetected until
someone happened to run the tool by hand. This closes that gap for
good: every real task entry point, checked automatically, every build.

Runs `vanic stack-depth --format=json` ONCE (not once per task -- each
invocation re-pays the full lex+parse+typecheck cost, the exact
per-entry overhead build.sh's own kernel_main gate was already
restructured once to avoid), then checks every task's own reported
max-reachable-depth against its real allocated stack size minus the
SAME 1/8 margin convention kernel_main's own gate already established
(16384 - 1/8 = 14336, the literal number in build.sh today).

Exit 0 if every task is within budget, 1 (with a clear report) if any
task exceeds it -- same contract as build.sh's own existing gates
(asm_safety_audit.py, the stack-depth-entry=kernel_main emit flag).
"""
import json
import subprocess
import sys

VANIC = sys.argv[1] if len(sys.argv) > 1 else "/home/virgo/source/vani-compiler/target/release/vanic"
SOURCE = sys.argv[2] if len(sys.argv) > 2 else "kernel/kernel_main.vani"

# (task entry fn, real allocated stack bytes) -- keep in sync with the
# dhruva_alloc_stack_domain/_usrstack_domain calls in kernel_main.vani's
# own task-creation sequence (stack_bytes/stack_e_bytes/stack_f_bytes/
# fsq_stack_bytes/custom_stack_bytes/mutex_low_stack_bytes/
# mutex_high_stack_bytes). Margin: allocated * 7/8, the same fraction
# kernel_main's own existing gate uses (16384 -> 14336).
TASKS = [
    ("task_a", 4096),
    ("task_b", 4096),
    ("task_c", 4096),
    ("task_d", 4096),
    ("task_e", 16384),
    ("task_f", 262144),
    ("task_fsq", 16384),
    ("task_custom_demo", 4096),
    ("task_mutex_demo_low", 4096),
    ("task_mutex_demo_high", 4096),
]


def margin_budget(allocated: int) -> int:
    return (allocated * 7) // 8


# WARN at 75% of the already-margined budget -- advance notice that a
# task is trending toward its limit, before it actually crosses it.
# Matches asm_safety_audit.py's own DEFINITE/REVIEW severity split
# (DEFINITE = fails the build, REVIEW = printed but non-fatal) so this
# gate reads consistently with the project's other ones.
WARN_FRACTION = 0.75


def main() -> int:
    try:
        proc = subprocess.run(
            [VANIC, "stack-depth", SOURCE, "--format=json"],
            capture_output=True, text=True, check=True, timeout=120,
        )
    except subprocess.CalledProcessError as e:
        print("ERROR: task_stack_depth_check: vanic stack-depth itself failed:")
        print(e.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print("ERROR: task_stack_depth_check: vanic stack-depth timed out")
        return 1
    except json.JSONDecodeError as e:
        print(f"ERROR: task_stack_depth_check: could not parse vanic's JSON output: {e}")
        return 1

    data = json.loads(proc.stdout)
    by_name = {e["name"]: e for e in data["entries"]}

    failed = False
    warned = False
    print("Per-task stack-depth gate (allocated real budget, 1/8 margin):")
    for name, allocated in TASKS:
        entry = by_name.get(name)
        if entry is None:
            print(f"  ERROR: {name}: NOT FOUND in stack-depth report (renamed, removed, or "
                  f"typo'd in this script's own TASKS list?) -- treating as FAIL since a "
                  f"missing entry means this gate silently stopped checking a real task")
            failed = True
            continue
        depth = entry["max_depth_bytes"]
        budget = margin_budget(allocated)
        warn_at = int(budget * WARN_FRACTION)
        if depth > budget:
            status = "FAIL"
            failed = True
        elif depth > warn_at:
            status = "WARN"
            warned = True
        else:
            status = "PASS"
        pct = (depth * 100) // budget
        print(f"  {name}: {depth} bytes ({pct}% of {budget}-byte budget, {allocated} allocated) [{status}]")
        if status in ("FAIL", "WARN"):
            print(f"    via: {' -> '.join(entry['chain'])}")

    if failed:
        print("\nERROR: task_stack_depth_check: at least one task EXCEEDS its real stack "
              "budget -- a genuine, likely-crashing stack overflow on real hardware if this "
              "ships. Either shrink the call chain shown above, or raise that task's own "
              "dhruva_alloc_stack_domain/_usrstack_domain allocation in kernel_main.vani AND "
              "this script's own TASKS list together.")
        return 1
    if warned:
        print(f"\nWARNING: task_stack_depth_check: at least one task is above "
              f"{int(WARN_FRACTION * 100)}% of its stack budget -- not failing the build, but "
              f"worth a look before it gets worse.")
    else:
        print("\ntask_stack_depth_check: all tasks comfortably within budget.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
