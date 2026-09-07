# crypto_hash

SHA-256 and SHA-512 (FIPS 180-4), pure vāṇी, hardware-agnostic and
heap-free.

Extracted from [Dhruva OS](https://github.com/enthusiasticgeek/dhruvaos)'s
Pi 4/5 (AArch64) port, where SHA-256 (round 85) and SHA-512 (round 94)
were first written this way because that target has **no heap
allocator at all, by design**. Every function here takes fixed-size
array parameters (`[u8; 256]` scratch, `[u8; 32]`/`[u8; 64]` digest
output) and returns by value or writes through a `mut ref` array — no
`dhruva_alloc_bytes`-style heap allocator, no `extern "C"` scratch
accessors, no persistent cross-call state. That makes it drop-in
portable to any vāṇी target, with or without a heap, not just the
board it was first written for.

## Why this exists

DhruvaOS's two kernels (`kernel_main.vani` for Raspberry Pi 1,
`kernel_main_rpi4.vani` for Pi 4/5) had independently hand-ported SHA
implementations: Pi 1's is heap-based (`mut ref i64` buffers via
`buf_read_u32`/`buf_write_u32` and named persistent scratch
accessors), Pi 4/5's is the fixed-array style here. This package is
the Pi 4/5 style, pulled out so it's the ONE shared implementation —
new boards (and, over time, Pi 1 itself) consume this instead of
writing a third copy.

## API

```
fn sha256_hash(msg: mut ref [u8; 256], msg_len: i64, out: mut ref [u8; 32]) -> i64
fn sha256_digest_equal(a: ref [u8; 32], b: ref [u8; 32]) -> i64
fn sha256_self_test() -> i64   // 1 = pass, 0 = fail; no I/O side effects

fn sha512_hash(msg: mut ref [u8; 256], msg_len: i64, out: mut ref [u8; 64]) -> i64
fn sha512_digest_equal(a: ref [u8; 64], b: ref [u8; 64]) -> i64
fn sha512_self_test() -> i64   // 1 = pass, 0 = fail; no I/O side effects
```

`msg` is padded **in place** by `sha256_hash`/`sha512_hash` (FIPS
180-4 padding: a `0x80` byte, zero bytes up to the block boundary,
then the bit-length). Message length is capped at what fits the
256-byte scratch buffer after padding — up to 247 bytes for SHA-256,
up to 111 bytes for SHA-512 before a second 128-byte block would be
needed (v0.1.0 doesn't loop the caller's own buffer across more than
one padding pass beyond that).

The self-test functions return `1`/`0` and print nothing — printing
whatever the result means (e.g. `"CRYPTO: SHA-256 ... (PASS)"`) is
the consumer's job, since a hardware-agnostic package can't assume
any particular UART/console function exists.

## Using it as a dependency

```toml
[deps]
crypto_hash = { path = "./vendor/crypto_hash" }
```

then `vanic vendor` and call `crypto_hash::sha256_hash(...)` etc.
from any file in your own package.

## Verification

Both self-tests reuse the exact known-answer vectors DhruvaOS's own
`kernel_main.vani`/`kernel_main_rpi4.vani` self-tests already carry:
3 FIPS-180-4/NIST SHA-256 KATs (empty string, `"abc"`, a 56-byte
message landing exactly on a second block) and 4 SHA-512 KATs (empty
string, `"abc"`, a 111-byte message, a genuine 2-block 112-byte
message). `test/host_test.vani` runs both self-tests under the host
harness on both the LLVM and C backends.
