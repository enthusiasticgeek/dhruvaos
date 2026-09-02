/* Dhruva -- persistent scratch buffers for Ed25519 (RFC 8032).
 * Same discipline as boot/x25519_scratch.S's own header comment:
 * allocate exactly once at boot, never per-call, plain word-pointer
 * accessors generated via the same .macro pattern already proven to
 * assemble cleanly in that file.
 *
 * Points are represented as 4 separate 32-byte field-element buffers
 * (X, Y, Z, T -- extended twisted-Edwards coordinates), not a single
 * packed struct, matching X25519's own "named buffers, not pointer
 * arithmetic" convention (vani has no way to offset into the middle
 * of an existing buffer). ed25519_point_add's own 8 internal
 * temporaries (A..H in the standard "add-2008-hwcd" formula) are
 * shared with point decompression's own scratch needs (tmp1..tmp8) --
 * verified safe by construction, since neither ever calls the other
 * mid-computation.
 *
 * qx/qy/qz/qt + bx/by/bz/bt: the scalar-multiplication ladder's own
 * accumulator and doubling-base points, verified safe for IN-PLACE
 * point_add (out buffers aliased with an input point) via a dedicated
 * host-side Python simulation before any of this was ported -- see
 * kernel_main.vani's own header comment on ed25519_point_add.
 *
 * scalar_remainder/scalar_product/scalar_sum: scalar-mod-L reduction
 * scratch (see ed25519_scalar_mod_l_raw's own comment for why this
 * needs a genuine bit-by-bit binary long division, not a fold like
 * field25519's own p=2^255-19 reduction -- L's own "small" part isn't
 * actually small).
 *
 * hash_input: shared scratch for building SHA-512 inputs
 * (prefix||msg for the nonce, R||A||msg for the challenge) -- sized
 * generously (4096, this project's own dharafs_file_max_len() bound,
 * plus 96 bytes of fixed prefix/R/A headroom). */

.section ".bss"
.align 4
ed25519_d_addr:
    .word 0
ed25519_2d_addr:
    .word 0
ed25519_sqrt_m1_addr:
    .word 0
ed25519_l_addr:
    .word 0
ed25519_gx_addr:
    .word 0
ed25519_gy_addr:
    .word 0
ed25519_gz_addr:
    .word 0
ed25519_gt_addr:
    .word 0
ed25519_tmp1_addr:
    .word 0
ed25519_tmp2_addr:
    .word 0
ed25519_tmp3_addr:
    .word 0
ed25519_tmp4_addr:
    .word 0
ed25519_tmp5_addr:
    .word 0
ed25519_tmp6_addr:
    .word 0
ed25519_tmp7_addr:
    .word 0
ed25519_tmp8_addr:
    .word 0
ed25519_qx_addr:
    .word 0
ed25519_qy_addr:
    .word 0
ed25519_qz_addr:
    .word 0
ed25519_qt_addr:
    .word 0
ed25519_bx_addr:
    .word 0
ed25519_by_addr:
    .word 0
ed25519_bz_addr:
    .word 0
ed25519_bt_addr:
    .word 0
ed25519_scalar_remainder_addr:
    .word 0
ed25519_scalar_product_addr:
    .word 0
ed25519_scalar_sum_addr:
    .word 0
ed25519_hash_input_addr:
    .word 0
ed25519_hash_out_addr:
    .word 0
ed25519_buf1_addr:
    .word 0
ed25519_buf2_addr:
    .word 0
ed25519_buf3_addr:
    .word 0
ed25519_buf4_addr:
    .word 0
ed25519_buf5_addr:
    .word 0
ed25519_buf6_addr:
    .word 0
ed25519_buf7_addr:
    .word 0
ed25519_buf8_addr:
    .word 0
ed25519_ax_addr:
    .word 0
ed25519_ay_addr:
    .word 0
ed25519_az_addr:
    .word 0
ed25519_at_addr:
    .word 0
