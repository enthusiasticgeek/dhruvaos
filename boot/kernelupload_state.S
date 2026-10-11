/* A/B kernel slots, Phase 4 -- persistent scratch state for the
 * `kernelupload` shell command. Same shape as boot/usb_wifi_state.S's
 * own usb_wifi_fw_buf/_chunk/_upload_len (fixed .bss arrays/words, not
 * heap-allocated -- this state is small and fixed-size, no need for
 * dhruva_alloc_bytes at all).
 *
 * kernelupload_block_buf: one 512-byte SD block's worth of
 * accumulation, filled 48 bytes at a time by `kernelupload chunk`,
 * flushed via sdhost_write_block once full -- kernelupload never
 * holds more than one block of the uploaded image in memory at once,
 * unlike wifikey's own whole-file 16KB buffer (a multi-MB kernel image
 * doesn't fit in this project's 768KB heap, let alone .bss).
 *
 * kernelupload_sha_ctx: a serialized vani-crypto-hash Sha256Ctx
 * (`h: [u32;8], carry: [u8;64], carry_len: i64, total_len: u64` --
 * 32+64+8+8 = 112 bytes), persisted across many `chunk` calls the same
 * way kernel_main.vani's own sha256_hash adapter already walks this
 * same struct within a single call -- here it has to survive BETWEEN
 * calls instead, since the whole image is never in memory at once to
 * hash in one shot.
 *
 * kernelupload_total_len: running byte count received so far this
 * upload session (also the write offset, in bytes, from the target
 * slot's own base block).
 *
 * kernelupload_target_slot: which slot (0=A, 1=B) is being written to
 * -- always the INACTIVE slot, decided once at the first `chunk` of a
 * fresh upload (kernelupload_active transitions 0->1) and held fixed
 * until `commit`/`abort`.
 */
.section ".bss"
.align 4
kernelupload_block_buf:
    .space 512
kernelupload_sha_ctx:
    .space 112
kernelupload_total_len:
    .space 4
kernelupload_target_slot:
    .space 4
kernelupload_active:
    .space 4
/* Decode scratch for one `chunk` call's hex -- same 48-byte cap as
 * wifikey's own chunk size (shell line buffer limit, see
 * shell_dispatch_wifikey's own comment), kept separate from
 * usb_wifi_fw_chunk rather than sharing it, since the two features
 * are conceptually unrelated even though both are only ever driven
 * interactively by the same single task (task_f) and so could
 * technically share safely. */
kernelupload_chunk_decode_buf:
    .space 48
/* Dedicated scratch for reading/writing the 512-byte slot-state
 * record (blocks 9216/9217) -- deliberately separate from
 * kernelupload_block_buf (which only ever holds kernel-PAYLOAD bytes
 * mid-upload) and from dharafs_sd_scratch (DharaFS's own general-
 * purpose raw-block buffer), so kernelslot/kernelupload's own slot-
 * state reads can never clobber either mid-operation. */
kernelslot_record_buf:
    .space 512

.section ".text"

.global kernelupload_block_buf_get
kernelupload_block_buf_get:
    ldr r0, =kernelupload_block_buf
    mov r1, #0
    bx lr

.global kernelupload_sha_ctx_get
kernelupload_sha_ctx_get:
    ldr r0, =kernelupload_sha_ctx
    mov r1, #0
    bx lr

.global kernelupload_total_len_get
kernelupload_total_len_get:
    ldr r0, =kernelupload_total_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_total_len_set
kernelupload_total_len_set:
    ldr r1, =kernelupload_total_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_target_slot_get
kernelupload_target_slot_get:
    ldr r0, =kernelupload_target_slot
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_target_slot_set
kernelupload_target_slot_set:
    ldr r1, =kernelupload_target_slot
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_active_get
kernelupload_active_get:
    ldr r0, =kernelupload_active
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_active_set
kernelupload_active_set:
    ldr r1, =kernelupload_active
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_chunk_decode_buf_get
kernelupload_chunk_decode_buf_get:
    ldr r0, =kernelupload_chunk_decode_buf
    mov r1, #0
    bx lr

.global kernelslot_record_buf_get
kernelslot_record_buf_get:
    ldr r0, =kernelslot_record_buf
    mov r1, #0
    bx lr
