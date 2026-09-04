# DharaFS User Manual

DharaFS ("dhara" — धर, Sanskrit for "bearer/holder") is DhruvaOS's
log-structured filesystem, implemented entirely in `kernel/
kernel_main.vani`. This manual describes its on-disk format,
permission model, crash-consistency guarantees, and full API — as
built, not as originally envisioned.

## 1. Design in one paragraph

DharaFS is an append-only log of fixed-size 512-byte records. There is
no free-space bitmap, no separate metadata region, and no in-place
update of anything: writing to an existing path always means
appending a brand-new record under that path with a higher sequence
number — the "latest" record for a path (by sequence number) is
authoritative, and older records for the same path become
unreachable garbage until compaction reclaims them. This is what makes
every single-record write atomic almost for free: a record is either
fully written (valid checksum) or it isn't there yet as far as
recovery is concerned — there is no "half-updated" state for one
record.

## 2. On-disk record format

Every record is exactly 512 bytes:

| Offset | Size | Field | Notes |
|---|---|---|---|
| `[0:4)` | 4 | checksum | Covers `[4:512)` — see §2.1. |
| `[4:8)` | 4 | seq_num | Monotonically increasing; 0 is reserved (means "not a real record", used to distinguish a genuine record from a blank/unwritten block whose checksum happens to trivially match). |
| `[8:12)` | 4 | path_len | 0 = continuation-block marker (see §3); 1-32 = a real path's length; `0xFFFFFFF0` = a transaction marker (see §5) — anything outside 0-32 is never a real path. |
| `[12:44)` | 32 | path | Left-padded/unused bytes beyond `path_len` are not required to be zero for ordinary records, but are zeroed by every writer that touches them. |
| `[44:48)` | 4 | data_len | `0xFFFFFFFF` = tombstone (the path was deleted); for a transaction marker, repurposed to hold a block count instead. |
| `[48:52)` | 4 | next_block | 0 = no continuation; otherwise the block number of the next chunk of this same logical file (see §3). |
| `[52:56)` | 4 | owner_uid | |
| `[56:60)` | 4 | owner_gid | |
| `[60:64)` | 4 | mode | Low 9 bits are real Unix-style rwxrwxrwx permission bits; bits 9-11 hold the immutable/append-only/system attributes (§4.2) — the rest of the u32 is unused, matching how real Unix systems overload setuid/setgid/sticky bits above the base permission bits in one mode word. |
| `[64:512)` | 448 | data | The per-block payload cap (`dharafs_block_payload_cap()`); a file larger than this spans multiple blocks via the `next_block` chain. |

**Checksum** (§2.1): a simple rotate-and-add mix over `[4:512)`
(`buf_checksum`) — `csum = ((csum << 1) | (csum >> 31)) + byte` for
each byte in range. This is **not** a cryptographic hash; it reliably
catches torn/partial writes (the actual threat model for a real power
loss) but not deliberate tampering. For tamper detection, see §6
(verified I/O).

**Maximum file size**: 4096 bytes (`dharafs_file_max_len()`), spanning
up to 10 blocks (`ceil(4096/448)`).

**Maximum path length**: 32 bytes.

## 3. Multi-block files

A file larger than 448 bytes is split into `ceil(data_len/448)`
chunks, block numbers and sequence numbers allocated up front, but
**written in reverse order** — every continuation chunk first, the
head block (the one a lookup actually finds) last. This means the
single atomic write that makes the whole chain reachable at all is the
head block's own commit: if a crash happens partway through a
multi-block write, either the head was never written (the old version,
if any, is still what every reader sees) or it was (and every
continuation block it points to was necessarily already there,
written first).

A continuation block has `path_len = 0` and `next_block` pointing to
the next chunk (or 0 if it's the last). Reading a multi-block file
means finding the head via a normal path lookup, then following
`next_block` — with the same checksum/sequence validation at every
hop, so a broken or corrupted chain fails the whole read rather than
silently returning a truncated prefix.

## 4. Permission model

### 4.1 Owner/group/other (rwx)

Standard Unix-style: `mode`'s low 9 bits, checked bit-for-bit like a
real `chmod` mode. **uid 0 (root) always bypasses every check.**
There is no login system — `dharafs_user_set(uid, gid)` (the shell's
`su`) switches the active context unconditionally.

- `dharafs_write_raw_checked`/`dharafs_delete_raw_checked`/
  `dharafs_rename_raw_checked` all check write permission.
- `dharafs_read_raw_checked` checks read permission.
- A brand-new path is always writable (no directory object exists to
  hold a separate "who may create files here" permission).
- `dharafs_chmod_checked`: owner-or-root only, matching real POSIX
  `chmod()` — **not** governed by the rwx bits themselves.
- `dharafs_chown_checked`: **root only**, no owner exemption — even a
  file's own owner cannot give it away, matching strict POSIX
  `chown()` semantics.

### 4.2 Attributes: immutable / append-only / system

Packed into `mode`'s otherwise-unused bits 9-11 (no on-disk format
change was needed — see `dharafs_attr_immutable`/`_append_only`/
`_system` in the source for the exact bit values).

