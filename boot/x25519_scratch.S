/* Dhruva -- persistent scratch buffers for X25519 (RFC 7748) field
 * arithmetic and the Montgomery ladder. Same "allocate exactly once
 * at boot, never per-call" discipline as every other scratch buffer
 * in boot/scratch_state.S -- kept in a separate file purely so that
 * file doesn't grow by another ~20 entries; the pattern (a single
 * .word holding a heap address, set once via dhruva_alloc_bytes) is
 * identical.
 *
 * x1/x2/z2/x3/z3: the Montgomery ladder's own persistent state,
 * alive across all 255 loop iterations. A/AA/B/BB/E/C/D/DA/CB/a24e:
 * scratch fully overwritten within a single loop iteration, safe to
 * reuse across iterations (verified against the ladder's own
 * algorithm: nothing after AA/BB are computed reads the PREVIOUS
 * iteration's leftover A/AA/etc. values -- each is always written
 * before being read within the same iteration). product_scratch: the
 * 16-limb (64-byte) wide product every field25519_mul/_sqr call needs
 * for bignum_mul_raw's own output before reduction -- one shared
 * buffer is safe since no call ever needs two products alive at once.
 * invert_base/invert_result: field25519_invert's own two temporaries.
 * p_bytes/p_minus_2_bytes: the field modulus and its own -2, each a
 * fixed 32-byte constant computed once at boot (field25519_init). */

.section ".bss"
.align 4
x25519_x1_addr:
    .word 0
x25519_x2_addr:
    .word 0
x25519_z2_addr:
    .word 0
x25519_x3_addr:
    .word 0
x25519_z3_addr:
    .word 0
x25519_a_addr:
    .word 0
x25519_aa_addr:
    .word 0
x25519_b_addr:
    .word 0
x25519_bb_addr:
    .word 0
x25519_e_addr:
    .word 0
x25519_c_addr:
    .word 0
x25519_d_addr:
    .word 0
x25519_da_addr:
    .word 0
x25519_cb_addr:
    .word 0
x25519_a24e_addr:
    .word 0
x25519_product_scratch_addr:
    .word 0
x25519_invert_base_addr:
    .word 0
x25519_invert_result_addr:
    .word 0
x25519_p_bytes_addr:
    .word 0
x25519_p_minus_2_bytes_addr:
    .word 0
x25519_p9_bytes_addr:
    .word 0
x25519_fold_t_addr:
    .word 0
x25519_fold_s_addr:
    .word 0
x25519_a24_bytes_addr:
    .word 0

.section ".text"

.macro X25519_SCRATCH_PAIR name
.global \name\()_set
\name\()_set:
    ldr r1, =\name\()_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global \name\()_get
\name\()_get:
    ldr r0, =\name\()_addr
    ldr r0, [r0]
    bx lr
.endm

X25519_SCRATCH_PAIR x25519_x1
X25519_SCRATCH_PAIR x25519_x2
X25519_SCRATCH_PAIR x25519_z2
X25519_SCRATCH_PAIR x25519_x3
X25519_SCRATCH_PAIR x25519_z3
X25519_SCRATCH_PAIR x25519_a
X25519_SCRATCH_PAIR x25519_aa
X25519_SCRATCH_PAIR x25519_b
X25519_SCRATCH_PAIR x25519_bb
X25519_SCRATCH_PAIR x25519_e
X25519_SCRATCH_PAIR x25519_c
X25519_SCRATCH_PAIR x25519_d
X25519_SCRATCH_PAIR x25519_da
X25519_SCRATCH_PAIR x25519_cb
X25519_SCRATCH_PAIR x25519_a24e
X25519_SCRATCH_PAIR x25519_product_scratch
X25519_SCRATCH_PAIR x25519_invert_base
X25519_SCRATCH_PAIR x25519_invert_result
X25519_SCRATCH_PAIR x25519_p_bytes
X25519_SCRATCH_PAIR x25519_p_minus_2_bytes
X25519_SCRATCH_PAIR x25519_p9_bytes
X25519_SCRATCH_PAIR x25519_fold_t
X25519_SCRATCH_PAIR x25519_fold_s
X25519_SCRATCH_PAIR x25519_a24_bytes
