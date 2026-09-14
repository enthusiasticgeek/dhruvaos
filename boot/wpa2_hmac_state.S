/* Dhruva -- persistent scratch for HMAC-SHA1/PBKDF2-HMAC-SHA1 (task
 * #164 WPA2-PSK groundwork). A dedicated, SEPARATE scratch set from
 * auth_state.S's own HMAC-SHA256/PBKDF2-HMAC-SHA256 scratch and
 * aead_hkdf_scratch.S's own separate HMAC-SHA256 scratch -- same
 * reasoning aead_hkdf_scratch.S's own header comment already gives for
 * why IT needed its own set distinct from auth_state.S's: two
 * logically independent subsystems (su/passwd auth, TLS/AEAD key
 * derivation, and now WPA2 WiFi association) can genuinely be in
 * flight on different tasks at the same time on this project's
 * preemptive scheduler, so sharing one scratch set across them would
 * be a real re-entrancy hazard, not just an aesthetic preference.
 * "Persistent scratch, never per-call dhruva_alloc_bytes" -- this
 * project's own established discipline (see boot/scratch_state.S's
 * own getter/setter convention).
 *
 * Sized for SHA-1's own 20-byte digest and 64-byte block (not
 * SHA-256's 32/64) -- hmac_sha1_msg_scratch's 128 bytes still
 * comfortably covers a 64-byte pad block plus up to a 64-byte message,
 * matching auth_state.S's own hmac_msg_scratch sizing rationale.
 * pbkdf2_sha1_salt_ctr_scratch's 36 bytes covers WPA2's own SSID (up
 * to 32 bytes, IEEE 802.11's real maximum) plus PBKDF2's 4-byte
 * big-endian block-index suffix. */

.section ".bss"
.align 4
hmac_sha1_key_block_scratch:
    .space 64
hmac_sha1_msg_scratch:
    .space 128
hmac_sha1_inner_hash_scratch:
    .space 20
pbkdf2_sha1_u_scratch:
    .space 20
pbkdf2_sha1_t_scratch:
    .space 20
pbkdf2_sha1_salt_ctr_scratch:
    .space 36

.section ".text"

.global hmac_sha1_key_block_ptr
hmac_sha1_key_block_ptr:
    ldr r0, =hmac_sha1_key_block_scratch
    bx lr

.global hmac_sha1_msg_scratch_ptr
hmac_sha1_msg_scratch_ptr:
    ldr r0, =hmac_sha1_msg_scratch
    bx lr

.global hmac_sha1_inner_hash_ptr
hmac_sha1_inner_hash_ptr:
    ldr r0, =hmac_sha1_inner_hash_scratch
    bx lr

.global pbkdf2_sha1_u_ptr
pbkdf2_sha1_u_ptr:
    ldr r0, =pbkdf2_sha1_u_scratch
    bx lr

.global pbkdf2_sha1_t_ptr
pbkdf2_sha1_t_ptr:
    ldr r0, =pbkdf2_sha1_t_scratch
    bx lr

.global pbkdf2_sha1_salt_ctr_ptr
pbkdf2_sha1_salt_ctr_ptr:
    ldr r0, =pbkdf2_sha1_salt_ctr_scratch
    bx lr