| Attribute | Blocks write | Blocks delete | Blocks being a rename source | Blocks being a rename destination |
|---|---|---|---|---|
| **immutable** | yes | yes | yes | yes |
| **append-only** | writes that aren't a valid prefix-extension | yes | **no** (content travels with it) | yes |
| **system** | no enforcement — informational only | no | no | no |

"Valid prefix-extension" for append-only: the new content must have
the *entire* old content as an exact byte prefix (this filesystem's
own storage is "replace with the newest full content," not a literal
incremental append, so this is what "append-only" has to mean here).

Ownership rule: a **non-root owner may set either protective attribute
but never clear it once set** — only root can undo immutable or
append-only, matching real `chattr`'s own `CAP_LINUX_IMMUTABLE`
requirement. `system` has no such restriction (nothing depends on it
staying set).

Set/query via `dharafs_set_attr_raw`/`dharafs_get_attr_raw`, or the
shell's `attr` command.

## 5. Rename and transaction atomicity

`dharafs_rename_raw` is: read the old path's full content, append it
under the new path (preserving owner/mode), then tombstone the old
path. Since round 52, this pair is wrapped in a real transaction
primitive so a crash between the two steps can't leave a half-done
rename:

A `TX_BEGIN` marker record (`path_len` set to a sentinel value outside
the real 1-32 range, `data_len` repurposed to hold a block count) is
appended immediately before the N blocks the transaction covers.
There is **no separate commit record** — block numbers in this log are
strictly increasing and never reused within one boot session, so "are
the next `block_count` blocks all present and checksum-valid" is
itself a complete proof the transaction finished; nothing else could
ever have produced valid records at exactly those positions. On
recovery, `dharafs_init` finds an incomplete transaction only ever at
the very tail of the log (a crash stops everything, so nothing real
could have been appended after one) and rolls the append cursor back
to the transaction's own starting block — old data intact, new data
simply never existed. This extends the same "old OR new, never mixed"
guarantee single-record atomicity already gives across multiple
records.

**Current scope**: this covers `dharafs_rename_raw`'s own append+
delete pair. There is no general-purpose "wrap N arbitrary operations
in one transaction" API exposed yet — see `TODO.md` if you need one
for a different multi-file operation.

## 6. Verified I/O (opt-in integrity beyond the checksum)

`buf_checksum` (§2) catches torn writes but not tampering. For paths
where that matters, `dharafs_write_verified_raw`/`_checked` also
writes a SHA-256 digest of the data to a companion `<path>.sha256`
file (using the *same* existing primitives — no on-disk format
change), and `dharafs_read_verified_checked` recomputes and compares
it on read.

- **Opt-in per path**: a plain (non-verified) write has no companion
  digest, and reading it back through the verified path is not an
  error — it just returns the data normally, same as an unverified
  read.
- **Return convention** extends the checked functions' own (-1 not
  found, -2 permission denied): **-3 means the read succeeded but the
  companion digest exists and does NOT match** — tamper or corruption
  beyond what the checksum alone catches.
