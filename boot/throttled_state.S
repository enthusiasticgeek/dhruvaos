/* 2026-09-26: real-HW investigation, second hypothesis after directly
 * ruling out the first. A fresh picocom capture confirmed real UART
 * bit-level corruption appearing well into boot -- but a direct
 * real-HW test (boot/uart_clock_state.S) proved the UART's own clock
 * rate stays fixed at 3MHz even across a real ARM-clock change via
 * governor_apply_freq_mhz(700), ruling out "UART clock tied to the
 * CPU governor" as the cause.
 *
 * The CPU frequency governor ramping the ARM core up to 700MHz DOES
 * draw more current, though -- and this project's own independent SD
 * investigation has ALREADY found real, hardware-reported signal-
 * integrity symptoms (CMD_TIMEOUT, CRC16, FIFO_ERROR) on this exact
 * physical board. A marginal power supply or wiring sagging under
 * load could plausibly degrade BOTH UART and SD signal integrity at
 * once, even though each peripheral's own clock source stays
 * technically correct -- exactly the kind of thing that would explain
 * two seemingly separate investigations sharing one root cause.
 *
 * Real Raspberry Pi firmware exposes this directly and unambiguously:
 * the VideoCore mailbox's GET_THROTTLED property tag (0x00030046)
 * reports genuine hardware-detected undervoltage/throttling events,
 * independent of anything this codebase's own software does. Bit
 * layout (Raspberry Pi firmware's own documented convention):
 *   bit 0  - under-voltage detected (right now)
 *   bit 1  - ARM frequency capped (right now)
 *   bit 2  - currently throttled
 *   bit 3  - soft temperature limit active
 *   bit 16 - under-voltage has occurred since boot
 *   bit 17 - ARM frequency capping has occurred since boot
 *   bit 18 - throttling has occurred since boot
 *   bit 19 - soft temperature limit has occurred since boot
 * A nonzero bit 0 or bit 16 here is direct, hardware-level proof of a
 * real power-supply problem -- not a guess, not inferred from
 * secondary symptoms. */

.section ".bss"
.align 4
throttled_mbox_buf:
    .space 32

.section ".text"

/* i64 get_throttled_status() -- returns the raw THROTTLED bitmask on
 * success, or -1 (all bits set, never a real hardware value -- the
 * real register never returns 0xFFFFFFFF) if the mailbox call timed
 * out or reported failure, matching this codebase's own established
 * "a sentinel distinguishable from every real answer" convention. */
.global get_throttled_status
get_throttled_status:
    stmdb sp!, {r4-r8, lr}

    ldr r4, =throttled_mbox_buf

    mov r7, #32
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00030046
    str r7, [r4, #8]                 /* buf[2]: tag = get throttled */
    mov r7, #4
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    str r7, [r4, #20]                /* buf[5]: throttled bits (response) */
    str r7, [r4, #24]                /* buf[6]: end tag */

    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5

    mov r8, r4
    bic r8, r8, #0xF
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r6, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
gts_wait_write:
    ldr r1, [r6]
    tst r1, #0x80000000              /* FULL */
    beq gts_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt gts_wait_write
    mvn r0, #0                       /* timed out -- -1 sentinel */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

gts_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
gts_wait_read:
    ldr r1, [r6]
    tst r1, #0x40000000              /* EMPTY */
    bne gts_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8
    beq gts_got_response
gts_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt gts_wait_read
    mvn r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

gts_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    bne gts_failed
    ldr r0, [r4, #20]                /* buf[5]: throttled bits */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
gts_failed:
    mvn r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
