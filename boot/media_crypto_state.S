/* Dhruva -- persistent state for media (at-rest) encryption of
 * DharaFS's own on-disk blocks, layered on round 44's existing
 * ChaCha20 stream cipher (RFC 8439) rather than introducing a new
 * cipher primitive -- this project already has a real, KAT-verified
 * cipher; there is no need to add AES just to get encryption working
 * (AES itself, if ever wanted for spec/interop reasons, stays a
 * separate, independent backlog item).
 *
 * All scratch is persistent, reused sequentially (never concurrently
 * -- single-core, and DharaFS's own block I/O is already single-
 * threaded-per-call), same "persistent scratch, not per-call
 * dhruva_alloc_bytes" discipline this project's other crypto
 * primitives already established (sha256_hash's own round-48 fix,
 * auth_state.S's HMAC/PBKDF2 scratch).
 *
 * dharafs_crypto_enabled defaults to 0 (OFF) -- every existing test
 * (phase4_milestone.py, heap_stress.py, power_yank.py, the host
 * harness) keeps running against plaintext blocks, completely
 * unchanged, unless something explicitly turns this on. Matches round
 * 36's own dharafs_block_dev toggle pattern (0=SDHOST default,
 * flipped only by a dedicated self-check, never by a real FS
 * operation) exactly. */

.equ CRYPTO_KEY_LEN, 32
.equ CRYPTO_NONCE_LEN, 12

.section ".bss"
.align 4
dharafs_crypto_enabled:
    .word 0
dharafs_crypto_key:
    .space CRYPTO_KEY_LEN
dharafs_crypto_nonce:
    .space CRYPTO_NONCE_LEN
dharafs_crypto_state_buf:
    .space 64
dharafs_crypto_working_buf:
    .space 64
dharafs_crypto_keystream_buf:
    .space 512
dharafs_crypto_scratch_buf:
    .space 512

.section ".text"

.global dharafs_crypto_get_enabled
dharafs_crypto_get_enabled:
    ldr r0, =dharafs_crypto_enabled
    ldr r0, [r0]
    bx lr

.global dharafs_crypto_set_enabled
dharafs_crypto_set_enabled:
    ldr r1, =dharafs_crypto_enabled
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_crypto_key_ptr
dharafs_crypto_key_ptr:
    ldr r0, =dharafs_crypto_key
    bx lr

.global dharafs_crypto_nonce_ptr
dharafs_crypto_nonce_ptr:
    ldr r0, =dharafs_crypto_nonce
    bx lr

.global dharafs_crypto_state_ptr
dharafs_crypto_state_ptr:
    ldr r0, =dharafs_crypto_state_buf
    bx lr

.global dharafs_crypto_working_ptr
dharafs_crypto_working_ptr:
    ldr r0, =dharafs_crypto_working_buf
    bx lr

.global dharafs_crypto_keystream_ptr
dharafs_crypto_keystream_ptr:
    ldr r0, =dharafs_crypto_keystream_buf
    bx lr

.global dharafs_crypto_scratch_ptr
dharafs_crypto_scratch_ptr:
    ldr r0, =dharafs_crypto_scratch_buf
    bx lr
