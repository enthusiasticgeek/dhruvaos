/* Dhruva -- persistent scratch/constant buffers for ML-KEM-512
 * (FIPS 203), round 67's PQC deliverable, built on top of the
 * Keccak/SHA-3/SHAKE primitives in boot/keccak_scratch.S. Same
 * allocate-once-at-boot discipline as every other scratch buffer in
 * this project.
 *
 * K=2 (ML-KEM-512's own module rank) is a FIXED constant for this
 * whole implementation, not a runtime parameter -- so the "vector of
 * K polynomials" and "K x K matrix of polynomials" shapes FIPS 203
 * describes generically are represented here as explicitly-named
 * pairs/quads of buffers (s0/s1, a00/a01/a10/a11, ...) rather than an
 * indexable array, matching this project's own established "named
 * buffers, not pointer arithmetic into a larger one" convention
 * (vani has no way to offset into the middle of an existing buffer).
 *
 * Each polynomial is 256 coefficients, one u32 per coefficient (not
 * bit-packed -- only the wire-format ByteEncode/ByteDecode functions
 * bit-pack; the internal representation stays simple), so 1024 bytes
 * per polynomial buffer.
 *
 * mlkem_zetas/mlkem_gammas: the 128 precomputed NTT twiddle factors
 * and base-case-multiplication constants (mod q=3329), computed
 * programmatically from the algorithm's own definition -- see
 * kernel_main.vani's own header comment on mlkem_init for the full
 * derivation/verification story, same discipline as every other
 * constant table this round. */

.section ".bss"
.align 4
mlkem_zetas_addr:
    .word 0
mlkem_gammas_addr:
    .word 0
mlkem_a00_addr:
    .word 0
mlkem_a01_addr:
    .word 0
mlkem_a10_addr:
    .word 0
mlkem_a11_addr:
    .word 0
mlkem_s0_addr:
    .word 0
mlkem_s1_addr:
    .word 0
mlkem_e0_addr:
    .word 0
mlkem_e1_addr:
    .word 0
mlkem_t0_addr:
    .word 0
mlkem_t1_addr:
    .word 0
mlkem_r0_addr:
    .word 0
mlkem_r1_addr:
    .word 0
mlkem_enc_e1_0_addr:
    .word 0
mlkem_enc_e1_1_addr:
    .word 0
mlkem_u0_addr:
    .word 0
mlkem_u1_addr:
    .word 0
mlkem_v_addr:
    .word 0
mlkem_mu_addr:
    .word 0
mlkem_w_addr:
    .word 0
mlkem_e2_addr:
    .word 0
mlkem_acc_addr:
    .word 0
mlkem_tmp1_addr:
    .word 0
mlkem_tmp2_addr:
    .word 0
mlkem_rho_addr:
    .word 0
mlkem_sigma_addr:
    .word 0
mlkem_prf_out_addr:
    .word 0
mlkem_xof_out_addr:
    .word 0
mlkem_h_buf_addr:
    .word 0
mlkem_z_buf_addr:
    .word 0
mlkem_mprime_buf_addr:
    .word 0
mlkem_kprime_buf_addr:
    .word 0
mlkem_rprime_buf_addr:
    .word 0
mlkem_kbar_buf_addr:
    .word 0
mlkem_ekpke_buf_addr:
    .word 0
mlkem_cprime_buf_addr:
    .word 0

.section ".text"

.macro MLKEM_SCRATCH_PAIR name
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

MLKEM_SCRATCH_PAIR mlkem_zetas
MLKEM_SCRATCH_PAIR mlkem_gammas
MLKEM_SCRATCH_PAIR mlkem_a00
MLKEM_SCRATCH_PAIR mlkem_a01
MLKEM_SCRATCH_PAIR mlkem_a10
MLKEM_SCRATCH_PAIR mlkem_a11
MLKEM_SCRATCH_PAIR mlkem_s0
MLKEM_SCRATCH_PAIR mlkem_s1
MLKEM_SCRATCH_PAIR mlkem_e0
MLKEM_SCRATCH_PAIR mlkem_e1
MLKEM_SCRATCH_PAIR mlkem_t0
MLKEM_SCRATCH_PAIR mlkem_t1
MLKEM_SCRATCH_PAIR mlkem_r0
MLKEM_SCRATCH_PAIR mlkem_r1
MLKEM_SCRATCH_PAIR mlkem_enc_e1_0
MLKEM_SCRATCH_PAIR mlkem_enc_e1_1
MLKEM_SCRATCH_PAIR mlkem_u0
MLKEM_SCRATCH_PAIR mlkem_u1
MLKEM_SCRATCH_PAIR mlkem_v
MLKEM_SCRATCH_PAIR mlkem_mu
MLKEM_SCRATCH_PAIR mlkem_w
MLKEM_SCRATCH_PAIR mlkem_e2
MLKEM_SCRATCH_PAIR mlkem_acc
MLKEM_SCRATCH_PAIR mlkem_tmp1
MLKEM_SCRATCH_PAIR mlkem_tmp2
MLKEM_SCRATCH_PAIR mlkem_rho
MLKEM_SCRATCH_PAIR mlkem_sigma
MLKEM_SCRATCH_PAIR mlkem_prf_out
MLKEM_SCRATCH_PAIR mlkem_xof_out
MLKEM_SCRATCH_PAIR mlkem_h_buf
MLKEM_SCRATCH_PAIR mlkem_z_buf
MLKEM_SCRATCH_PAIR mlkem_mprime_buf
MLKEM_SCRATCH_PAIR mlkem_kprime_buf
MLKEM_SCRATCH_PAIR mlkem_rprime_buf
MLKEM_SCRATCH_PAIR mlkem_kbar_buf
MLKEM_SCRATCH_PAIR mlkem_ekpke_buf
MLKEM_SCRATCH_PAIR mlkem_cprime_buf
