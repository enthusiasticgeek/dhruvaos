# vani-galois

Generic GF(2^m) finite-field arithmetic, and a binary BCH encoder/decoder
with real bit-flip correction built on top of it, for the
[vāṇी compiler](https://github.com/enthusiasticgeek/vani-compiler).

No Kosh dependencies -- v0.1.0 is a standalone package.

## Add to your project

```toml
# vani.toml
[deps]
galois = { registry = "kosh", version = "^0.1" }
```

```sh
vanic add galois
vanic build
```

## Why this exists

Several packages in this ecosystem already have field arithmetic
(`vani-aes`'s `gf256_mul`/`gf256_inv` for GF(2^8), `vani-curve25519`'s
`field25519_*` for GF(2^255-19)) -- but each is deliberately hardcoded
to its own one field, because that's genuinely all its one consumer
ever needs. The motivating use for THIS package (a NAND-flash error-
correcting-code layer for DhruvaOS's DharaFS filesystem, needing
GF(2^13) specifically) is different: the field's own degree and
reduction polynomial are exactly the parameters that vary across
different consumers, so this package takes them as plain function
arguments instead of baking in one field.

## What's included (v0.1.0)

| Module | Functions |
|---|---|
| Generic GF(2^m) arithmetic | `galois_field_mask`, `galois_mul`, `galois_pow`, `galois_inv` |
| Binary BCH encode/decode | `bch_encode`, `bch_decode_correct` |
| Bit-array helpers (used by the above, exposed for a caller injecting test errors) | `bch_data_get_bit`/`bch_data_set_bit` (`[u8;512]` buffers), `bch_small_get_bit`/`bch_small_set_bit` (`[u8;32]` buffers) |

### GF(2^m) arithmetic

`galois_mul(a, b, prim_poly, deg)` multiplies two elements of GF(2^deg),
where `prim_poly` holds the field's primitive polynomial's own
low-degree terms (its implicit leading x^deg coefficient is never
passed -- exactly how `vani-aes`'s `gf256_mul` already encodes AES's
own x^8+x^4+x^3+x+1 as the bare constant 27). `deg` must be in [1, 31].
`galois_pow`/`galois_inv` build on it via square-and-multiply and
Fermat's-little-theorem-for-finite-fields (`a^(2^deg-2)`) respectively.

**Finding your own field's primitive polynomial**: pick any irreducible
degree-`deg` polynomial over GF(2) (a table lookup, or verify one
computationally -- see "Verifying this package" below for the exact
irreducibility check used for this package's own test parameters).
If `2^deg - 1` happens to be prime (a Mersenne prime -- true for
deg = 2, 3, 5, 7, 13, 17, 19, 31, ...), every irreducible polynomial of
that degree is automatically primitive too, since the only possible
multiplicative orders of a nonzero non-unity element are 1 or the
(prime) group order itself -- this is why this package's own test
parameters use deg=13 (2^13-1 = 8191 is prime).

### BCH codec

`bch_encode`/`bch_decode_correct` implement a binary BCH code: given a
field degree `deg`, its primitive polynomial `prim_poly`, and a target
correction strength `t` (correct up to `t` bit errors per codeword),
the generator polynomial for that `(deg, t)` pair is a fixed polynomial
derivable once, offline -- **this package does not compute it at
runtime** (deriving it requires building minimal polynomials of
`alpha^1..alpha^(2t)` and taking their LCM, a one-time symbolic
computation no embedded consumer should pay for on every boot or even
every build). Compute your own generator polynomial once using the
recipe in "Deriving a generator polynomial" below, then pass its
coefficient bytes as the `gen_poly` parameter to `bch_encode` (and its
degree as `parity_bits`).

`data` is always a fixed `[u8; 512]` buffer and `parity`/`gen_poly` are
always a fixed `[u8; 32]` buffer (`parity_bits` can be less than 256;
the unused trailing bytes are simply zero) -- this package does not use
generics or dynamic sizing, matching every other package in this
ecosystem. `bch_encode`'s `data_bits` may be less than 512*8: this is
exactly how a **shortened** BCH code works (the standard technique for
a message length shorter than the field's own full 2^deg-1 codeword
length) -- the "missing" high-degree message bits are implicitly zero
and simply never computed or transmitted.

`bch_decode_correct` returns the number of bits corrected (0 if the
word was already clean, up to `t`), or **-1** if the word has more than
`t` errors -- detected, never silently miscorrected. On -1, `data`/
`parity` are left exactly as given (still containing whatever errors
were present on input), not rolled back to anything else.

`t` is bounded by `galois_bch_max_t()` (8, matching the package's only
real consumer as of v0.1.0 -- DharaFS's own t=8 NAND-FTL ECC) -- a
fixed internal buffer size in this package (the Peterson-Gorenstein-
Zierler solve and Chien search both use fixed-size scratch arrays sized
for exactly `t=8`, deliberately not padded with untested headroom for
a larger `t` nothing has exercised yet), not a property of BCH codes
in general. Raise `galois_bch_max_t()` and the `[u32; 17]`/`[u32; 9]`/
`[u32; 72]`/`[i64; 8]` buffer sizes in `bch_syndrome`/`galois_pgz_solve`/
`bch_decode_correct` together (to `2t+1`/`t+1`/`t*(t+1)`/`t`
respectively) if a future consumer genuinely needs stronger correction
-- this is a real resize each time, not just flipping a constant, and
should be re-verified the same way v0.1.0's own t=8 was (see "Verifying
this package" below) before being trusted at the new strength.

## Deriving a generator polynomial (offline, once per (deg, t))

This package intentionally does NOT include this derivation (see
above) -- do it once, offline, in any language with arbitrary-precision
integers, and hardcode the resulting bytes in your own project. The
recipe, concretely:

1. Pick an irreducible degree-`deg` polynomial over GF(2) (verify via
   `x^(2^deg) == x (mod poly)` using repeated-squaring polynomial
   multiplication, plus `poly(0) != 0` and `poly(1) != 0` -- sufficient
   whenever `deg` is prime, which covers every Mersenne-prime-exponent
   degree above).
2. For each `i` in `1..=2t`, compute the minimal polynomial of
   `alpha^i` (the conjugates `{alpha^(i*2^j) : j=0..deg-1}`, their
   product `prod(x + alpha^c)` expanded with GF(2^deg)-valued
   coefficients that must collapse to {0,1} -- verify that collapse
   computationally, don't assume it).
3. The generator polynomial is the GF(2)-polynomial product (= LCM,
   since these minimal polynomials are pairwise coprime) of the
   distinct minimal polynomials found in step 2.
4. Verify `x^(2^deg - 1) + 1 mod g(x) == 0` (every root of `g` must be
   an `(2^deg-1)`-th root of unity) before trusting the result.

This package's own test file (`test/host_core_test.vani`) uses the
`(deg=13, t=8)` generator derived exactly this way for its own test
vectors.

## Verifying this package

Every algorithm here was validated in a from-scratch Python reference
implementation (direct `gf2_polmod`-based polynomial division for
encoding, syndrome evaluation + Peterson-Gorenstein-Zierler + Chien
search for decoding) across hundreds of randomized trials BEFORE being
translated to vani, specifically to separate "is the algorithm
correct" from "is the vani translation correct" as two independently
checkable things rather than debugging both at once. Two real bugs
were caught this way, not by inspection:

- The Peterson-Gorenstein-Zierler linear system's matrix indexing was
  initially wrong (`mat[r][c] = syn[r+c+1]` instead of the correct
  `mat[r][c] = syn[nu+r-c]`) -- it happened to degenerate to the
  correct formula for a single error (`nu=1`), which is exactly why a
  test that only ever injected one error at a time would never have
  caught it. Caught by testing 2-8 simultaneous errors, not just 1.
- The LFSR encoder initially ran for `data_bits + parity_bits` clock
  cycles (data, then a `parity_bits`-cycle "flush") -- the flush does
  not belong: the register already holds the correct remainder after
  exactly `data_bits` cycles, since the virtual `x^parity_bits` shift
  is already implicit in the feedback structure over those cycles
  alone. The extra flush silently double-applies that shift. Caught by
  cross-checking the LFSR's bit-by-bit simulation against a direct
  `gf2_polmod(data << parity_bits, gen)` computation on a hand-worked
  3-bit example before trusting it on real-sized data.

`test/host_core_test.vani` (`vanic run test/host_core_test.vani`, also
passes `--backend=c`) exercises: GF(2^13) order/inverse sanity, a clean
round trip, single-bit correction, exactly-`t`-simultaneous-bit
correction (spread across both the data and parity portions of the
word), and `t+1`-bit detection-without-miscorrection -- the same four
scenarios the Python reference was validated against.

## Scope decisions (read before using)

- **LDPC is out of scope.** For very high raw bit-error rates (the
  realistic regime for modern TLC/QLC NAND flash) a production NAND
  controller often uses LDPC instead of BCH -- but LDPC is normally
  hardware-accelerated and is not a realistic software workload on a
  small embedded CPU with no dedicated ECC engine. BCH with a
  configurable `t` is this package's ceiling; Hamming is simply the
  `t=1` degenerate case of the same code path, not a separate
  implementation.
- **No runtime generator-polynomial derivation**, by design -- see
  above.
- **Fixed-size buffers, no generics** -- `[u8; 512]` data / `[u8; 32]`
  parity, matching this ecosystem's own no-heap-allocator convention.
  A consumer needing a different data size can still use this package
  (via the shortened-code technique, feeding fewer than 512*8 bits) up
  to that fixed ceiling, but not beyond it without raising the
  constant and recompiling.
