/* Dhruva Round 56 -- tiny persistent state for the USB network driver
 * (CDC-ECM and the real SMSC LAN9512 backend), same shape as usb_msd_
 * state.S (round 33) and every other .bss-plus-accessor file in this
 * project. Needed for the same reason usb_msd_state.S exists:
 * dwc2_fetch_and_set_configuration (which discovers the device kind
 * and its bulk endpoints while walking the config descriptor) and the
 * functions that actually use them (dwc2_net_bulk_out/in, netif_send_
 * frame/netif_recv_frame) are separate calls with nothing else to
 * carry this across.
 *
 * A SEPARATE state module from usb_msd_state.S, not a shared/
 * generalized one, deliberately: dwc2_fetch_and_set_configuration
 * resets usb_msd_bot_flag to 0 on every call specifically so a non-
 * mass-storage device (a usb-net gadget, or the hub itself) doesn't
 * retain a stale BOT flag from a previous device -- the same isolation
 * needs to hold in the other direction (a mass-storage device must not
 * leave stale net_kind/endpoint state behind either), and two
 * independent state modules make that trivially true rather than
 * something a shared one would need to remember to reset correctly at
 * every call site.
 *
 * net_kind: 0 = none (loopback fallback, netif's original behavior),
 * 1 = CDC-ECM (QEMU's own `usb-net` device, and real standard USB
 * Ethernet dongles -- live-verified over QEMU), 2 = real SMSC LAN9512
 * (the actual chip every Pi 1 Model B's onboard wired port uses --
 * written to the public datasheet + Linux's smsc95xx.c reference
 * driver, NOT live-verified: no LAN9512 QEMU device model exists,
 * pending real Pi 1B hardware-in-loop testing per project TODO).
 *
 * mac_scratch_ptr holds the ADDRESS of a 6-byte buffer (allocated once
 * via dhruva_alloc_bytes by whichever enumeration path sets it), not
 * the MAC bytes themselves -- same "asm side holds a pointer set once
 * at boot, vani code owns the actual buffer" indirection this project
 * already uses for dharafs_sd_scratch_set/dharafs_path_scratch_set,
 * since vani has no top-level mutable global storage of its own. */

.section ".bss"
.align 4
usb_net_kind:
    .word 0
usb_net_bulk_in_epaddr:
    .word 0
usb_net_bulk_in_mps:
    .word 0
usb_net_bulk_out_epaddr:
    .word 0
usb_net_bulk_out_mps:
    .word 0
usb_net_in_toggle:
    .word 0
usb_net_out_toggle:
    .word 0
usb_net_cdc_data_iface_num:
    .word 0
usb_net_mac_scratch_ptr:
    .word 0

.section ".text"

.global usb_net_get_kind
usb_net_get_kind:
    ldr r0, =usb_net_kind
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_kind
usb_net_set_kind:
    ldr r1, =usb_net_kind
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_bulk_in_epaddr
usb_net_get_bulk_in_epaddr:
    ldr r0, =usb_net_bulk_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_bulk_in_epaddr
usb_net_set_bulk_in_epaddr:
    ldr r1, =usb_net_bulk_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_bulk_in_mps
usb_net_get_bulk_in_mps:
    ldr r0, =usb_net_bulk_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_bulk_in_mps
usb_net_set_bulk_in_mps:
    ldr r1, =usb_net_bulk_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_bulk_out_epaddr
usb_net_get_bulk_out_epaddr:
    ldr r0, =usb_net_bulk_out_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_bulk_out_epaddr
usb_net_set_bulk_out_epaddr:
    ldr r1, =usb_net_bulk_out_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_bulk_out_mps
usb_net_get_bulk_out_mps:
    ldr r0, =usb_net_bulk_out_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_bulk_out_mps
usb_net_set_bulk_out_mps:
    ldr r1, =usb_net_bulk_out_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_in_toggle
usb_net_get_in_toggle:
    ldr r0, =usb_net_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_in_toggle
usb_net_set_in_toggle:
    ldr r1, =usb_net_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_out_toggle
usb_net_get_out_toggle:
    ldr r0, =usb_net_out_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_out_toggle
usb_net_set_out_toggle:
    ldr r1, =usb_net_out_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_cdc_data_iface_num
usb_net_get_cdc_data_iface_num:
    ldr r0, =usb_net_cdc_data_iface_num
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_cdc_data_iface_num
usb_net_set_cdc_data_iface_num:
    ldr r1, =usb_net_cdc_data_iface_num
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_net_get_mac_scratch_ptr
usb_net_get_mac_scratch_ptr:
    ldr r0, =usb_net_mac_scratch_ptr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_net_set_mac_scratch_ptr
usb_net_set_mac_scratch_ptr:
    ldr r1, =usb_net_mac_scratch_ptr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