ed25519_rx_addr:
    .word 0
ed25519_ry_addr:
    .word 0
ed25519_rz_addr:
    .word 0
ed25519_rt_addr:
    .word 0
ed25519_kax_addr:
    .word 0
ed25519_kay_addr:
    .word 0
ed25519_kaz_addr:
    .word 0
ed25519_kat_addr:
    .word 0
ed25519_sbx_addr:
    .word 0
ed25519_sby_addr:
    .word 0
ed25519_sbz_addr:
    .word 0
ed25519_sbt_addr:
    .word 0

.section ".text"

.macro ED25519_SCRATCH_PAIR name
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

ED25519_SCRATCH_PAIR ed25519_d
ED25519_SCRATCH_PAIR ed25519_2d
ED25519_SCRATCH_PAIR ed25519_sqrt_m1
ED25519_SCRATCH_PAIR ed25519_l
ED25519_SCRATCH_PAIR ed25519_gx
ED25519_SCRATCH_PAIR ed25519_gy
ED25519_SCRATCH_PAIR ed25519_gz
ED25519_SCRATCH_PAIR ed25519_gt
ED25519_SCRATCH_PAIR ed25519_tmp1
ED25519_SCRATCH_PAIR ed25519_tmp2
ED25519_SCRATCH_PAIR ed25519_tmp3
ED25519_SCRATCH_PAIR ed25519_tmp4
ED25519_SCRATCH_PAIR ed25519_tmp5
ED25519_SCRATCH_PAIR ed25519_tmp6
ED25519_SCRATCH_PAIR ed25519_tmp7
ED25519_SCRATCH_PAIR ed25519_tmp8
ED25519_SCRATCH_PAIR ed25519_qx
ED25519_SCRATCH_PAIR ed25519_qy
ED25519_SCRATCH_PAIR ed25519_qz
ED25519_SCRATCH_PAIR ed25519_qt
ED25519_SCRATCH_PAIR ed25519_bx
ED25519_SCRATCH_PAIR ed25519_by
ED25519_SCRATCH_PAIR ed25519_bz
ED25519_SCRATCH_PAIR ed25519_bt
ED25519_SCRATCH_PAIR ed25519_scalar_remainder
ED25519_SCRATCH_PAIR ed25519_scalar_product
ED25519_SCRATCH_PAIR ed25519_scalar_sum
ED25519_SCRATCH_PAIR ed25519_hash_input
ED25519_SCRATCH_PAIR ed25519_hash_out
ED25519_SCRATCH_PAIR ed25519_buf1
ED25519_SCRATCH_PAIR ed25519_buf2
ED25519_SCRATCH_PAIR ed25519_buf3
ED25519_SCRATCH_PAIR ed25519_buf4
ED25519_SCRATCH_PAIR ed25519_buf5
ED25519_SCRATCH_PAIR ed25519_buf6
ED25519_SCRATCH_PAIR ed25519_buf7
ED25519_SCRATCH_PAIR ed25519_buf8
ED25519_SCRATCH_PAIR ed25519_ax
ED25519_SCRATCH_PAIR ed25519_ay
ED25519_SCRATCH_PAIR ed25519_az
ED25519_SCRATCH_PAIR ed25519_at
ED25519_SCRATCH_PAIR ed25519_rx
ED25519_SCRATCH_PAIR ed25519_ry
ED25519_SCRATCH_PAIR ed25519_rz
ED25519_SCRATCH_PAIR ed25519_rt
ED25519_SCRATCH_PAIR ed25519_kax
ED25519_SCRATCH_PAIR ed25519_kay
ED25519_SCRATCH_PAIR ed25519_kaz
ED25519_SCRATCH_PAIR ed25519_kat
ED25519_SCRATCH_PAIR ed25519_sbx
ED25519_SCRATCH_PAIR ed25519_sby
ED25519_SCRATCH_PAIR ed25519_sbz
ED25519_SCRATCH_PAIR ed25519_sbt
