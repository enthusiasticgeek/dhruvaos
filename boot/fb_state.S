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

/* BUG (round 71 audit, 2026-09-05): fb_base_get/fb_size_get/fb_pitch_
 * get are declared `-> i64` in kernel_main.vani, which under AAPCS
 * means a genuine 64-bit return value split across the r0:r1
 * register PAIR (r0=low 32 bits, r1=high 32 bits) -- these functions
 * only ever set r0, leaving r1 as whatever garbage happened to be
 * left over from an earlier call. Harmless for a caller that only
 * ever uses the return value as a plain address (r0 alone is
 * correct there) -- but fb_self_check's own last_x computation
 * (`fb_pitch_get() / 4`) treats the return value as a REAL signed
 * 64-bit quantity, and the compiler-generated 64-bit division
 * correctly assumes r1 holds real data per the ABI contract it was
 * promised. Garbage in r1 corrupted that division's result,
 * producing a wildly wrong last_x (still correct in its low ~10
 * bits, which is what made this look so much like a narrow, obscure
 * bug rather than the fairly ordinary ABI-contract violation it
 * actually is) that fb_fill_pixel's own bounds check then correctly
 * (and silently) rejected as out-of-range, so the far-corner pixel
 * write never happened at all.
 *
 * Found via GDB against the real failing build (not guessed): traced
 * bad values all the way back through fb_fill_pixel's own received
 * arguments to this exact division, then to fb_pitch_get's own
 * incomplete i64 return. Originally misdiagnosed one level too
 * shallow as a vani/LLVM compiler bug (a `let`-bound intermediate
 * happened to reuse a register that coincidentally still held zero,
 * masking the same underlying garbage-r1 bug rather than fixing it)
 * -- retracted once GDB actually proved the real cause. Fixed by
 * explicitly zeroing r1 in all three getters below: these values are
 * always non-negative 32-bit quantities, so zero-extension is always
 * the correct 64-bit representation. */
.global fb_base_get
fb_base_get:
    ldr r0, =fb_base_val
    ldr r0, [r0]
    mov r1, #0
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
    mov r1, #0
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
    mov r1, #0
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
 * the buffer address instead of building one particular tag inline.
 *
 * BUG (round 71 audit, 2026-09-05): this function is declared `-> i64`
 * in kernel_main.vani (genuine 64-bit AAPCS return, r0:r1 pair), but
 * all three of its original exit paths only ever set r0, leaving r1
 * as garbage -- despite this function's own header comment claiming
 * to be a direct generalization of governor_apply_freq_mhz, which
 * gets this right (explicit `mov r1, #0` on every one of its own
 * three exit paths). Found via the same GDB-traced investigation that
 * found the identical bug in this file's fb_base_get/_size_get/
 * _pitch_get (see their own shared comment for the full story) --
 * swept here too once the bug CLASS was identified, not just the one
 * instance that happened to be actively causing a visible failure.
 * fb_init's own `if status != 0 { return status; }` check on this
 * function's return value could have spuriously treated a real
 * success (r0=0) as a failure whenever leftover r1 garbage made the
 * full 64-bit value non-zero -- not proven to have actually fired
 * (fb_init passed in every test run so far), but a real, confirmed
 * ABI violation regardless, fixed the same way: explicit `mov r1, #0`
 * on every exit path, matching governor_apply_freq_mhz's own
 * already-correct convention this function was supposed to copy. */
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
    mov r1, #0
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
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

mpc_got_response:
    ldr r2, [r4, #4]                   /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    moveq r0, #0
    movne r0, #1
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr
