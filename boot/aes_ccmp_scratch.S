/* Dhruva -- persistent scratch for AES-CCMP (task #164 WPA2-PSK
 * groundwork). "Persistent scratch, never per-call dhruva_alloc_bytes"
 * -- this will eventually be called once per real data frame, once
 * WPA2 data-frame wiring exists, so it needs the same discipline every
 * other frequently-called crypto primitive in this project already
 * follows (see boot/scratch_state.S's own getter/setter convention).
 *
 * w/state/temp mirror aes128_encrypt_block's own three scratch
 * parameters (round-key schedule, cipher state, ShiftRows temp) --
 * CCMP calls that function many times per packet (once per CBC-MAC
 * block, once per CTR counter block), all sharing this one scratch
 * set since CCMP's own construction never needs two AES operations
 * live at once.
 *
 * b/x/a/s_block are CCM's own working blocks: b_block is the block
 * currently being fed into AES (B_0, an AAD/plaintext CBC-MAC input
 * block, or a counter block A_i); x_block is the running CBC-MAC
 * accumulator; a_block/s_block are the CTR-mode counter block and its
 * resulting keystream. computed_tag holds a decrypt call's own
 * freshly-recomputed MAC, compared against the tag the caller
 * supplied -- kept separate from x_block so aes_ccmp_decrypt can still
 * read x_block's own final value after computing the comparison. */

.section ".bss"
.align 4
aes_ccmp_w_scratch:
    .space 176
aes_ccmp_state_scratch:
    .space 16
aes_ccmp_temp_scratch:
    .space 4
aes_ccmp_b_block:
    .space 16
aes_ccmp_x_block:
    .space 16
aes_ccmp_a_block:
    .space 16
aes_ccmp_s_block:
    .space 16
aes_ccmp_computed_tag:
    .space 16

.section ".text"

.global aes_ccmp_w_ptr
aes_ccmp_w_ptr:
    ldr r0, =aes_ccmp_w_scratch
    bx lr

.global aes_ccmp_state_ptr
aes_ccmp_state_ptr:
    ldr r0, =aes_ccmp_state_scratch
    bx lr

.global aes_ccmp_temp_ptr
aes_ccmp_temp_ptr:
    ldr r0, =aes_ccmp_temp_scratch
    bx lr

.global aes_ccmp_b_block_ptr
aes_ccmp_b_block_ptr:
    ldr r0, =aes_ccmp_b_block
    bx lr

.global aes_ccmp_x_block_ptr
aes_ccmp_x_block_ptr:
    ldr r0, =aes_ccmp_x_block
    bx lr

.global aes_ccmp_a_block_ptr
aes_ccmp_a_block_ptr:
    ldr r0, =aes_ccmp_a_block
    bx lr

.global aes_ccmp_s_block_ptr
aes_ccmp_s_block_ptr:
    ldr r0, =aes_ccmp_s_block
    bx lr

.global aes_ccmp_computed_tag_ptr
aes_ccmp_computed_tag_ptr:
    ldr r0, =aes_ccmp_computed_tag
    bx lr
