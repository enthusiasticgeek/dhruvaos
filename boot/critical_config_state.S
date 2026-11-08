/* Critical Config Store -- persistent scratch state for the
 * `critconfig` shell command and the boot-time config readers
 * (wifi_config_init/ble_config_init) that migrate onto it.
 *
 * See kernel_main.vani's own block-layout comment (next to
 * rtl8188cu_fw_raw_sd_base_block's) for the full design rationale:
 * this exists specifically so small boot-critical config/credentials
 * (WiFi SSID/password, BLE target name, and future additions) are
 * available on EVERY boot regardless of DharaFS Tier 1/2/3 recovery
 * state -- they live in their own dedicated raw-block region (blocks
 * 8224-8255), entirely outside DharaFS's append-only log, the same
 * architectural move this project already made once for kernel-slot
 * state (kernelslot_record_buf below).
 *
 * critical_config_table_scratch: one full in-RAM copy of the 32-slot
 * x 256-byte table (8192 bytes) -- loaded from whichever on-disk copy
 * (of the two ping-ponged copies) has the higher generation, modified
 * in place by a write, then flushed back out to BOTH on-disk copies.
 * Deliberately a whole-table buffer (not a single-block scratch like
 * dharafs_sd_scratch) so find_slot's linear key scan is a simple
 * direct byte-offset walk, no block-boundary bookkeeping.
 *
 * critical_config_key_scratch: Str-literal-to-bytes conversion
 * scratch for the convenience wrappers (critical_config_read/_write,
 * which take a Str key the way dharafs_read's own Str overload does)
 * -- separate from dharafs_path_scratch so the two features can never
 * clobber each other mid-call.
 *
 * critical_config_crypto_key / _crypto_key_ready: this store derives
 * and caches its OWN ChaCha20-Poly1305 key, independently of DharaFS
 * media encryption's dharafs_crypto_key_ptr -- deliberately NOT
 * shared, because dharafs_crypto_key_init() runs AFTER wifi_config_
 * init()/ble_config_init() in the boot sequence (kernel_main.vani),
 * and this store's whole point is working correctly regardless of
 * DharaFS-related boot ordering. Derived once, lazily, on first use.
 *
 * critical_config_nonce_scratch / _aad_scratch: transient per-call
 * buffers for the AEAD calls (nonce = slot index + per-slot counter,
 * AAD = slot index -- same binding-the-tag-to-its-own-location
 * reasoning as dharafs_crypto_encrypt_block's own AAD=block_num).
 *
 * critical_config_plain_scratch: transient decrypted-plaintext output
 * buffer for a read of an encrypted slot (max value size, 196 bytes).
 */
.section ".bss"
.align 4
critical_config_table_scratch:
    .space 8192
critical_config_key_scratch:
    .space 32
critical_config_crypto_key:
    .space 32
critical_config_crypto_key_ready:
    .space 4
critical_config_nonce_scratch:
    .space 12
critical_config_aad_scratch:
    .space 8
critical_config_plain_scratch:
    .space 196

.text
.global critical_config_table_scratch_get
critical_config_table_scratch_get:
    ldr r0, =critical_config_table_scratch
    mov r1, #0
    bx lr

.global critical_config_key_scratch_get
critical_config_key_scratch_get:
    ldr r0, =critical_config_key_scratch
    mov r1, #0
    bx lr

.global critical_config_crypto_key_get
critical_config_crypto_key_get:
    ldr r0, =critical_config_crypto_key
    mov r1, #0
    bx lr

.global critical_config_crypto_key_ready_get
critical_config_crypto_key_ready_get:
    ldr r0, =critical_config_crypto_key_ready
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global critical_config_crypto_key_ready_set
critical_config_crypto_key_ready_set:
    ldr r1, =critical_config_crypto_key_ready
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global critical_config_nonce_scratch_get
critical_config_nonce_scratch_get:
    ldr r0, =critical_config_nonce_scratch
    mov r1, #0
    bx lr

.global critical_config_aad_scratch_get
critical_config_aad_scratch_get:
    ldr r0, =critical_config_aad_scratch
    mov r1, #0
    bx lr

.global critical_config_plain_scratch_get
critical_config_plain_scratch_get:
    ldr r0, =critical_config_plain_scratch
    mov r1, #0
    bx lr
