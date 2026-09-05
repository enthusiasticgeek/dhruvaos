# DharaFS portability: extracting it for use by other kernels

Scoped out on request (2026-09-05); **Tier 1 is now built, standalone, and
verified**, in its own repository: `~/source/dharafs` (Apache 2.0, kosh
package `dharafs`). This document is the feasibility/effort analysis that
extraction was based on — every number below comes from grepping
`kernel/kernel_main.vani` directly, not estimated — updated in place where
the real extraction found the original analysis imprecise (see "Tier 1,
corrected" below). DhruvaOS's own `kernel/kernel_main.vani` has NOT been
migrated to consume the new package — that's a deliberate, separate,
not-yet-requested next step; this codebase's own DharaFS code is untouched.

## Bottom line

**Yes, and the hard part is already done by accident.** `test/host_harness`
already compiles DharaFS as plain, portable C (via `vanic emit
--backend=c`) with every hardware/OS-specific dependency swapped for a
small C stub file, and runs it clean under ASAN/UBSAN. That proves the
actual filesystem logic — record format, checksums, journaling,
permissions, verified I/O, media encryption — has no inherent
dependency on ARM, QEMU, or DhruvaOS's own scheduler. What's missing is
packaging: turning "code that happens to be portable" into "a real,
consumable library another project can depend on."

## The real dependency surface (measured, not guessed)

`kernel_main.vani` is 27,841 lines total. 104 `dharafs_*` functions
span 3,655 of them (~13%). Scanning every one of those 104 function
bodies for calls to anything outside DharaFS itself finds exactly 135
distinct external identifiers, which fall into six groups:

| Group | Count | Real dependency? |
|---|---|---|
| Block-device read/write | 9 | **Yes — the one real seam.** `dharafs_state_get_block_dev`/`_set` plus 3 backend implementations (SDHOST/USB-MSD/host-virtual-disk) and one address helper. A consumer needs exactly a `read_block(n) -> status` / `write_block(n, buf) -> status` pair; DhruvaOS's own 3-way backend dispatch is convenience, not a requirement. |
| DharaFS's own scratch/state accessors | 39 | **Mechanical, not risky.** All are `get`/`set` one-liners backing scratch buffers — a workaround for vani not having persistent top-level state holding buffer pointers. Trivially reimplementable as one-line C statics (this is *exactly* what `test/host_harness/host_stubs.c` already does for all of them). |
| dirindex/fsqueue/snapshot state | 53 | **Corrected during extraction — only fsqueue is actually cuttable.** A precise brace-matching dependency pass (the original scan's "next top-level `fn`" boundary heuristic over-attributed trailing comment blocks to the wrong function) found dirindex and snapshot are woven directly into core functions (`dharafs_append_raw`, `dharafs_delete_raw`, `dharafs_find_latest_block_raw`, `dharafs_init`) — but with a provably-safe fallback (a dirindex miss just means the same linear log scan the code always did), making them **safer to include than to surgically remove**. Only the 7 `dharafs_queue_*` functions have a genuine hard dependency (scheduler primitives) and are cleanly separable. The extracted package therefore ships dirindex + snapshot and omits only fsqueue. |
| Allocator/string/buffer utilities | 12 | **One real dependency (`dhruva_alloc_bytes`), the rest is pure logic.** `buf_read/write_byte`, `str_len_bytes`, `wrapping_mul`, etc. have zero OS coupling and can be copied verbatim. Only the allocator itself needs a real shim — see "Correctness and performance" below for why DhruvaOS's own allocator specifically must **not** be copied along with it. |
| Crypto primitives | 8 | **Pure algorithms, already independently verified.** ChaCha20-Poly1305, SHA-256, PBKDF2 — the exact same functions this project's own TLS 1.3 stack uses, checked byte-exact against real reference implementations before ever being trusted here. Only needed if the media-encryption/verified-I/O features come along. |
| Scheduler/task primitives | 2 | **Optional — only the FS queue uses them.** `current_eff_prio`/`current_task_get`. Disappears entirely if the priority-queue feature is cut. |
| UART/logging | 3 | **Real but trivial.** `uart_puts`/`uart_putc`/`uart_put_hex32` — three functions, needs a log-sink shim (or a real no-op for a build that wants silence). |

## Extraction mechanism: this is what kosh packages are for

vani-compiler already has a shipped (2026-07-21, all 6 phases, 12
published packages) namespaced package system (`kosh`): a `vani.toml`
manifest, `[deps]` entries each wrapped in their own module namespace,
transitive resolution, cycle detection, a real lockfile. This is
*exactly* the mechanism for "reusable vani code another project
depends on" — extracting DharaFS means packaging it as a kosh package,
not inventing a new file-splitting scheme.

The interface a consuming project (another kernel, or a from-scratch
one) would implement is unchanged from what DhruvaOS itself already
does: a set of `extern "C" fn` declarations that get satisfied by
whatever the final native-toolchain link step provides — hand-written
assembly on bare metal, a thin C shim on a hosted kernel, or (as
`host_harness` already proves) plain host-process C stubs for testing.
Nothing about this crosses a language boundary DharaFS doesn't already
cross today.

## Correctness and performance: what does and doesn't need care

**Low risk, unchanged:** the on-disk record format, checksums,
journaling/transaction logic, and permission checks don't move at all
in this plan — they're the same vani source, compiled the same way,
already regression-tested by this project's own battery
(`phase4_milestone.py`, `power_yank.py`'s 70/70 torn-write sweep,
`host_harness`'s ASAN/UBSAN-clean run). Extraction is a packaging
change, not a rewrite of filesystem logic.

**One real design decision, not a risk:** `dhruva_alloc_bytes` is a
deliberate *never-free* bump allocator — correct for DhruvaOS's own
"boot once, run forever, nothing meaningfully returns memory" model,
and actively wrong to copy verbatim into a general-purpose kernel that
expects to reclaim memory. The shim a consumer provides for this one
function is the actual interesting engineering work here, not a
mechanical stub — it needs to match the *signature* DharaFS expects
(a flat `size -> pointer` allocator with no free/realloc calls from
DharaFS's own side, confirmed by grep: DharaFS never calls anything
resembling `free`), while the target kernel is free to back that with
a real slab/heap allocator underneath.

**Performance:** nothing in the extraction touches the hot path (block
read/write, checksum, record parse) — those stay exactly as fast as
they are today, since the code doesn't change, only what's linked
around it does. The one place performance could regress is if a
target kernel's own block-device shim adds overhead DhruvaOS's direct
SDHOST/USB-MSD calls don't have (e.g., going through a generic VFS/
block-layer indirection) — that cost belongs to the target kernel's
own integration, not to anything in DharaFS itself.

## Phased scope

- **Tier 0 (already done, zero new work):** `test/host_harness` *is*
  a working proof that DharaFS's core logic compiles and runs
  correctly as portable C, decoupled from ARM/QEMU/the scheduler.
  Nothing to build here, just worth knowing it already exists.
- **Tier 1 — DONE, `~/source/dharafs`, corrected scope:** 90 core
  `dharafs_*` functions — `dharafs_init`/`_append`/`_read`/`_delete`/
  `_rename`/`_stat`/permissions/attributes/append-only-log, **plus**
  the hashed directory index and snapshots (see corrected dependency
  table above — these turned out safer to keep than to cut). Cuts
  fsqueue (7 functions, genuine scheduler dependency) and the
  SHA-256-verified-companion-file / AEAD-metadata crypto-tier
  functions (6 functions with zero remaining callers once cut, plus
  their 2 thin public wrappers). Shim surface: 9 real externs — block
  I/O (2), allocator (1), logging (3), an optional stubbable
  media-encryption hook (3) — plus ~80 mechanical scratch/dirindex/
  snapshot accessors, all provided by a bundled portable C runtime
  (`runtime/dharafs_runtime.c`) so most consumers never reimplement
  them. Verified via a real standalone round trip (init/append/read/
  overwrite/rename/delete against an in-memory disk), clean under
  ASAN/UBSAN. No crypto, no scheduler dependency at all.
- **Tier 2 — add verified I/O + media encryption:** bring in the
  crypto-primitive calls and their own scratch accessors, replacing
  Tier 1's stubbable encryption hook with real algorithm calls. Still
  zero scheduler dependency. Not yet built.
- **Tier 3 — add the priority-aware FS queue:** the 7 `dharafs_queue_*`
  functions plus the 2 scheduler-primitive calls
  (`current_eff_prio`/`current_task_get`). Requires the target kernel
  to expose an equivalent scheduler API. Not yet built.

## What this plan deliberately does not do

No attempt to make the extraction "generic for any hypothetical future
kernel" — that's speculative design against requirements that don't
exist yet, the same discipline this project applies everywhere else.
If a real second consumer shows up, build exactly the shim it needs;
until then this document is the answer to "is it feasible," not a
commitment to build Tier 1-3 speculatively.

## Open question — checked

Whether vani has grown genuine persistent top-level state (removing
the need for the scratch-accessor `.S`/C one-liners entirely) was
checked directly (`static counter: i64 = 0;` at top level) against the
current vani-compiler before starting Tier 1: still a hard parse error
("expected 'use', 'intent', 'struct', or 'fn'"). The scratch-accessor
pattern remains a real, permanent necessity, not a stale workaround —
it's exactly what `runtime/dharafs_runtime.c` implements for the new
package.

## See also

- `docs/DHARAFS_MANUAL.md` — how DharaFS works as used by DhruvaOS today.
- `docs/PORTING.md` — the other portability axis (DhruvaOS itself to
  different *hardware*, not a subsystem to a different *kernel*).
- `test/host_harness/` — the existing proof-of-portability this whole
  analysis leans on.
