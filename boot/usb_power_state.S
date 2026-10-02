/* USB HCD power-on via the VideoCore mailbox property interface
 * (task #197 follow-up, real-HW USB bring-up investigation, 2026-10-
 * 02) -- confirmed against multiple independent real-hardware bare-
 * metal Pi references (not QEMU source, since QEMU's raspi1ap model
 * never power-gates the DWC2 block at all, making this step
 * genuinely untestable there): on real BCM2835 silicon, the USB HCD's
 * own power domain is NOT guaranteed on by the time a kernel.img
 * gets control -- bare-metal USB drivers that skip this step report
 * exactly this project's own real symptom (every HPRT0 field reading
 * as if nothing is attached, regardless of what's physically plugged
 * in, even though a fixed ID register like GSNPSID can still read
 * back a real, correct value -- that register is plausibly a
 * synthesis-time constant independent of the HCD's own power-gated
 * operational logic, not proof the whole block is powered). Same
 * exact mailbox property-tag protocol boot/governor_state.S's own
 * `governor_apply_freq_mhz` already uses and already documents in
 * full (register offsets, channel 8, the DMB barrier before handing
 * the buffer to a separate hardware bus master, the bounded-poll-
 * never-`while true` discipline) -- not re-explained here, just a
 * different tag (SET_POWER_STATE, 0x00028001) and a different, 2-word
 * value buffer (device_id, state) instead of SET_CLOCK_RATE's 3-word
 * one.
 *
 * Device id 3 = USB HCD (confirmed against the official Raspberry Pi
 * firmware mailbox property interface documentation's own device-id
 * table: 0=SD, 1=UART0, 2=UART1, 3=USB HCD, 4-6=I2C0-2, 7=SPI,
 * 8=CCP2TX). State value 3 = bit0 (ON) | bit1 (WAIT -- block the
 * response until the power rail has actually stabilized, not just
 * "request accepted"), matching how every real bare-metal Pi USB
 * reference that does this step sets both bits together. */

.section ".bss"
.align 4
usb_power_mbox_buf:
    .space 32    /* 8 words -- see the layout comment in usb_power_on */

.section ".text"

/* i64 usb_power_on() -- returns 0 on VideoCore-reported success, 1 on
 * timeout or a reported failure. Must be called before dwc2_init
 * touches any DWC2 register -- same "power the real thing before
 * trusting what it reports" ordering boot/dwc2 bring-up already
 * applies for GRSTCTL/GUSBCFG/HPRT0 in kernel_main.vani. */
.global usb_power_on
usb_power_on:
    stmdb sp!, {r4-r9, lr}

    ldr r4, =usb_power_mbox_buf
    mov r7, #32
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00028001
    str r7, [r4, #8]                 /* buf[2]: tag = set power state */
    mov r7, #8
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    mov r7, #3
    str r7, [r4, #20]                /* buf[5]: device id (3 = USB HCD) */
    mov r7, #3
    str r7, [r4, #24]                /* buf[6]: state (bit0=on, bit1=wait) */
    mov r7, #0
    str r7, [r4, #28]                /* buf[7]: end tag */

    /* Same DMB governor_apply_freq_mhz's own header comment already
     * documents in full -- the VideoCore reads this buffer via its
     * own bus-master path, independent of this core's own cache/MMU
     * state (both off for this whole image regardless). */
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5

    mov r8, r4
    bic r8, r8, #0xF
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r9, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
upo_wait_write:
    ldr r1, [r9]
    tst r1, #0x80000000              /* FULL */
    beq upo_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt upo_wait_write
    mov r0, #1
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

upo_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
upo_wait_read:
    ldr r1, [r9]
    tst r1, #0x40000000              /* EMPTY */
    bne upo_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8
    beq upo_got_response
upo_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt upo_wait_read
    mov r0, #1
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

upo_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    bne upo_failed

    /* Per the official Raspberry Pi firmware mailbox property
     * interface docs (confirmed via WebSearch, task #197, 2026-10-02):
     * the response overwrites buf[6] with the tag's OWN state --
     * bit0=1 means actually on (not just "request accepted"), bit1=1
     * means "device does not exist." An overall-success response with
     * state reporting device-does-not-exist or still-off is a real,
     * distinct failure this function's own caller needs to be able to
     * tell apart from "request never even landed" -- checking only
     * buf[1] (the whole-transaction status) would silently treat that
     * as success. */
    ldr r2, [r4, #24]                /* buf[6]: response state */
    tst r2, #1                       /* bit0: powered on? */
    beq upo_failed
    tst r2, #2                       /* bit1: device does not exist? */
    bne upo_failed

    mov r0, #0
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

upo_failed:
    mov r0, #1
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr
