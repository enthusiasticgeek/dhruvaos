/* Dhruva round 69 -- DharaFS media encryption, AEAD upgrade.
 *
 * Dedicated scratch for DharaFS's own ChaCha20-Poly1305 AEAD use and
 * its new per-block metadata (write counter + tag), deliberately NOT
 * shared with TLS 1.3's own AEAD scratch (boot/aead_hkdf_scratch.S)
 * even though the underlying primitive is the same function
 * (chacha20_poly1305_encrypt/decrypt) -- this project's own single-
 * core, preemptible scheduler means a DharaFS block read/write
 * (reachable from ANY task, including task_e's background compaction)
 * could interrupt a `tlsecho` task mid-AEAD-computation; sharing one
 * scratch set between the two would let one clobber the other's
 * in-progress state.
 *
 * Fixed static buffers, same pattern boot/media_crypto_state.S (this
 * feature's own original scratch file) already established -- not
 * the dhruva_alloc_bytes-backed SCRATCH_PAIR indirection some other
 * files in this project use, matching the file this one directly
 * extends rather than introducing a second style for the same
 * feature. */

.section ".bss"
.align 4
dharafs_crypto_block_scratch_buf:
    .space 16    /* poly1305_mac's own per-call scratch */
dharafs_crypto_otk_scratch_buf:
    .space 32    /* one-time-key */
dharafs_crypto_mac_data_scratch_buf:
    .space 576   /* AAD(8)+pad(8)+data(512)+pad(0)+lengths(16) = 544, rounded up */
dharafs_crypto_computed_tag_scratch_buf:
    .space 16    /* decrypt's own recomputed tag, for comparison */
dharafs_crypto_tag_scratch_buf:
    .space 16    /* the tag being written to/read from metadata */
dharafs_crypto_aad_scratch_buf:
    .space 8     /* holds block_num (as AAD) */
dharafs_crypto_meta_sector_scratch_buf:
    .space 512   /* one metadata sector, for read-modify-write */

.section ".text"

.global dharafs_crypto_block_scratch_ptr
dharafs_crypto_block_scratch_ptr:
    ldr r0, =dharafs_crypto_block_scratch_buf
    bx lr

.global dharafs_crypto_otk_scratch_ptr
dharafs_crypto_otk_scratch_ptr:
    ldr r0, =dharafs_crypto_otk_scratch_buf
    bx lr

.global dharafs_crypto_mac_data_scratch_ptr
dharafs_crypto_mac_data_scratch_ptr:
    ldr r0, =dharafs_crypto_mac_data_scratch_buf
    bx lr

.global dharafs_crypto_computed_tag_scratch_ptr
dharafs_crypto_computed_tag_scratch_ptr:
    ldr r0, =dharafs_crypto_computed_tag_scratch_buf
    bx lr

.global dharafs_crypto_tag_scratch_ptr
dharafs_crypto_tag_scratch_ptr:
    ldr r0, =dharafs_crypto_tag_scratch_buf
    bx lr

.global dharafs_crypto_aad_scratch_ptr
dharafs_crypto_aad_scratch_ptr:
    ldr r0, =dharafs_crypto_aad_scratch_buf
    bx lr

.global dharafs_crypto_meta_sector_scratch_ptr
dharafs_crypto_meta_sector_scratch_ptr:
    ldr r0, =dharafs_crypto_meta_sector_scratch_buf
    bx lr
