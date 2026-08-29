# Host-side ASAN/UBSAN harness

Runs DharaFS's real logic (record format, recovery, append/read/
delete, compaction, permissions, directory hierarchy) plus the
SHA-256/ChaCha20/bignum primitives as an ordinary host process under
AddressSanitizer and UndefinedBehaviorSanitizer, instead of only ever
exercising this code on bare metal under QEMU.

## Why this exists

The bare-metal target has no hosted process model, so there is no
`valgrind`/ASAN/UBSAN on real hardware -- memory-safety bugs there
have historically only been found by code review or by symptom (a
wrong self-test result, a hang, a reboot). This harness gets real
sanitizer coverage for the parts of `kernel_main.vani` that don't
depend on actual MMIO hardware.

## Why it can't cover everything

Two hard architectural limits, not implementation gaps:

1. `mmio_read_u32`/`mmio_write_u32` are vani compiler builtins that
   lower directly to raw pointer dereferences of hardcoded hardware
   addresses in the generated C -- not interceptable extern function
   calls. Any code path that calls `uart_puts`/`uart_putc` (all of the
   existing `_self_test` wrapper functions do, for PASS/FAIL
   reporting) would segfault dereferencing an unmapped address on a
   host process. This harness calls the CORE logic functions directly
   instead (see host_main.c's own header comment) and never the
   `_self_test` wrappers.
2. DharaFS's two real block-device backends (SDHOST, USB mass storage)
   both go through real MMIO transitively. `kernel_main.vani`'s
   `dharafs_block_read`/`dharafs_block_write` have a third backend
   (`dev==2`) specifically for this harness, backed by an in-memory
   array (`host_virtual_disk_read`/`write` in host_stubs.c) -- see
   kernel_main.vani's own comment on that branch.

So: no networking, no USB, no scheduler/interrupts, no SD/MMIO code is
exercised here. Everything else that's pure logic operating on
in-memory buffers -- which is most of what actually manipulates
untrusted lengths and offsets, the bug class this harness targets --
is fair game.

## Running it

```
./build_and_run.sh
```

This regenerates `kernel_gen.c` from the CURRENT `kernel/kernel_main.
vani` every run (via `vanic emit --backend=c`), patches it with
`unstatic.py` (vani's C backend marks every vani-defined function
`static`; a small whitelist gets un-static'd so `host_main.c`, a
separate translation unit, can call into it directly -- see
unstatic.py's own header comment), compiles `kernel_gen_patched.c` +
`host_stubs.c` + `host_main.c` with `-fsanitize=address,undefined`,
and runs it. `ASAN_OPTIONS=detect_leaks=0` is set because `dhruva_
alloc_bytes` never frees by design (matching the real bump allocator's
own documented behavior) -- LeakSanitizer would otherwise flood output
with expected, non-actionable "leaks" every run.

`kernel_gen.c` and `kernel_gen_patched.c` are build products, not
checked in -- only `host_stubs.c`, `host_main.c`, `unstatic.py`, and
`build_and_run.sh` are source.

## Extending coverage

To exercise another core function: add its signature to unstatic.py's
`WHITELIST` and to host_main.c's own forward-declaration block, then
call it from a new `test_*` function in host_main.c's `main()`. If it
needs an extern this harness doesn't stub yet, add a real
implementation (if the test cares about its behavior) or a trivial
dummy (if it's only needed to satisfy the linker) to host_stubs.c.

## What this found (2026-08-29)

A genuine hang/DoS bug in `dharafs_read_raw`: a continuation block
whose on-disk `data_len` field is exactly 0 (a value no real append
path ever writes, but a corrupted or adversarial disk image could
contain) made the read loop's `remaining` counter never decrease,
looping forever if `next_block` pointed back into the chain. Found by
`test_self_referential_continuation_chain` (which runs the read in a
forked child under a wall-clock timeout specifically so a real hang
gets reported as a test failure instead of hanging the harness
itself), fixed in `kernel_main.vani`'s `dharafs_read_raw` by rejecting
`cont_len <= 0` (previously only `cont_len < 0`, which was already
dead code -- a u32-read-then-cast-to-i64 can never be negative).
