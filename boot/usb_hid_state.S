/* Dhruva Round 71 -- tiny persistent state for USB HID (keyboard/
 * mouse), same shape as usb_msd_state.S (round 33)/usb_net_state.S
 * (round 56)/usb_bt_state.S (round 57). A SEPARATE state module, not
 * shared with any of those, for the same reason they're separate from
 * each other: a mass-storage, network, Bluetooth, or HID device
 * attached at different times must never leave stale state behind for
 * whichever driver comes next.
 *
 * USB HID boot-protocol devices (interface class 0x03, subclass 0x01
 * "boot interface subclass", protocol 0x01 keyboard / 0x02 mouse --
 * HID1.11 spec Appendix B) need exactly ONE endpoint for this driver's
 * scope: an INTERRUPT IN endpoint the host polls for input reports.
 * A keyboard MAY also expose an interrupt OUT endpoint for LED state
 * (Num/Caps/Scroll Lock) -- not implemented here, this driver is
 * read-only (report input, not LED output), matching this project's
 * own "build what's needed, not speculative extras" discipline.
 *
 * usb_hid_kind: 0 = none, 1 = keyboard (protocol 0x01), 2 = mouse
 * (protocol 0x02) -- the two USB HID boot-protocol device types,
 * matching usb_net_kind's own "small integer enum in a .bss word"
 * convention rather than two separate boolean flags. */

.section ".bss"
.align 4
usb_hid_kind:
    .word 0
usb_hid_intr_in_epaddr:
    .word 0
usb_hid_intr_in_mps:
    .word 0
usb_hid_intr_in_toggle:
    .word 0

.section ".text"

.global usb_hid_get_kind
usb_hid_get_kind:
    ldr r0, =usb_hid_kind
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hid_set_kind
usb_hid_set_kind:
    ldr r1, =usb_hid_kind
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hid_get_intr_in_epaddr
usb_hid_get_intr_in_epaddr:
    ldr r0, =usb_hid_intr_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hid_set_intr_in_epaddr
usb_hid_set_intr_in_epaddr:
    ldr r1, =usb_hid_intr_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hid_get_intr_in_mps
usb_hid_get_intr_in_mps:
    ldr r0, =usb_hid_intr_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hid_set_intr_in_mps
usb_hid_set_intr_in_mps:
    ldr r1, =usb_hid_intr_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hid_get_intr_in_toggle
usb_hid_get_intr_in_toggle:
    ldr r0, =usb_hid_intr_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hid_set_intr_in_toggle
usb_hid_set_intr_in_toggle:
    ldr r1, =usb_hid_intr_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
