# DHDL roadmap: from compile-time register tags to a queryable, file-configurable subsystem layer

## Where DHDL actually is today

"DHDL" (Dhruva Hardware Description Language) currently means exactly one
thing in this codebase: `#[mmio(size=N)]`, a vani-compiler attribute on a
`const` that tags a hardware register address, used so the same GPIO/UART
logic can target BCM2835 vs BCM2711 without duplicating code (task #170).
It is **compile-time only** — it generates nothing at runtime, reads no
config file, and has no relationship to Linux's device tree beyond the
name. This doc scopes what it would take to grow a real, runtime,
file-configurable, queryable subsystem layer alongside it — a different
project that happens to share the name, not an extension of the attribute
itself.

Prompted by the `/config/loglevel` work (2026-09-28,
[[project_dhruva_loglevel_config_2026_09_28]] in memory) — that feature
established the pattern this whole roadmap generalizes: a `.bss`+accessor
state file, a `/config/<name>` file read once at boot, and (the missing
piece, scoped below) a generic way to ask a subsystem "what are you
actually doing right now" without hand-writing a new `if` branch every
time.

## Survey: what's real vs. aspirational, per subsystem the user named

| Subsystem | Real driver? | Current state |
|---|---|---|
| Disk (SD) | **Yes, most mature** | `sdhost_*` (~30 fns) + `boot/sdcard_state.S`. Densest existing `.bss`+accessor surface in the project — this whole session's own work lives here. |
| USB (host) | **Yes** | `dwc2_*` + 5 state files (`usb_msd/net/wifi/hid/bt_state.S`), one per device class. |
| WiFi | **Yes, substantial** | Full RTL8188CU register-level driver + WPA2 handshake state (`usb_wifi_state.S`, `wpa2_hmac_state.S`, `wpa_handshake_state.S`, `wpa_ptk_scratch.S`). Task #197, actively worked. |
| Ethernet | **Yes** | LAN9512 backend on `usb_net_state.S`. Spec-only — never live-verified against real hardware (no LAN9512 ever attached). |
| BLE | **Yes, earlier-stage** | Real HCI ACL framing + GATT layer (`gatt_state.S`, `gatt_server_state.S`). |
| Display | **Yes** | `fb_*` + `boot/fb_state.S`. Already has a shell front end (`shell_dispatch_fb`: `fb init/status/fill`). |
| DMA | **Yes** | `dma_ram_copy_self_test`/`dma_uart_tx_self_test` + `boot/dma_uart_state.S`. Boot-time self-test only, no live query yet. |
| RAM/heap | **Yes, different pattern** | `dhruva_alloc_bytes` family, already queryable via `shell_dispatch_heap` and `diagnose` — but state lives in the C runtime stub, not a `boot/*_state.S` file. Needs its own adapter, not a retrofit. |
| Cache | **Partial — not really a subsystem** | Only `mem_barrier` (a shared DMB primitive reused everywhere). No config surface exists to query; likely stays out of scope entirely. |
| Audio | **No** | Zero implementation. GPIO31's own I2S ALT2 pinctrl group is defined but never activated by anything. |
| CAN | **No** | Zero hits. |
| RS485 | **No** | Zero hits. |
| I2C | **No** | Zero hits. |
| SPI | **No** | Zero hits (only false-positive matches: a loop var named `spi`, an unrelated QEMU SD-model comment). |
| LoRa | **No** | Zero hits. |

**Consequence for scoping**: seven subsystems (disk, USB, WiFi, ethernet,
BLE, display, DMA) already have real drivers and are pure *retrofit*
work — wire an existing accessor surface into a new generic query
mechanism, no new hardware code. RAM is a near-retrofit needing one new
adapter. Six subsystems (audio, CAN, RS485, I2C, SPI, LoRa) have **no
driver at all** — for these, "DHDL roadmap" work is limited to making sure
the query/config *interface* is generic enough that a future driver adopts
it from day one, never to inventing the drivers themselves. Building six
new hardware drivers is its own multi-month body of work, tracked
separately (see the TODO entries below, each explicitly marked
driver-not-yet-built).

## Existing precedent to build on, not replace

Two patterns already exist and should be generalized, not thrown away:

1. **Per-subsystem shell verbs** — `shell_dispatch_gpio` (`gpio <pin>
   in|out|read|write|pull ...`), `shell_dispatch_fb` (`fb init|status|fill
   ...`). Good shape for the *command* half.
2. **Aggregate snapshot** — the plain `diagnose` command hand-calls
   several subsystems' own accessors into one flat report. Good shape for
   the *report* half, but it's rebuilt by hand every time a field is
   added — exactly the generic-registration gap below.

Neither is a registered, generic "ask any subsystem for its own current
parameters" mechanism. That's the one genuinely new piece this roadmap
adds — everything else is applying the `/config/loglevel` pattern more
places.

## Design: two halves, boot-time config and live query

**Static config (extends the already-shipped `/config/loglevel`
pattern)**: one `/config/<subsystem>` file per subsystem, plain text,
read once at boot by a `<subsystem>_config_init()` following
`log_level_init()`'s exact shape (read via `dharafs_read`, parse, apply
via the subsystem's own existing setter accessor, default on
missing/invalid file). No new mechanism needed here — just more call
sites of the one already built and verified.

