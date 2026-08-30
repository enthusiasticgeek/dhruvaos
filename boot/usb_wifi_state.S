/* Dhruva Round 58 -- minimal persistent state for USB WiFi (Realtek
 * RTL8188CU/RTL8192CU family) enumeration + vendor register I/O.
 *
 * Deliberately smaller than usb_msd_state.S/usb_net_state.S/usb_bt_
 * state.S: this round's own scope stops at detection + register read/
 * write (see rtl8188cu_probe's own comment in kernel_main.vani for
 * exactly why and where it stops) -- there is no data-path endpoint
 * state to track yet, since no TX/RX/firmware-loading exists. Just a
 * single flag: 0 = none, 1 = RTL8188CU/RTL8192CU family detected
 * (idVendor:idProduct 0x0bda:0x8176, confirmed against Linux's
 * rtl8xxxu driver's own device table). */

.section ".bss"
.align 4
usb_wifi_kind:
    .word 0

.section ".text"

.global usb_wifi_get_kind
usb_wifi_get_kind:
    ldr r0, =usb_wifi_kind
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_kind
usb_wifi_set_kind:
    ldr r1, =usb_wifi_kind
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