- Shell: `writev`/`catv`.
- **Known cost**: `sha256_hash` uses persistent scratch internally
  (fixed as of round 53's own follow-up), so it no longer grows the
  heap per call — but it does still recompute the full hash on every
  verified read/write, which is real CPU work for a large (near
  4096-byte) file. Not a correctness concern, just not free.

## 7. Append-only log API

For the "sensor → record → append → record → append" embedded logging
shape, distinct from a single named file. A log named `name` lives as
numbered files `/logs/<name>-0001.log`, `/logs/<name>-0002.log`, ...
plus a small `/logs/<name>.hdr` header (8 bytes: current file index +
current file size), tracked automatically:

- `dharafs_log_append_raw(name, record, ...)` — appends `record`
  (≤512 bytes, `dharafs_log_record_max_len()`) to the current file,
  rolling over to a new numbered file automatically once the current
  one would exceed 3584 bytes (`dharafs_log_rollover_threshold()`).
  Built entirely on the existing append/read primitives — no new
  on-disk record format.
- Shell: `log <name> <text>`.
- Records are concatenated with **no separator** — if you need to
  distinguish individual entries later, include your own delimiter or
  fixed-width framing in what you log.
- Old generations are reclaimed automatically: only the current file
  plus the `dharafs_log_retention_count()` most recent prior ones
  (5, keeping 5 generations total) are kept on disk — rolling over to
  generation N deletes generation `N - 5` once it exists, so a log
  that runs indefinitely (the sensor-logging use case this API exists
  for) uses bounded storage rather than growing forever. Reclaiming
  only happens after the new generation AND its header update are both
  safely durable, so a crash mid-rollover can never leave the header
  pointing at an already-deleted file.

## 8. Block-device backends

`dharafs_block_read`/`dharafs_block_write` dispatch on
`dharafs_state_get_block_dev()`:

| Value | Backend |
|---|---|
| 0 (default) | SDHOST — the real SD card, used for every real filesystem operation. |
| 1 | USB mass storage (DWC2 + bulk-only transport), proven as a genuine second backend through the same abstraction. |
| 2 | `host_virtual_disk_read`/`write` — an in-memory array, used **only** by `test/host_harness/` (the host-side ASAN/UBSAN test driver) to exercise DharaFS's real logic without touching real hardware. Dead code on real hardware; production `runtime_stubs.c` always fails this path if somehow reached. |

**Media (at-rest) encryption (round 62)** applies orthogonally to
which backend above is selected — a ChaCha20 transform hooked
directly into `dharafs_block_read`/`dharafs_block_write` (renamed to
`_raw` + a thin wrapper), so every higher layer in this manual
(records, multi-block files, transactions, snapshots, the directory
index) keeps operating on plaintext with zero awareness it's on.
**Off by default** (`dharafs_crypto_get_enabled()` starts at 0). Key
derived once at boot via PBKDF2-HMAC-SHA256 from a fixed passphrase;
nonce per block is a pure function of the block number. Honest,
deliberate limitation: overwriting the same block twice under the
same key reuses the same keystream (a two-time-pad leak against an
attacker holding two on-disk snapshots) — real protection against the
common single-stolen-SD-card threat, not multi-snapshot analysis.
Integrity (Poly1305, built round 67) is not yet wired into this path
— see `TODO.md`.

## 9. Recovery (what happens at boot)

`dharafs_init` scans blocks 1 through 2048 (a bounded 1MB log region
for this v1), validating each record's checksum and sequence number,
to reconstruct where the log's append cursor currently sits and the
highest sequence number seen. This is recomputed from scratch every
boot — nothing about recovery is persisted across reboots except the
log's own contents, specifically so a crash mid-write (this project's
own actual concern, tested by `test/power_yank.py`) can never leave
stale in-RAM bookkeeping trusted over what the card actually holds. A
transaction marker with an incomplete follow-up group (§5) rolls the
cursor back to before it; `log_start` (compaction's own optimization
of how much of the log still needs scanning) always resets to block 1
on boot.

## 10. Hashed directory index (round 67)

`boot/dirindex_state.S`: a 256-slot open-addressed (linear probing, no
deletion) RAM-only hash table mapping path → latest block number,
FNV-1a hash. Built once by `dharafs_init`'s own boot-time scan and
kept in sync afterward by `dharafs_append_raw`/`dharafs_delete_raw` on
every successful write — every path-mutating operation in this
codebase funnels through one of those two, so there's no separate
"remember to update the index" call site to miss.
`dharafs_find_latest_block_raw` tries the index first (an O(1) probe)
and only falls through to the original full linear scan on a miss,
which then self-heals the index for next time. A hit is always
correct by construction; a miss is always safe — identical behavior
to before this feature existed, including graceful degradation if the
table's 256 slots ever genuinely fill (falls back to the linear scan
for everything beyond that, same as if the index didn't exist at
all). Pure performance optimization — nothing about the on-disk
format or the recovery semantics in §9 changed.

## 11. Snapshots / versioned rollback (round 67)

A filesystem-wide point-in-time view, added without needing any
change to `dharafs_compact`'s own reclaim logic: compaction's
"reclaim" is an in-RAM-only optimization (advancing `log_start`,
which unconditionally resets to block 1 on the next boot) that hides
old blocks from *ordinary* lookups without ever erasing their bytes —
nothing in this v1 design reuses or overwrites a block number within
one boot session. So a snapshot doesn't need to pin or protect
anything from reclaim; it only needs to remember a sequence number to
query against later.

- `dharafs_snapshot_create(name)` — pins `next_seq - 1` (the highest
  sequence number that genuinely existed at that moment) under `name`
  (`boot/snapshot_state.S`, 8 named slots).
- `dharafs_snapshot_read(path, name, buf)` — finds the highest-
  sequence record for `path` with `seq <= ` the pinned sequence,
  scanning from block 1 (**not** `log_start`) — the one deliberate
  place in this codebase that looks past what `log_start` currently
  hides.
