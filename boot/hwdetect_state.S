/* Runtime real-hardware-vs-QEMU detection (2026-11-21).
 *
 * Why this exists: every "real hardware only" behavior in this codebase
 * (the watchdog chief among them) used to be gated by a compile-time
 * constant that build_real_hw.sh had to sed-patch, build, then revert --
 * because vani has no preprocessor/conditional compilation, that source-
 * patch-then-revert dance was the only way to ship two different binaries.
 * This project's own history already shows the real cost of that: a fix
 * got verified with a plain ./build.sh and the STALE pre-fix real-HW image
 * got flashed and tested instead, because the second build step was never
 * re-run. One binary that correctly self-configures at boot removes the
 * whole class of mistake.
 *
 * Detection mechanism (verified against QEMU's own real source before
 * relying on it, not guessed -- same discipline governor_apply_freq_mhz's
 * own header comment already documents for SET_CLOCK_RATE): QEMU's
 * hw/misc/bcm2835_property.c (v10.0.0, the raspi1ap machine this project
 * targets) handles RPI_FWREQ_GET_FIRMWARE_REVISION (tag 0x00000001) with
 * an unconditional hardcoded literal:
 *     stl_le_phys(&s->dma_as, value + 12, 346337);
 * every single time, regardless of machine-model config -- unlike
 * GET_BOARD_REVISION (0x00010002), which QEMU just echoes back from a
 * configurable board-rev property and so could plausibly be set to look
 * like real hardware. Real Raspberry Pi firmware answers this exact same,
 * standard property tag with its own genuine build-revision integer
 * instead -- so "the response is exactly 346337" is a QEMU fingerprint a
 * real board could only match by astronomical coincidence.
 *
 * Fail-safe direction: hardware_is_real_hw defaults to 0 (treat as QEMU/
 * unknown -- the already-accepted status quo default, watchdog off) until
 * hwdetect_probe_real_hardware() positively confirms a non-346337 reply.
 * A mailbox timeout or any unexpected response shape also stays 0 -- never
 * flips to "real" on uncertainty. Getting this backwards would be actively
 * harmful, not just conservative: QEMU resets immediately on the very
 * first PM_RSTC write (see boot/stage0/stage0_main.c's own matching
 * comment), so a false "real hardware" verdict under QEMU would arm a
 * watchdog that then fires into a reset loop. */

.section ".bss"
.align 4
hardware_is_real_hw:
    .word 0        /* 0 = treat as QEMU/unknown (fail-safe default, same
                     * as today's watchdog-off status quo); 1 = positively
                     * confirmed real hardware by hwdetect_probe_real_
                     * hardware(). Set once, early in boot, by whichever
                     * binary (kernel or stage0) calls the probe; every
                     * other watchdog-related call site just reads this. */

.align 4
hwdetect_mbox_buf:
    .space 32    /* 7 words used (28 bytes), rounded up to match this
                   * file family's own "always a clean multiple" habit --
                   * see the layout comment in hwdetect_probe_real_hardware. */

.section ".text"

.global hardware_is_real_hw_get
hardware_is_real_hw_get:
    ldr r0, =hardware_is_real_hw
    ldr r0, [r0]
    bx lr

.global hardware_is_real_hw_set
hardware_is_real_hw_set:
    ldr r1, =hardware_is_real_hw
    str r0, [r1]
    mov r0, #0
    bx lr

/* u32 hwdetect_probe_real_hardware(void) -- one VideoCore mailbox
 * property-tag round trip (channel 8, same protocol as governor_
 * apply_freq_mhz/boot/governor_state.S and usb_power_on/boot/usb_power_
 * state.S, verified correct and QEMU-safe there already), querying
 * RPI_FWREQ_GET_FIRMWARE_REVISION (tag 0x00000001, a standard property
 * tag real Pi firmware also answers, not QEMU-only). Returns 1 only if
 * the call completed AND the returned value is not the hardcoded QEMU
 * literal 346337; returns 0 on a mailbox timeout, on this response not
 * being the one we asked for, or on an exact 346337 match. Bounded
 * polls (not `while true`), matching this project's own established
 * "any hardware wait must have a real exit" convention. */
.global hwdetect_probe_real_hardware
hwdetect_probe_real_hardware:
    stmdb sp!, {r4-r9, lr}

    ldr r4, =hwdetect_mbox_buf
    mov r7, #28
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00000001
    str r7, [r4, #8]                 /* buf[2]: tag = get firmware revision */
    mov r7, #4
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    str r7, [r4, #20]                /* buf[5]: response word (VC fills this in) */
    str r7, [r4, #24]                /* buf[6]: end tag */

    /* Same DMB-before-handoff fix as governor_apply_freq_mhz's own
     * matching comment -- a genuinely separate hardware bus master
     * reads this buffer via its own path, nothing else guarantees the
     * stores above have actually reached memory first. */
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5

    mov r8, r4
    bic r8, r8, #0xF                 /* defensive -- buf is already 16-byte aligned */
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r9, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
hdp_wait_write:
    ldr r1, [r9]
    tst r1, #0x80000000              /* FULL */
    beq hdp_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt hdp_wait_write
    mov r0, #0                       /* timed out -- fail-safe: not real */
    ldmia sp!, {r4-r9, lr}
    bx lr

hdp_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5       /* DMB */

    mov r0, #0
hdp_wait_read:
    ldr r1, [r9]
    tst r1, #0x40000000              /* EMPTY */
    bne hdp_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8                       /* is this response ours? */
    beq hdp_got_response
hdp_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt hdp_wait_read
    mov r0, #0                       /* timed out -- fail-safe: not real */
    ldmia sp!, {r4-r9, lr}
    bx lr

hdp_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    bne hdp_not_real                 /* overall call itself failed -- fail-safe: not real */

    ldr r2, [r4, #20]                /* buf[5]: the firmware-revision value */
    ldr r3, =346337
    cmp r2, r3
    moveq r0, #0                     /* exactly QEMU's hardcoded literal -- not real */
    movne r0, #1                     /* anything else -- positively confirmed real hardware */
    ldmia sp!, {r4-r9, lr}
    bx lr

hdp_not_real:
    mov r0, #0
    ldmia sp!, {r4-r9, lr}
    bx lr
