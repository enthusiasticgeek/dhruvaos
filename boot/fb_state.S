/* Dhruva round 71 -- BCM2835 VideoCore mailbox property-channel
 * framebuffer setup: HDMI display output.
 *
 * Reuses the SAME mailbox transport protocol boot/governor_state.S's
 * own governor_apply_freq_mhz already built and verified (channel 8,
 * property-tag interface, base 0x2000B800) -- generalized here into
 * mbox_property_call(buf_addr), which sends an ALREADY-BUILT buffer
 * rather than constructing one hardcoded tag internally, so vani code
 * can assemble whatever combination of tags a given call needs. Not a
 * refactor of governor_state.S itself (that code is already tested
 * and working; a from-scratch parallel implementation avoids any risk
 * to it).
 *
 * Confirmed against QEMU 10.0.0's own hw/misc/bcm2835_property.c and
 * hw/display/bcm2835_fb.c source, the same discipline as every other
 * MMIO peripheral in this project: unlike governor_apply_freq_mhz's
 * own SET_CLOCK_RATE (marked NYI under QEMU), every framebuffer
 * property tag used here -- SET_PHYSICAL/VIRTUAL_WIDTH_HEIGHT,
 * SET_DEPTH, SET_PIXEL_ORDER, FRAMEBUFFER_ALLOCATE, FRAMEBUFFER_
 * GET_PITCH -- is genuinely implemented and stateful in QEMU's own
 * device model, so this feature gets REAL round-trip verification
 * under QEMU (pitch/size actually computed from the just-requested
 * resolution+depth), not just "the call didn't hang" the way the
 * clock-rate mailbox call is limited to.
 *
 * Buffer must be 16-byte aligned (the mailbox call encodes
 * (buffer_address & ~0xF) | channel) -- same reasoning as governor_
 * mbox_buf, hence a dedicated static .bss buffer rather than
 * dhruva_alloc_bytes (which only guarantees 8-byte alignment). */

.section ".bss"
.align 4
fb_mbox_buf:
    .space 128    /* 32 words -- comfortably covers this call's real
                   * 120-byte layout (6 tags + header + end tag), see
                   * fb_init's own header comment in kernel_main.vani
                   * for the exact tag-by-tag byte accounting. */

fb_base_val:
    .word 0
fb_size_val:
    .word 0
fb_pitch_val:
    .word 0

.section ".text"

.global fb_mbox_buf_ptr
fb_mbox_buf_ptr:
    ldr r0, =fb_mbox_buf
    bx lr

.global fb_base_get
fb_base_get:
    ldr r0, =fb_base_val
    ldr r0, [r0]
    bx lr

.global fb_base_set
fb_base_set:
    ldr r1, =fb_base_val
    str r0, [r1]
    bx lr

.global fb_size_get
fb_size_get:
    ldr r0, =fb_size_val
    ldr r0, [r0]
    bx lr

.global fb_size_set
fb_size_set:
    ldr r1, =fb_size_val
    str r0, [r1]
    bx lr

.global fb_pitch_get
fb_pitch_get:
    ldr r0, =fb_pitch_val
    ldr r0, [r0]
    bx lr

.global fb_pitch_set
fb_pitch_set:
    ldr r1, =fb_pitch_val
    str r0, [r1]
    bx lr

/* i64 mbox_property_call(i64 buf_addr) -- sends buf_addr (already
 * built by the caller, already 16-byte aligned) over mailbox channel
 * 8 (property tags) and waits for the VideoCore's response. Returns 0
 * if the overall response code indicates success, 1 on failure or a
 * bounded-poll timeout (never hangs forever -- this calls into
 * hardware that might just not respond). Direct generalization of
 * governor_apply_freq_mhz's own already-verified transport logic
 * (boot/governor_state.S) -- same registers, same bounded-poll
 * constant, same barrier-before-first-peripheral-write reasoning
 * (context_switch.S's mem_barrier comment) -- just parameterized on
 * the buffer address instead of building one particular tag inline. */
.global mbox_property_call
mbox_property_call:
    stmdb sp!, {r4-r9, lr}

    mov r4, r0                        /* r4 = buf_addr */

    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5         /* DMB -- see governor_apply_freq_mhz */

    mov r8, r4
    bic r8, r8, #0xF
    orr r8, r8, #8                    /* channel 8: property tags */

    ldr r9, =0x2000B898                /* MAILBOX_STATUS */
    ldr r5, =100000                    /* bounded-poll iteration cap */

    mov r0, #0
mpc_wait_write:
    ldr r1, [r9]
    tst r1, #0x80000000                /* FULL */
    beq mpc_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt mpc_wait_write
    mov r0, #1
    ldmia sp!, {r4-r9, lr}
    bx lr

mpc_write_ready:
    ldr r1, =0x2000B8A0                /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
mpc_wait_read:
    ldr r1, [r9]
    tst r1, #0x40000000                /* EMPTY */
    bne mpc_read_not_ready
    ldr r2, =0x2000B880                /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8                         /* is this response ours? */
    beq mpc_got_response
mpc_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt mpc_wait_read
    mov r0, #1
    ldmia sp!, {r4-r9, lr}
    bx lr

mpc_got_response:
    ldr r2, [r4, #4]                   /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    moveq r0, #0
    movne r0, #1
    ldmia sp!, {r4-r9, lr}
    bx lr
