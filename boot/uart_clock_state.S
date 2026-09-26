/* 2026-09-26: real-HW investigation -- a fresh picocom capture showed
 * genuine UART bit-level corruption appearing partway through boot
 * (recognizable text like "idle"/"GOVERNOR" degrading into repeated
 * "d"/"i"/"l"/"e" fragments, and picocom's own "M-I" notation for a
 * byte with the high bit incorrectly set -- definitive proof of real
 * serial-line corruption, not a software print bug). This started
 * shortly after the CPU frequency governor's own self-test ran
 * (governor_apply_freq_mhz, boot/governor_state.S, clock id 3 = ARM),
 * stepping the ARM clock 250->450->700MHz. This project's own UART
 * init (kernel_main.vani) computes its baud-rate divisor (IBRD/FBRD)
 * from a HARDCODED "assumed 3MHz UART clock" -- never queried live.
 * On real Broadcom SoCs the UART clock domain is *supposed* to be
 * independent of the ARM/core clock, but whether that holds on THIS
 * board's actual firmware/config.txt is unconfirmed -- a well-known
 * real Raspberry Pi gotcha (UART baud drifting when core/ARM clock
 * changes) exists for exactly this class of shared-PLL dependency on
 * some firmware/config combinations.
 *
 * This is a direct, evidence-first test of that hypothesis: query the
 * UART clock rate (VideoCore mailbox GET_CLOCK_RATE, clock id 2 =
 * UART -- see the Broadcom mailbox property interface's own clock ID
 * enum) at two points -- once early at boot, before the governor's
 * self-test ever runs, and once again immediately after it. If the
 * two readings differ, that's direct, conclusive proof the UART clock
 * genuinely shifts with the governor's own ARM-clock changes on this
 * hardware. If they're identical, this hypothesis is wrong and the
 * real cause is something else.
 *
 * Structurally a near-duplicate of boot/sdcard_state.S's own
 * sdhost_get_core_clock_hz (clock id 4 = CORE) -- deliberately kept
 * separate rather than shared/parameterized, matching this project's
 * own established preference (boot/rpi1/uboot_sdhost_write.c's own
 * header comment) for independent, self-contained diagnostic code
 * over introducing a new shared dependency into an already-scrutinized
 * path, especially one this timing-sensitive. */

.section ".bss"
.align 4
uart_clock_mbox_buf:
    .space 32

.section ".text"

/* i64 uart_get_clock_hz() -- returns the UART clock rate in Hz on
 * success, 0 if the mailbox call timed out or reported failure. */
.global uart_get_clock_hz
uart_get_clock_hz:
    stmdb sp!, {r4-r8, lr}

    ldr r4, =uart_clock_mbox_buf

    mov r7, #32
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00030002
    str r7, [r4, #8]                 /* buf[2]: tag = get clock rate */
    mov r7, #8
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    mov r7, #2
    str r7, [r4, #20]                /* buf[5]: clock id (2 = UART) */
    mov r7, #0
    str r7, [r4, #24]                /* buf[6]: rate in Hz (response) */
    str r7, [r4, #28]                /* buf[7]: end tag */

    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5

    mov r8, r4
    bic r8, r8, #0xF
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r6, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
ugch_wait_write:
    ldr r1, [r6]
    tst r1, #0x80000000              /* FULL */
    beq ugch_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt ugch_wait_write
    mov r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

ugch_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
ugch_wait_read:
    ldr r1, [r6]
    tst r1, #0x40000000              /* EMPTY */
    bne ugch_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8
    beq ugch_got_response
ugch_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt ugch_wait_read
    mov r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

ugch_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    bne ugch_failed
    ldr r0, [r4, #24]                /* buf[6]: rate in Hz */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
ugch_failed:
    mov r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
