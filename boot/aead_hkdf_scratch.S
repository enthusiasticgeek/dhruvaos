/* Dhruva -- persistent scratch buffers for ChaCha20-Poly1305 AEAD
 * (RFC 8439 section 2.8) and HKDF (RFC 5869), round 67's "crypto
 * machinery a TLS 1.3 handshake needs" contribution. Same allocate-
 * once-at-boot discipline as every other scratch buffer in this
 * project.
 *
 * aead_state/working/keystream: chacha20_block/chacha20_encrypt's own
 * required scratch shapes, dedicated to AEAD use (every existing
 * caller of those two functions already allocates its own copy of
 * these rather than sharing a global one -- same pattern followed
 * here). aead_block_scratch: poly1305_mac's own per-call scratch.
 * aead_otk/aead_mac_data/aead_computed_tag: this construction's own
 * intermediates.
 *
 * hkdf_hmac_key_block/msg_scratch/inner_hash: a SEPARATE HMAC-SHA256
 * working set from round 61's own hmac_sha256 (see hkdf_hmac_sha256's
 * own comment in kernel_main.vani for why -- real authentication's
 * primitive stays untouched, this is deliberately independent).
 * hkdf_t_scratch/hkdf_hmac_input_scratch: HKDF-Expand's own
 * intermediates. */

.section ".bss"
.align 4
aead_state_addr:
    .word 0
aead_working_addr:
    .word 0
aead_keystream_addr:
    .word 0
aead_block_scratch_addr:
    .word 0
aead_otk_addr:
    .word 0
aead_mac_data_addr:
    .word 0
aead_computed_tag_addr:
    .word 0
hkdf_hmac_key_block_addr:
    .word 0
hkdf_hmac_msg_scratch_addr:
    .word 0
hkdf_hmac_inner_hash_addr:
    .word 0
hkdf_t_scratch_addr:
    .word 0
hkdf_hmac_input_scratch_addr:
    .word 0

.section ".text"

.macro AEAD_HKDF_SCRATCH_PAIR name
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

AEAD_HKDF_SCRATCH_PAIR aead_state
AEAD_HKDF_SCRATCH_PAIR aead_working
AEAD_HKDF_SCRATCH_PAIR aead_keystream
AEAD_HKDF_SCRATCH_PAIR aead_block_scratch
AEAD_HKDF_SCRATCH_PAIR aead_otk
AEAD_HKDF_SCRATCH_PAIR aead_mac_data
AEAD_HKDF_SCRATCH_PAIR aead_computed_tag
AEAD_HKDF_SCRATCH_PAIR hkdf_hmac_key_block
AEAD_HKDF_SCRATCH_PAIR hkdf_hmac_msg_scratch
AEAD_HKDF_SCRATCH_PAIR hkdf_hmac_inner_hash
AEAD_HKDF_SCRATCH_PAIR hkdf_t_scratch
AEAD_HKDF_SCRATCH_PAIR hkdf_hmac_input_scratch
