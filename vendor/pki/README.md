# pki

Raw public-key trust — no X.509/CA chain, a compile-time-pinned key
never runtime-settable — pure vāṇी, hardware-agnostic and heap-free.

Extracted from [Dhruva OS](https://github.com/enthusiasticgeek/dhruvaos)'s
Pi 4/5 port. `pki_verify_raw` really is exactly a one-line wrapper
around [`curve25519`](https://github.com/enthusiasticgeek/vani-curve25519)'s
`ed25519_verify` against a pinned 32-byte public key — deliberately
thin scope, matching DhruvaOS's own Pi 1 design (no certificate
format, no chain-of-trust, no CA).

File-based verification (checking a file on disk against a companion
`<path>.sig`) is **not** included here — that's a filesystem
integration concern for the consumer, not something a hardware-
agnostic package can assume (DhruvaOS's own Pi 1 kernel does this via
[DharaFS](https://github.com/enthusiasticgeek/dharafs), but that's
wiring the consumer does itself, not part of this package).

## Dependency

Depends on `curve25519` for `ed25519_verify`. Vendored at
`./vendor/curve25519` (itself vendoring `crypto_hash`) and pulled in
via a direct relative `use` — see `vani-curve25519`'s own README for
why this isn't a `vani.toml` `[deps]` entry.

## API

```
fn pki_pinned_key() -> [u8; 32]
fn pki_verify_raw(data: ref [u8; 64], data_len: i64, sig: ref [u8; 64]) -> i64
fn pki_self_test() -> i64   // 1 = pass, 0 = fail; no I/O side effects
```

`pki_pinned_key()` returns a fixed demo key baked in at v0.1.0 — a
real consumer will want its own pinned key, which today means editing
`src/lib.vani` directly (no runtime key-loading API exists, by
design: the whole point is that the trust anchor is a compile-time
constant, not something that can be changed after the fact).

`data` is capped at 64 bytes, matching `curve25519`'s own
`ed25519_verify` message cap.

## Verification

Reuses a real, independently-verified pinned key/message/signature
triple from DhruvaOS's own kernels. Covers a genuine signature
verifying correctly and tampered content being correctly rejected.
`test/host_test.vani` runs the self-test under the host harness.
