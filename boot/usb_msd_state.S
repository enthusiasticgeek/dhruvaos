/* Dhruva Round 33 -- tiny persistent state for the USB mass-storage
 * (Bulk-Only Transport) bring-up, same shape as every other
 * .bss-plus-accessor file in this project (governor_state.S/
 * netif_state.S/arp_state.S/tcp_state.S/dhcp_state.S). Needed because
 * dwc2_fetch_and_set_configuration (which discovers the bulk
 * endpoints while walking the config descriptor) and the bulk-
 * transfer/BOT functions that actually use them (dwc2_bulk_out/
 * dwc2_bulk_in/usb_msd_test_unit_ready) are separate calls with
 * nothing else to carry this across -- no vani top-level global
 * exists for it, and this state needs to survive across many
 * separate calls, not just one.
 *
 * bulk_in/bulk_out store the endpoint's raw bEndpointAddress byte
 * (bit7 = direction, bits[3:0] = endpoint number) exactly as the
 * descriptor reports it -- not decoded further here, since dwc2_
 * build_hcchar's own epdir/epnum parameters want the same two pieces
 * separately anyway, and the caller already knows which of the two
 * fields it's asking for by name (bulk_in vs bulk_out).
 *
 * Data-toggle bits (in_toggle/out_toggle): USB bulk endpoints track
 * DATA0/DATA1 PER ENDPOINT, independently of control transfers (which
 * always start each new stage at a fixed toggle value) -- every real
 * bulk endpoint's toggle resets to DATA0 (0) right after SET_
 * CONFIGURATION, per spec, matching the .bss zero-init default here
 * needing no separate reset call. */

.section ".bss"
.align 4
usb_msd_bot_flag:
    .word 0        /* 1 once dwc2_fetch_and_set_configuration finds a
                     * mass-storage/SCSI/BOT interface (class 0x08,
                     * subclass 0x06, protocol 0x50) on the currently-
                     * enumerated device; 0 otherwise (e.g. usb-net) --
                     * gates every bulk/BOT call site from ever firing
                     * against a device that isn't actually BOT. */
usb_msd_bulk_in_epaddr:
    .word 0
usb_msd_bulk_in_mps:
    .word 0
usb_msd_bulk_out_epaddr:
    .word 0
usb_msd_bulk_out_mps:
    .word 0
usb_msd_in_toggle:
    .word 0
usb_msd_out_toggle:
    .word 0

.section ".text"

.global usb_msd_get_bot
usb_msd_get_bot:
    ldr r0, =usb_msd_bot_flag
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_bot
usb_msd_set_bot:
    ldr r1, =usb_msd_bot_flag
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_bulk_in_epaddr
usb_msd_get_bulk_in_epaddr:
    ldr r0, =usb_msd_bulk_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_bulk_in_epaddr
usb_msd_set_bulk_in_epaddr:
    ldr r1, =usb_msd_bulk_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_bulk_in_mps
usb_msd_get_bulk_in_mps:
    ldr r0, =usb_msd_bulk_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_bulk_in_mps
usb_msd_set_bulk_in_mps:
    ldr r1, =usb_msd_bulk_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_bulk_out_epaddr
usb_msd_get_bulk_out_epaddr:
    ldr r0, =usb_msd_bulk_out_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_bulk_out_epaddr
usb_msd_set_bulk_out_epaddr:
    ldr r1, =usb_msd_bulk_out_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_bulk_out_mps
usb_msd_get_bulk_out_mps:
    ldr r0, =usb_msd_bulk_out_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_bulk_out_mps
usb_msd_set_bulk_out_mps:
    ldr r1, =usb_msd_bulk_out_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_in_toggle
usb_msd_get_in_toggle:
    ldr r0, =usb_msd_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_in_toggle
usb_msd_set_in_toggle:
    ldr r1, =usb_msd_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_msd_get_out_toggle
usb_msd_get_out_toggle:
    ldr r0, =usb_msd_out_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_msd_set_out_toggle
usb_msd_set_out_toggle:
    ldr r1, =usb_msd_out_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
