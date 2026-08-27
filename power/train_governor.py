#!/usr/bin/env python3
"""Phase 5 step 2 -- OFFLINE training for the governor's fixed-cost
scoring function (DHRUVA_ARCHITECTURE.md §7 Phase 5 step 2).

This is the actual "training": a small, deterministic search run here,
on the host, once, at development time -- never on-device, never in
the scheduling hot path. Its only output is a handful of small integer
weights, hand-copied into kernel_main.vani's governor_v2_weight*
constants. There is no model file, no runtime inference loop, and
nothing resembling a neural network, per the architecture doc's own
explicit caveat ("deliberately not a neural network").

The problem this solves: step 1's governor (governor_desired_freq_mhz)
reacts to the INSTANTANEOUS run-queue depth alone, every time it runs.
A single-tick load spike -- noise, not real sustained demand -- gets
exactly the same full upward response as genuine sustained load,
costing an extra real-hardware DVFS transition (and the higher
frequency's own extra power draw) for no lasting benefit. Step 2
smooths the decision over a short history window (a fixed-size moving
average) instead of reacting to the latest sample alone, damping
single-tick noise while still ramping up for genuine sustained load --
a real, standard DVFS-governor technique (Linux's own "ondemand"/
"conservative" cpufreq governors do a version of this), not a
decorative "AI" label on unrelated logic.

"Training" here means: grid-search small integer weight vectors
(w0..w3, applied to the current sample and the 3 before it, most
recent weighted heaviest) over a FIXED, hand-authored synthetic
best-effort workload replay (representative of "mostly quiet, one
noise spike, one real sustained burst, one medium plateau" -- not
live-collected telemetry, since this is a from-scratch demo project
with no fleet of real devices to harvest data from), scoring each
candidate on:
  - total DVFS transitions (a real hardware cost: each mailbox
    SET_CLOCK_RATE call has real switching latency/energy on real
    silicon, distinct from the steady-state power draw at whatever
    level is currently set)
  - total weighted MHz-time (sum of applied MHz per tick -- a rough
    proxy for average power draw)
  - a correctness penalty if the SUSTAINED burst (ticks 11-14 in the
    workload below) doesn't reach the HIGH level at all -- a governor
    that just always picks LOW would trivially "win" on the other two
    metrics while being useless; this keeps the search honest.
"""

# Fixed synthetic best-effort workload replay: ready_count sampled
# once per (simulated) idle-task wake. Deliberately includes a quiet
# baseline, one single-tick noise spike (index 5) that reverts
# immediately, one genuine sustained burst (indices 11-14), and one
# medium plateau (indices 21-24) -- see the module docstring for why
# each matters to the search.
WORKLOAD = [0, 0, 1, 0, 0, 5, 0, 0, 1, 1, 2, 4, 5, 5, 4, 3, 2, 1, 0, 0,
            0, 2, 2, 2, 2, 1, 0, 0, 0, 0]

SUSTAINED_BURST_INDICES = range(11, 15)  # must reach HIGH somewhere in here


def desired_freq_mhz(ready_count: int) -> int:
    """governor_desired_freq_mhz -- must stay byte-for-byte identical
    to kernel_main.vani's own copy; this is what step 1 already ships,
    unmodified, and what step 2's smoothed score is fed through too
    (same thresholds, smoothed input) rather than needing its own
    separate table."""
    if ready_count <= 1:
        return 250
    if ready_count <= 3:
        return 450
    return 700


def simulate_v1(workload):
    """Step 1 baseline: react to the instantaneous sample every tick."""
    levels = [desired_freq_mhz(r) for r in workload]
    transitions = sum(1 for i in range(1, len(levels)) if levels[i] != levels[i - 1])
    mhz_time = sum(levels)
    reached_high_in_burst = any(levels[i] == 700 for i in SUSTAINED_BURST_INDICES)
    return levels, transitions, mhz_time, reached_high_in_burst


def simulate_v2(workload, weights):
    """Step 2 candidate: score = weighted average of the current
    sample and the 3 before it (weights most-recent-first, integer
    arithmetic with a fixed divisor -- exactly what the embedded vani
    code does), fed through the SAME threshold table as v1."""
    w0, w1, w2, w3 = weights
    divisor = w0 + w1 + w2 + w3
    levels = []
    history = [0, 0, 0, 0]  # [current, t-1, t-2, t-3], oldest samples default 0
    for r in workload:
        history = [r, history[0], history[1], history[2]]
        score = (w0 * history[0] + w1 * history[1] + w2 * history[2] + w3 * history[3]) // divisor
        levels.append(desired_freq_mhz(score))
    transitions = sum(1 for i in range(1, len(levels)) if levels[i] != levels[i - 1])
    mhz_time = sum(levels)
    reached_high_in_burst = any(levels[i] == 700 for i in SUSTAINED_BURST_INDICES)
    return levels, transitions, mhz_time, reached_high_in_burst


def main():
    v1_levels, v1_trans, v1_mhz, v1_ok = simulate_v1(WORKLOAD)
    print(f"v1 (step 1, instantaneous):  transitions={v1_trans:3d}  "
          f"mhz_time={v1_mhz:5d}  reaches_high_in_burst={v1_ok}")
    print(f"v1 levels: {v1_levels}")
    print()

    # Small integer grid search -- weights need not sum to any
    # particular value (the divisor is just their sum), so this
    # searches every combination with each weight in [1, 10] and the
    # current-sample weight required to be the largest (recency bias
    # is the whole point; a search that let older samples dominate
    # would just be a differently-shaped lag, not smoothing).
    best = None
    for w0 in range(1, 11):
        for w1 in range(1, w0 + 1):
            for w2 in range(1, w1 + 1):
                for w3 in range(1, w2 + 1):
                    weights = (w0, w1, w2, w3)
                    levels, trans, mhz, ok = simulate_v2(WORKLOAD, weights)
                    if not ok:
                        continue  # disqualified: never reaches HIGH for real sustained load
                    # Primary objective: fewer transitions (real hardware
                    # switching cost); tie-break on lower total MHz-time.
                    score = (trans, mhz)
                    if best is None or score < best[0]:
                        best = (score, weights, levels, trans, mhz)

    if best is None:
        print("No candidate reached HIGH during the sustained burst -- search space too narrow.")
        return 1

    _, weights, v2_levels, v2_trans, v2_mhz = best
    print(f"v2 (step 2, best found):     transitions={v2_trans:3d}  "
          f"mhz_time={v2_mhz:5d}  weights={weights}")
    print(f"v2 levels: {v2_levels}")
    print()
    print(f"Improvement: {v1_trans - v2_trans} fewer transitions "
          f"({100 * (v1_trans - v2_trans) / v1_trans:.0f}%), "
          f"{v1_mhz - v2_mhz} less MHz-time "
          f"({100 * (v1_mhz - v2_mhz) / v1_mhz:.0f}%)")
    print()
    print(f"Embed in kernel_main.vani as:")
    print(f"  governor_v2_weight0 = {weights[0]}")
    print(f"  governor_v2_weight1 = {weights[1]}")
    print(f"  governor_v2_weight2 = {weights[2]}")
    print(f"  governor_v2_weight3 = {weights[3]}")
    print(f"  governor_v2_divisor = {sum(weights)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