- `dharafs_snapshot_delete(name)`.

**Scope, explicit**: filesystem-wide (one pin covers every path), not
per-file/per-directory; no snapshot-aware `dharafs_list`; bounded by
the same 2048-block/1MB v1 log region cap every other DharaFS feature
already has. Verified against a real, non-trivial case: create a
snapshot, overwrite the file, run an actual `dharafs_compact()` pass
that reclaims the old block from ordinary lookups, confirm the
snapshot still reads the pre-overwrite content byte-exact — proving
this works against real compaction, not just an un-compacted log.

## 12. Priority-aware FS request queue (round 67)

An opt-in, asynchronous alternative to the synchronous `dharafs_*`
calls used everywhere else in this manual — every existing call site
is completely unchanged; this is purely additive.

- `dharafs_queue_submit_write_raw`/`_submit_delete_raw`/`_submit` (a
  `Str` convenience wrapper) enqueue a request into 8 fixed slots
  (`boot/fsqueue_state.S`), auto-tagging the calling task's own
  `current_eff_prio()`/`current_task_get()`.
- `dharafs_queue_dispatch_one` always picks the numerically LOWEST
  priority value present (this project's own "0 is highest"
  convention), oldest submission first among ties.
- A dedicated background task (`task_fsq`, priority tier 2 — the same
  tier as `task_gc`'s compaction) drains the whole queue every time it
  wakes.
- Queued writes are capped at `dharafs_block_payload_cap()` (448
  bytes, single-block only); a full queue or an oversized write is
  rejected cleanly and the caller falls back to a direct synchronous
  call — never a silent drop.

## 13. API reference (raw/checked/Str layering)

DharaFS follows one consistent layering, top to bottom:

- **`dharafs_*_raw`**: operate on raw byte buffers + explicit lengths,
  **unchecked** (trusted primitives — no permission enforcement).
  Used by callers that only ever have raw bytes (compaction re-carrying
  a record it just read off disk has no `Str` form to build from
  arbitrary bytes).
- **`dharafs_*_checked`**: the real permission-enforcement boundary,
  taking explicit `req_uid`/`req_gid`. This is what the shell's
  mutating commands (`write`, `rm`, `mv`, `writev`, `chmod`, `chown`)
  go through.
- **`dharafs_*`** (Str-based, e.g. `dharafs_append`, `dharafs_read`,
  `dharafs_delete`, `dharafs_chmod`, `dharafs_chown`): convenience
  wrappers taking a real `Str`. **`dharafs_chmod`/`dharafs_chown`
  (the Str-based forms) are unchecked** — they exist for internal/
  self-test use where the caller already controls the context; the
  shell goes through the `_checked` raw forms instead (see §4.1).

Core functions: `dharafs_init`, `dharafs_append_raw`/`_checked`/
`_verified_raw`/`_verified_checked`, `dharafs_read_raw`/`_checked`/
`_verified_checked`, `dharafs_delete_raw`/`_checked`,
`dharafs_rename_raw`/`_checked`, `dharafs_stat_raw`/`dharafs_stat`,
`dharafs_chmod_checked`/`dharafs_chown_checked`, `dharafs_set_attr_raw`/
`dharafs_get_attr_raw`, `dharafs_list_dir_raw`/`dharafs_list_dir`,
`dharafs_log_append_raw`/`dharafs_log_append`, `dharafs_compact`
(GC — reclaims blocks whose every record has a newer copy beyond
`log_start`), `dharafs_tx_begin_raw` (the transaction primitive, §5).
Round 67 additions: `dharafs_snapshot_create`/`_read`/`_delete` (§11),
`dharafs_queue_submit_write_raw`/`_submit_delete_raw`/`_submit`/
`_dispatch_one` (§12) — the hashed directory index (§10) has no public
API of its own, it's an internal acceleration
`dharafs_find_latest_block_raw` already uses transparently.

## 14. See also

- `docs/DHRUVAOS_MANUAL.md` — the shell commands that front most of
  this API, the scheduler, and the overall system.
- `docs/TODO.md` — open DharaFS-adjacent backlog (a general multi-op
  transaction API beyond rename; capability tokens beyond uid/gid/
  mode; wear/erase statistics — no current backend exposes that
  information at this layer at all).
- `docs/HARDWARE_IN_LOOP.md` — connecting a real Pi 1B + SD card;
  includes a critical note on SD partition layout, since this
  filesystem writes raw blocks 1-2048 (~1MB) from the very front of
  the device with zero partition-table awareness.
- `test/host_harness/README.md` — the host-side ASAN/UBSAN test
  driver for this filesystem's own logic.
