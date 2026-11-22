/* Round 2026-11-21: runtime TX-pipeline instrumentation, requested
 * after two independent, fully-covered external monitor-mode captures
 * (0 of 6112, then 0 of 11705 packets from either Pi MAC) established
 * that the Authentication Request never reaches the antenna, even
 * after the calibration-order fix. Static source comparison against
 * Linux has been exhausted (TX descriptor, TX power, PA bias, antenna
 * switch, MAC address, sequence numbers, firmware identity, H2C
 * handshakes, calibration order, RF path switch, dm_init -- all
 * checked, all closed). This buffer captures the LAST frame handed to
 * dwc2_wifi_bulk_out (descriptor + frame bytes + raw USB completion
 * registers), overwritten on every TX -- no printing, no loops, no
 * new delays in the hot path, same discipline as every other
 * persistent-state file in this codebase. Printed only once, after
 * the join attempt already concluded (success or failure), by
 * wifi_real_join's own existing diagnostic path -- that dump happens
 * strictly after the last real TX, so "last frame" is always the
 * Authentication Request when a join fails in state=2 waiting for its
 * response (the one case this instrumentation was built for). */

.section ".bss"
.align 4
wifi_txtrace_valid:
    .word 0
wifi_txtrace_devaddr:
    .word 0
wifi_txtrace_epaddr:
    .word 0
wifi_txtrace_mps:
    .word 0
wifi_txtrace_out_len:
    .word 0
/* Raw bytes handed to dwc2_wifi_bulk_out: bytes 0-31 are the 32-byte
 * RTL TX descriptor (all 8 dwords), bytes 32-95 are the real 802.11
 * frame body that follows it (64 bytes -- covers the 30-byte Auth
 * Request/36-byte Probe Request/62-byte Assoc Request this driver
 * ever sends, with margin). */
wifi_txtrace_bytes:
    .space 96
wifi_txtrace_hctsiz_written:
    .word 0
wifi_txtrace_hcchar_written:
    .word 0
wifi_txtrace_hcint_result:
    .word 0
wifi_txtrace_hctsiz_after:
    .word 0
wifi_txtrace_hcchar_after:
    .word 0

.section ".text"
.global wifi_txtrace_bytes_get
wifi_txtrace_bytes_get:
    ldr r0, =wifi_txtrace_bytes
    mov r1, #0
    bx lr

/* Split into three <=4-arg calls rather than one wide call -- every
 * other persistent-state setter in this codebase takes at most 1-2
 * args; matching that convention sidesteps any risk of vani's own
 * extern "C" call codegen not handling 5th+ (stack-passed) integer
 * arguments the way hand-written AAPCS assembly would expect. */
.global wifi_txtrace_begin
wifi_txtrace_begin:                /* r0=devaddr r1=epaddr r2=mps r3=out_len */
    ldr r12, =wifi_txtrace_devaddr /* r12 (IP) is a true scratch register per AAPCS, never callee-saved -- avoids the push/pop r4 needs */
    str r0, [r12]
    ldr r12, =wifi_txtrace_epaddr
    str r1, [r12]
    ldr r12, =wifi_txtrace_mps
    str r2, [r12]
    ldr r12, =wifi_txtrace_out_len
    str r3, [r12]
    mov r0, #0
    mov r1, #0
    bx lr

.global wifi_txtrace_set_usb
wifi_txtrace_set_usb:               /* r0=hctsiz_written r1=hcchar_written r2=hcint_result */
    ldr r3, =wifi_txtrace_hctsiz_written
    str r0, [r3]
    ldr r3, =wifi_txtrace_hcchar_written
    str r1, [r3]
    ldr r3, =wifi_txtrace_hcint_result
    str r2, [r3]
    mov r0, #0
    mov r1, #0
    bx lr

.global wifi_txtrace_set_after
wifi_txtrace_set_after:             /* r0=hctsiz_after r1=hcchar_after */
    ldr r2, =wifi_txtrace_hctsiz_after
    str r0, [r2]
    ldr r2, =wifi_txtrace_hcchar_after
    str r1, [r2]
    ldr r2, =wifi_txtrace_valid
    mov r3, #1
    str r3, [r2]
    mov r0, #0
    mov r1, #0
    bx lr

.global wifi_txtrace_valid_get
wifi_txtrace_valid_get:
    ldr r0, =wifi_txtrace_valid
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_devaddr_get
wifi_txtrace_devaddr_get:
    ldr r0, =wifi_txtrace_devaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_epaddr_get
wifi_txtrace_epaddr_get:
    ldr r0, =wifi_txtrace_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_mps_get
wifi_txtrace_mps_get:
    ldr r0, =wifi_txtrace_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_out_len_get
wifi_txtrace_out_len_get:
    ldr r0, =wifi_txtrace_out_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_hctsiz_written_get
wifi_txtrace_hctsiz_written_get:
    ldr r0, =wifi_txtrace_hctsiz_written
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_hcchar_written_get
wifi_txtrace_hcchar_written_get:
    ldr r0, =wifi_txtrace_hcchar_written
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_hcint_result_get
wifi_txtrace_hcint_result_get:
    ldr r0, =wifi_txtrace_hcint_result
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_hctsiz_after_get
wifi_txtrace_hctsiz_after_get:
    ldr r0, =wifi_txtrace_hctsiz_after
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_txtrace_hcchar_after_get
wifi_txtrace_hcchar_after_get:
    ldr r0, =wifi_txtrace_hcchar_after
    ldr r0, [r0]
    mov r1, #0
    bx lr
