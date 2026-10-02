/* Vendor-agnostic BLE/HCI transport interface (task #311 follow-up,
 * "do same ble too", 2026-10-01). Same standing project policy as
 * boot/wifi_radio_state.S's own header comment: "every feature a
 * generic layer unless per-board/per-chip HW needed" -- the real
 * scan/connect orchestrator (kernel_main.vani's ble_real_connect/
 * ble_scan_for_target) has no business knowing which USB Bluetooth
 * controller chip it's talking to.
 *
 * Unlike WiFi's RTL8188CU (vendor-specific USB class 0xFF, needing an
 * entirely proprietary frame format), USB Bluetooth HCI is ALREADY a
 * standardized transport (Bluetooth Core Spec's own "USB Transport
 * Layer" section) -- this project's existing USB enumeration already
 * detects any compliant dongle generically by class code, not by
 * vendor/product ID (see kernel_main.vani's `cur_iface_is_bt`
 * detection, same shape as BOT/CDC-ECM). So why does this abstraction
 * layer still need to exist?  Because "speaks standard HCI framing"
 * and "needs nothing extra to start answering HCI commands" are NOT
 * the same guarantee: real-world Broadcom/Cypress and Intel USB
 * Bluetooth chips require a vendor-specific firmware/patch download
 * over this same USB transport BEFORE they will respond to HCI_Reset
 * at all (confirmed against Linux's btusb.c, whose btbcm_patchram_
 * download()/btintel_download_firmware() hooks exist for exactly
 * this reason, run transparently before the generic HCI command path
 * continues) -- so a second real chip plugged into this board in the
 * future may need its own startup adapter even though the wire
 * protocol afterward is identical. This file holds exactly ONE
 * "active BLE transport" descriptor -- a devaddr/mps triple plus 2
 * registered function pointers (send_cmd/poll_event) -- and two pure
 * tail-call trampolines that dispatch through them. A future second
 * chip driver needs only its own adapter functions matching these 2
 * signatures (its own adapter free to do a firmware download first,
 * then forward to the same dwc2_hci_send_command/dwc2_hci_
 * interrupt_in this file's own generic adapter already uses),
 * registered via the setters below; the orchestrator itself never
 * changes.
 *
 * Same proven shape as boot/wifi_radio_state.S (itself matching boot/
 * dhdl_state.S's own registration mechanism) -- see that file's own
 * header comment for the full "why r12, why separate single-argument
 * setters, why pure forwarding is safe regardless of argument
 * complexity" reasoning; not repeated here since it applies
 * identically. */

.section ".bss"
.align 4
ble_radio_devaddr:
    .word 0
ble_radio_mps_ctrl:
    .word 0
ble_radio_mps_intr_in:
    .word 0
ble_radio_present:
    .word 0
ble_radio_send_cmd_fn_ptr:
    .word 0
ble_radio_poll_event_fn_ptr:
    .word 0

.section ".text"

.global ble_radio_set_devaddr
ble_radio_set_devaddr:
    ldr r1, =ble_radio_devaddr
    str r0, [r1]
    bx lr

.global ble_radio_set_mps_ctrl
ble_radio_set_mps_ctrl:
    ldr r1, =ble_radio_mps_ctrl
    str r0, [r1]
    bx lr

.global ble_radio_set_mps_intr_in
ble_radio_set_mps_intr_in:
    ldr r1, =ble_radio_mps_intr_in
    str r0, [r1]
    bx lr

.global ble_radio_set_present
ble_radio_set_present:
    ldr r1, =ble_radio_present
    str r0, [r1]
    bx lr

.global ble_radio_set_send_cmd_fn
ble_radio_set_send_cmd_fn:
    ldr r1, =ble_radio_send_cmd_fn_ptr
    str r0, [r1]
    bx lr

.global ble_radio_set_poll_event_fn
ble_radio_set_poll_event_fn:
    ldr r1, =ble_radio_poll_event_fn_ptr
    str r0, [r1]
    bx lr

.global ble_radio_get_devaddr
ble_radio_get_devaddr:
    ldr r0, =ble_radio_devaddr
    ldr r0, [r0]
    bx lr

.global ble_radio_get_mps_ctrl
ble_radio_get_mps_ctrl:
    ldr r0, =ble_radio_mps_ctrl
    ldr r0, [r0]
    bx lr

.global ble_radio_get_mps_intr_in
ble_radio_get_mps_intr_in:
    ldr r0, =ble_radio_mps_intr_in
    ldr r0, [r0]
    bx lr

.global ble_radio_get_present
ble_radio_get_present:
    ldr r0, =ble_radio_present
    ldr r0, [r0]
    bx lr

/* i64 ble_radio_send_command(devaddr: u32, mps: u32, cmd_buf: mut ref i64,
 * cmd_len: u32) -> i64 -- matches dwc2_hci_send_command's own real
 * signature exactly; any future second driver's own send function
 * (firmware-download adapter included) must match it too. */
.global ble_radio_send_command
ble_radio_send_command:
    ldr r12, =ble_radio_send_cmd_fn_ptr
    ldr r12, [r12]
    bx r12

/* i64 ble_radio_poll_event(devaddr: u32, mps: u32, out_buf: mut ref i64,
 * want_len: i64) -> i64 -- matches dwc2_hci_interrupt_in's own real
 * signature exactly. */
.global ble_radio_poll_event
ble_radio_poll_event:
    ldr r12, =ble_radio_poll_event_fn_ptr
    ldr r12, [r12]
    bx r12