**Live query (the new piece, directly answers "query and dynamically
fetch parameters wherever possible")**: a small fixed-size registration
table — `{name: Str, describe: fn() -> i64}` pairs, vani already supports
fn-typed values (used elsewhere, see `docs/PORTING.md`'s block-device
abstraction plan) — populated once at boot, one call per subsystem:
`dhdl_register("sd", sd_describe)`. Two new shell commands:
- `dhdl list` — walks the table, prints registered subsystem names.
- `dhdl query <name>` — looks up the matching `describe` fn, calls it.
  Each subsystem's own `describe` fn is a thin adapter over accessors
  that **already exist** (`sd_state_get_rca`/`_is_sdhc`/`_is_4bit` for
  SD, GPIO's function-select reads, DMA's busy/status, etc.) — genuinely
  live data, not a cached snapshot, since it calls the real accessor at
  query time.

Deliberately **not** building a write-back (`dhdl set <name> <param>
<value>`) path in the first pass: some parameters are safe to change live
(log level already proved this out), others (SD bus width, WiFi channel
mid-association) are not, and that safety analysis is genuinely
per-subsystem, not a generic property of the mechanism. Scope `set`
per-subsystem, later, once `list`/`query` exist and the first subsystem
(most likely SD, given how much of this session's own work already lives
there) proves the pattern live.

## Phased plan

- **Phase 0 — generic mechanism.** `boot/dhdl_state.S` (registration
  table, following the `.bss`+accessor pattern), `dhdl list`/`dhdl query`
  shell commands, zero real subsystem wiring yet — build and verify the
  mechanism itself against one trivial describe fn first.
- **Phase 1 — retrofit the subsystems with the densest existing accessor
  surface.** SD (`sdcard_state.S`, most mature), GPIO, the already-shipped
  log-level system itself (dogfooding `dhdl query loglevel`). Smallest
  effort, proves the pattern against real, varied accessor shapes.
  **DONE (2026-10-01, task #295)**: `sd_describe`/`gpio_describe` added
  (`kernel_main.vani`), thin adapters over existing accessors (`sd_state_
  get_rca`/`_is_sdhc`/`_is_4bit`/`_drain_forced_fallback_count`;
  `gpio_get_function`/`gpio_read` on the 8 pins the boot code actively
  drives: UART0 TXD/RXD + SDHOST CLK/CMD/DAT0-3). QEMU-verified live:
  `dhdl list` shows all 3 subsystems, `dhdl query sd`/`dhdl query gpio`
  both return genuinely live state (real RCA from boot-time card init,
  correct ALT0 function-select on all 8 pins).
- **Phase 2 — retrofit display, DMA, RAM/heap.** Display and DMA are
  direct retrofits; RAM needs one new adapter over the C-runtime-stub
  state (no new `.bss` file required, just an adapter fn).
  **DONE (2026-10-01, task #296)**: `display_describe`/`dma_describe`/
  `ram_describe` added (`kernel_main.vani`). Display reuses `fb_base_
  get`/`_size_get`/`_pitch_get` (same 3 accessors `fb status` already
  prints). DMA reuses `dma_uart_tx_busy()` -- a genuine read-only CS-
  register query, deliberately NOT the self-test fns, which actually
  kick off a transfer. RAM is the one new adapter the roadmap
  predicted, over `dhruva_heap_used_bytes`/`_alloc_count_get` (same
  accessors `diagnose` already uses). QEMU-verified live: all three
  return genuinely live state (real fb base/size/pitch, real DMA
  busy=no, real heap usage). 6/8 registration-table slots now used --
  Phase 3's 4 subsystems will need `DHDL_MAX_SLOTS` raised past 8.
- **Phase 3 — retrofit the USB-backed subsystems.** USB host, ethernet,
  WiFi, BLE — more parameters each (link state, MAC, WPA2 status,
  enumeration state), same mechanism, no new mechanism work.
  **DONE (2026-10-01, task #297)**, scoped down to enumeration state
  only: `usb_describe` (`dwc2_port_connected`/`_port_enabled`, direct
  real HPRT0 reads, same ones the boot self-test's own "USB: port
  connected=..." print already uses), `ethernet_describe`/`wifi_
  describe`/`ble_describe` (each device class's own `_get_kind`
  accessor). Deliberately did NOT reach into the WPA2 join context
  (explicit caller-owned, not a persisted singleton) or GATT
  connection state -- both real, actively-evolving surfaces (task #197
  still in-progress); richer per-subsystem state is a follow-up, not
  blocked by this round. Registration table raised 8->12 slots
  (`boot/dhdl_state.S`) to fit; now at 10/12. QEMU-verified live: all 4
  return correct state (no USB device ever enumerates under QEMU, so
  every kind reads 0/no, exactly as expected).
- **Phase 4 — per-subsystem `dhdl set` support.** Only after Phase 1-3
  prove `list`/`query` live; scoped and safety-reviewed one subsystem at
  a time, starting with the ones already proven safe to reconfigure live
  (log level).
  **STARTED (2026-10-01, task #298)**: generic mechanism built -- a
  SEPARATE fixed 12-slot table in `boot/dhdl_state.S` (`dhdl_register_
  setter`/`dhdl_set_by_id`), since a setter fn's `fn(u32) -> i64` shape
  can't share the describe table's zero-argument dispatch path. `dhdl
  set <name> <value>` added to the shell (deliberately 2 arguments, not
  the roadmap's own speculative `<name> <param> <value>` -- no
  registered subsystem has more than one settable parameter yet). Only
  loglevel registered as settable so far -- every other subsystem
  stays query-only until its own safety analysis says otherwise, per
  this entry's own long-standing reasoning. QEMU-verified a full live
  round trip in one boot: `dhdl set loglevel 12` -> `ok`, demo-task
  chatter starts appearing immediately (the real behavioral proof, not
  just a changed number), `dhdl query loglevel` confirms `mask=
  0x0000000C (DEMO GC)`; `dhdl set sd 1` correctly rejected (query-only
  subsystem); `dhdl set bogus 1` correctly rejected (unknown name).
  Remaining subsystems' settability is an open, subsystem-by-subsystem
  question, not scheduled.
- **Phase 5 (separate epic, not DHDL-layer work) — new drivers for the
  six subsystems with nothing today**: I2C, SPI, CAN, RS485, audio, LoRa.
  Each is its own multi-round driver-bring-up effort (register-level
  work, self-tests, real-HW verification) on the scale of the RTL8188CU
  or LAN9512 drivers already in this codebase. Adopt the DHDL config/
  query convention from the first commit of each, rather than retrofit
  later. Not scheduled; tracked here so the eventual work starts from
  this convention instead of reinventing one per driver.

## `dhdl set` safety survey (2026-10-01, task #298)

Before wiring a second settable subsystem, surveyed every other registered subsystem's own setter
accessors: `sd_state_set`/`_set_is_4bit` (RCA, is_sdhc, is_4bit), `fb_base_set`/`_size_set`/`_pitch_set`, and
every `usb_net`/`usb_wifi`/`usb_bt_set_kind`/`_set_bulk_*_epaddr`/`_mps`/`_toggle`. Every single one exists
purely to RECORD what real hardware enumeration or mailbox negotiation already discovered -- not an
independent, software-only policy knob the way loglevel's mask is. Letting `dhdl set` write any of them
would desync software's belief about currently attached/negotiated hardware from reality -- exactly the
per-subsystem danger this doc already named above (SD bus width, WiFi channel mid-association), now
confirmed concretely rather than asserted. GPIO is the one genuine exception -- its function/pull/level
writes are direct register writes, not cached beliefs, so they ARE safe to set live -- but it already has
its own dedicated `gpio <pin> in|out|read|write|pull ...` shell command; a second `dhdl set gpio` path would
duplicate it with no narrower risk and no real benefit. **Conclusion: no second subsystem is wired.**
Loglevel remains the only registered subsystem with a safe, independent live-settable parameter among the
10 currently in `dhdl list`. The next candidate is whichever FUTURE subsystem turns out to have a genuinely
software-only policy parameter -- not a scheduled item, since none of the existing 10 qualify.

## `/dev`-style path interface on top of DHDL (scoped 2026-10-02, task TBD — not yet implemented)

User: "do we have a software subsystem we can query like linux treats devices as files" — then, after
confirming DHDL (`dhdl list`/`query`/`set`) is the closest existing analog but isn't path-addressable:
"scope the /dev-style path abstraction on top of DHDL." Design only below; no code written yet.

**What this is, and isn't.** Real Linux `/proc`/`/sys` are virtual filesystems: an `open()`/`read()` on
`/sys/class/.../status` never touches a disk, it calls straight into live kernel state at access time. This
scopes the same relationship for DhruvaOS: a reserved `/dev/<name>` path namespace that the shell's existing
`cat`/`write`/`ls` verbs recognize and route to DHDL, *before* the real DharaFS block-backed path layer ever
sees them — same reasoning DharaFS's own write path already applies elsewhere (reject before touching real
storage, don't let a look-alike path silently create a real persisted record). This is explicitly **not** a
second command grammar to learn (`dhdl query wifi` still works, unchanged) — it's the same data, reachable
through the uniform file-style verbs a user would reach for instinctively, matching the actual ask.

**Interception point.** `shell_dispatch`'s own `cat`/`write`/`ls` handlers (kernel/kernel_main.vani) already
copy the parsed path into `dharafs_path_scratch_get()` before calling `dharafs_read_raw_checked`/`dharafs_
write`/`dharafs_list`. Add one check immediately after that copy, before any of those calls: if the path's
first 5 bytes are literally `/dev/` (or the path is exactly `/dev`, for `ls`), branch into the new DHDL-
routing logic instead and `return` — the real DharaFS call is never reached. Cheap, surgical, and leaves
DharaFS's own already-audited internals ([[project_dharafs_scratch_bounds_audit_2026_09_27]]) completely
untouched.

**One new shared helper, factored out of existing duplication.** `shell_dispatch_dhdl`'s own `query`/`set`
handlers already each hand-roll the same name→id `shell_word_matches` if-chain (10 subsystems, duplicated
twice). Factor it into `dhdl_subsys_id_for_name(line_buf: mut ref i64, name_start: i64, name_end: i64) -> i64`
(returns -1 for unknown), used by `query`, `set`, AND the new `/dev/` routing — three call sites sharing one
chain instead of two growing to three independently. The one actual code change to already-shipped logic
this design needs; everything else below is purely additive.

**Read: `cat /dev/<name>`.** Resolve `<name>` (the path segment after `/dev/`) via the new helper; unknown
→ "(not found)" (matching `cat`'s existing behavior for a real missing path, not a different error shape
for a different reason). Known → `dhdl_call_by_id(id)`, i.e. byte-for-byte the same output `dhdl query
<name>` already produces today. **Honest limitation, inherited from the roadmap's own still-open "Open
questions" entry below**: every registered `describe` fn is `fn() -> i64` that prints directly via
`uart_puts` — there is no buffer-returning variant. So `cat /dev/wifi` behaves like a *command* that prints
on demand (true to the real `/proc` model, where a read triggers live computation), not like a static file
whose bytes could be captured, diffed, or piped into another in-kernel consumer. Capturing `describe` output
into a caller-supplied buffer would need every registered describe fn's own signature to grow a buffer
parameter — a real, larger change touching all 10 currently-registered subsystems, out of scope here and
not worth doing until something other than a human at the UART actually needs programmatic access, not just
a human-readable print.

**Write: `write /dev/<name> <value>`.** Same name resolution, then `dhdl_set_by_id(id, value)` — identical
semantics to `dhdl set <name> <value>` today, including its existing single-source-of-truth gate (the -1
return IS the "does this subsystem support set" check, no separate permission table). Unknown name or a
query-only subsystem (everything except loglevel today, per this doc's own safety survey above) both already
produce a clear rejection through the existing `dhdl_set_by_id` path; the `/dev/` front door doesn't change
either outcome, just how it's reached.

**Enumeration: `ls /dev`.** Synthesize a listing from `dhdl_list_count()`/`dhdl_list_id_at()`/`dhdl_name_
for_id()` — the exact same 3 calls `dhdl list` already makes, just triggered from `ls`'s own dispatch when
the path is exactly `/dev`. A real subdirectory-per-category hierarchy (`/dev/usb/wifi`, mirroring sysfs's
own nested bus/class trees) is explicitly NOT in this scope — DHDL's own subsystem list is already flat (10
names, no categories), so a flat `/dev` matches what's actually being exposed rather than inventing
structure the backing registry doesn't have.

**Namespace safety.** `/dev` becomes a reserved prefix: a real `write /dev/anything ...` must be rejected
outright ("error: /dev is reserved") rather than silently falling through to a real persisted DharaFS
record under that path, the same "reject, don't guess" posture every other wire-format/path boundary check
in this project already uses. Confirmed before writing this doc: no existing DharaFS path anywhere in this
codebase or its tests already starts with `/dev` ((`grep -rn '"/dev'` across kernel_main.vani/test/docs)),
so reserving it breaks nothing in flight.

**Explicit non-goals for this phase**: no nested per-attribute files (one flat entry per subsystem, matching
DHDL's own one-`describe`-call-per-subsystem shape, not real sysfs's multiple-attributes-per-device model);
no new permission/ownership model beyond whatever already gates `dhdl set` (none, today); no byte-buffer
read semantics (see the Read section's own limitation above). Each would be a real, separately-scoped
follow-on, not a surprise discovered mid-implementation.

**Verification plan, matching this doc's own established pattern**: extend `test/dhdl_realhw_check.py`
(already proven 16/16 via the `ready`/`READY` handshake) with `cat /dev/wifi` vs `dhdl query wifi` output-
equivalence, `ls /dev` enumeration-matches-`dhdl list` check, and the `write /dev/x ...` reserved-prefix
rejection — all QEMU-reachable without real hardware, same as every other DHDL phase so far.

## Open questions for whoever picks this up

- Registration table sizing: fixed array of N slots (matching this
  codebase's own established "no dynamic collections, fixed-size +
  linear scan" convention — see `dirindex_max_slots()`) — needs an actual
  N once Phase 1-3's real subsystem count is known.
- Whether `describe` fns print directly (matching every other diagnostic
  in this codebase) or return structured data a caller formats — printing
  directly is simpler and consistent with existing style; revisit only if
  a non-shell consumer (e.g. a future SSH real command loop) needs the
  same data in a different shape. **Directly blocks true byte-buffer
  `/dev` read semantics — see that section above.**
