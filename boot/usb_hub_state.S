/* Round 59 (tasks #164/#197, 2026-10-10): persistent state for real USB
 * hotplug detection on the LAN9512's own 3-port downstream hub --
 * needed because the hub's own bMaxPacketSize0 (learned once, at boot,
 * by dwc2_probe_device0) has to be remembered for any LATER control
 * transfer to the hub itself (GET_PORT_STATUS), and because detecting
 * a NEW connection or disconnection requires knowing what each port's
 * connect state was on the PREVIOUS check.
 *
 * hub_ready: 0 = no hub was ever found+configured at boot (nothing to
 * poll -- e.g. no device at all attached to the Pi's single physical
 * port), 1 = a hub answered and configured successfully at boot, so
 * its downstream ports are worth periodically re-checking.
 *
 * port1_connected/port2_connected/port3_connected: last-known connect
 * state (0/1) for each of the hub's 3 downstream ports (round 61,
 * 2026-10-10: a live GET_DESCRIPTOR(Hub) class request confirmed
 * bNbrPorts=3, not 2 -- see dwc2_hub_port3's own comment in
 * kernel_main.vani for the full story), as of the most recent
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
usb_hub_port3_connected:
    .word 0
/* 2026-10-23 (real-HW kernelupload-stream stall investigation, user
 * request "fix it first", then "will 1st fail never enumerate wifi
 * or ble... for usb hotplug poll" -- a real regression the FIRST
 * version of this fix had): exponential backoff for a hub that
 * answers GET_PORT_STATUS unreliably or not at all -- live-confirmed
 * root cause of a 20+ SECOND task_e critical-section hold (ceiling=2,
 * shared with kernelupload's own SD writes): usb_hotplug_sample_
 * port_connected's own 3-try loop, each try potentially driving a
 * full dwc2_control_in (SETUP+DATA+STATUS, each stage's own
 * dwc2_wait_chan0_done up to its documented ~500ms worst case, times
 * its own internal XACTERR retry count), across all 3 downstream
 * ports, every single 10-second task_e wake, forever, with nothing
 * to stop it if the hub is simply never going to answer. Rather than
 * touching dwc2_wait_chan0_done itself (the shared primitive EVERY
 * USB transfer in this driver goes through -- bulk/interrupt/mass-
 * storage too, far too broad a blast radius for a hub-specific fix),
 * this counts CONSECUTIVE hub-communication failures (any port's own
 * sample returning -1) and skips an EXPONENTIALLY GROWING number of
 * future passes after each one (see usb_hotplug_poll's own header
 * comment, kernel_main.vani, for the exact schedule and cap) --
 * matching how Linux's own hub driver actually behaves (hub_events()
 * keeps re-polling a misbehaving port on its own workqueue schedule;
 * it never permanently gives up on one for the life of the boot). A
 * FIRST version of this fix tripped once and disabled hotplug
 * polling for the rest of the boot entirely -- live-flagged as a
 * real regression (a WiFi/BLE dongle plugged in later would never be
 * noticed) -- replaced with this backoff so detection genuinely
 * degrades (slower, not zero) instead of permanently dying. Both
 * fields reset to 0 on any genuinely successful sample (sr==0 from
 * dwc2_hub_get_port_status), so a hub that recovers (replugged,
 * power-cycled) is noticed on its very next poll, not after waiting
 * out a stale backoff. */
usb_hub_fail_streak:
    .word 0
usb_hub_backoff_remaining:
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

.global usb_hub_get_port3_connected
usb_hub_get_port3_connected:
    ldr r0, =usb_hub_port3_connected
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_port3_connected
usb_hub_set_port3_connected:
    ldr r1, =usb_hub_port3_connected
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hub_get_fail_streak
usb_hub_get_fail_streak:
    ldr r0, =usb_hub_fail_streak
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_fail_streak
usb_hub_set_fail_streak:
    ldr r1, =usb_hub_fail_streak
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_hub_get_backoff_remaining
usb_hub_get_backoff_remaining:
    ldr r0, =usb_hub_backoff_remaining
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_hub_set_backoff_remaining
usb_hub_set_backoff_remaining:
    ldr r1, =usb_hub_backoff_remaining
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
