/* Dhruva Round 57 -- tiny persistent state for the USB Bluetooth HCI
 * transport, same shape as usb_msd_state.S (round 33) and usb_net_
 * state.S (round 56). A SEPARATE state module, not shared with either,
 * for the same reason those two are separate from each other: a
 * mass-storage, network, or Bluetooth device attached at different
 * times must never leave stale state behind for whichever driver
 * comes next.
 *
 * Unlike usb_msd_state.S/usb_net_state.S (2 bulk endpoints each), USB
 * Bluetooth HCI needs THREE: bulk IN/OUT for ACL data, plus an
 * INTERRUPT IN endpoint for HCI events -- the standardized USB
 * Bluetooth HCI transport (interface class 0xE0, subclass 0x01,
 * protocol 0x01) always has all three, per the Bluetooth Core
 * Specification's own "USB Transport Layer" section. HCI COMMANDS
 * (host -> controller) go over the control endpoint instead (see
 * dwc2_hci_send_command's own comment in kernel_main.vani) and need no
 * endpoint state here at all.
 *
 * bt_kind: 0 = none, 1 = USB Bluetooth HCI detected (class 0xE0/0x01/
 * 0x01). No further variants today (unlike usb_net_kind's CDC-ECM vs
 * LAN9512 split) -- HCI-over-USB has exactly one standardized shape. */

.section ".bss"
.align 4
usb_bt_kind:
    .word 0
usb_bt_bulk_in_epaddr:
    .word 0
usb_bt_bulk_in_mps:
    .word 0
usb_bt_bulk_out_epaddr:
    .word 0
usb_bt_bulk_out_mps:
    .word 0
usb_bt_bulk_in_toggle:
    .word 0
usb_bt_bulk_out_toggle:
    .word 0
usb_bt_intr_in_epaddr:
    .word 0
usb_bt_intr_in_mps:
    .word 0
usb_bt_intr_in_toggle:
    .word 0

.section ".text"

.global usb_bt_get_kind
usb_bt_get_kind:
    ldr r0, =usb_bt_kind
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_kind
usb_bt_set_kind:
    ldr r1, =usb_bt_kind
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_in_epaddr
usb_bt_get_bulk_in_epaddr:
    ldr r0, =usb_bt_bulk_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_in_epaddr
usb_bt_set_bulk_in_epaddr:
    ldr r1, =usb_bt_bulk_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_in_mps
usb_bt_get_bulk_in_mps:
    ldr r0, =usb_bt_bulk_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_in_mps
usb_bt_set_bulk_in_mps:
    ldr r1, =usb_bt_bulk_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_out_epaddr
usb_bt_get_bulk_out_epaddr:
    ldr r0, =usb_bt_bulk_out_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_out_epaddr
usb_bt_set_bulk_out_epaddr:
    ldr r1, =usb_bt_bulk_out_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_out_mps
usb_bt_get_bulk_out_mps:
    ldr r0, =usb_bt_bulk_out_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_out_mps
usb_bt_set_bulk_out_mps:
    ldr r1, =usb_bt_bulk_out_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_in_toggle
usb_bt_get_bulk_in_toggle:
    ldr r0, =usb_bt_bulk_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_in_toggle
usb_bt_set_bulk_in_toggle:
    ldr r1, =usb_bt_bulk_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_bulk_out_toggle
usb_bt_get_bulk_out_toggle:
    ldr r0, =usb_bt_bulk_out_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_bulk_out_toggle
usb_bt_set_bulk_out_toggle:
    ldr r1, =usb_bt_bulk_out_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_intr_in_epaddr
usb_bt_get_intr_in_epaddr:
    ldr r0, =usb_bt_intr_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_intr_in_epaddr
usb_bt_set_intr_in_epaddr:
    ldr r1, =usb_bt_intr_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_intr_in_mps
usb_bt_get_intr_in_mps:
    ldr r0, =usb_bt_intr_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_intr_in_mps
usb_bt_set_intr_in_mps:
    ldr r1, =usb_bt_intr_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_bt_get_intr_in_toggle
usb_bt_get_intr_in_toggle:
    ldr r0, =usb_bt_intr_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bt_set_intr_in_toggle
usb_bt_set_intr_in_toggle:
    ldr r1, =usb_bt_intr_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
