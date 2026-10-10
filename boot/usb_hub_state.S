/* Round 59 (tasks #164/#197, 2026-10-10): persistent state for real USB
 * hotplug detection on the LAN9512's own 2-port downstream hub --
 * needed because the hub's own bMaxPacketSize0 (learned once, at boot,
 * by dwc2_probe_device0) has to be remembered for any LATER control
 * transfer to the hub itself (GET_PORT_STATUS), and because detecting
 * a NEW connection or disconnection requires knowing what each port's
 * connect state was on the PREVIOUS check.
 *
 * hub_ready: 0 = no hub was ever found+configured at boot (nothing to
 * poll -- e.g. no device at all attached to the Pi's single physical
 * port), 1 = a hub answered and configured successfully at boot, so
 * its 2 downstream ports are worth periodically re-checking.
 *
 * port1_connected/port2_connected: last-known connect state (0/1) for
 * each of the hub's 2 downstream ports, as of the most recent
 * usb_hotplug_poll() pass (or the boot-time dwc2_enumerate_downstream
 * call, which seeds these the same way). */

.section ".bss"
.align 4
usb_hub_ready:
    .word 0
usb_hub_mps:
    .word 0
usb_hub_port1_connected:
    .word 0
usb_hub_port2_connected:
    .word 0

.section ".text"

.global usb_hub_get_ready
usb_hub_get_ready:
    ldr r0, =usb_hub_ready
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_ready
usb_hub_set_ready:
    ldr r1, =usb_hub_ready
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hub_get_mps
usb_hub_get_mps:
    ldr r0, =usb_hub_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_mps
usb_hub_set_mps:
    ldr r1, =usb_hub_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hub_get_port1_connected
usb_hub_get_port1_connected:
    ldr r0, =usb_hub_port1_connected
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_port1_connected
usb_hub_set_port1_connected:
    ldr r1, =usb_hub_port1_connected
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hub_get_port2_connected
usb_hub_get_port2_connected:
    ldr r0, =usb_hub_port2_connected
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_port2_connected
usb_hub_set_port2_connected:
    ldr r1, =usb_hub_port2_connected
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
