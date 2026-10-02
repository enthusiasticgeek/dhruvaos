/* Vendor-agnostic WiFi radio interface (task #197 follow-up,
 * 2026-10-01). Standing project policy: "every feature a generic
 * layer unless per-board/per-chip HW needed" -- the WPA2 join
 * orchestrator (kernel_main.vani's wifi_real_join/wifi_scan_for_ssid)
 * has no business knowing it's talking to an RTL8188CU specifically.
 * This file holds exactly ONE "active radio" descriptor -- a devaddr/
 * mps pair plus 3 registered function pointers (tx_frame/rx_frame/
 * set_channel) -- and three pure tail-call trampolines that dispatch
 * through them. A future second chip driver (RTL8192, RTL8812, ...)
 * needs only its own adapter functions matching these same 3
 * signatures, registered via the setters below; the orchestrator
 * itself never changes.
 *
 * Same proven shape as boot/dhdl_state.S's own registration mechanism
 * (a stored fn pointer, called via `bx`), simplified for exactly ONE
 * active radio rather than a searchable table -- there is only ever
 * one WiFi chip attached to this board at a time, so a linear-scan
 * table (DHDL's own reason for existing) buys nothing here that a
 * fixed set of named slots doesn't already give more simply.
 *
 * Deliberately split into separate single-argument setters (`wifi_
 * radio_set_devaddr`, `_set_mps_in`, `_set_mps_out`, `_set_tx_fn`,
 * `_set_rx_fn`, `_set_channel_fn`) rather than one combined multi-
 * argument `wifi_radio_register(...)` call -- a 6-argument assembly
 * function needs 2 arguments marshalled through the AAPCS stack (only
 * 4 fit in r0-r3), real complexity worth avoiding when nothing forces
 * it; DHDL's own `dhdl_register(id, describe)` made exactly the same
 * choice for exactly this reason.
 *
 * The three TRAMPOLINES below (`wifi_radio_tx_frame`/`_rx_frame`/
 * `_set_channel`) are PURE forwarding: load the registered fn pointer
 * into r12 (the one register AAPCS guarantees is scratch across any
 * call -- never callee-saved, exactly the register real PLT/linker
 * trampolines use for this same "load target, jump" pattern) and
 * `bx` straight into it, touching NOTHING else. This is what makes a
 * 6-argument tail call through a stored pointer safe without hand-
 * deriving the i64-pairing/stack-argument ABI here at all: as long as
 * the vani-side extern declaration for each trampoline declares the
 * EXACT SAME parameter types, in the EXACT SAME order, as whatever
 * real driver function gets registered, the compiler marshals both
 * call sites identically and this file never needs to know or care
 * what that marshalling actually looks like. */

.section ".bss"
.align 4
wifi_radio_devaddr:
    .word 0
wifi_radio_mps_in:
    .word 0
wifi_radio_mps_out:
    .word 0
wifi_radio_present:
    .word 0
wifi_radio_tx_fn_ptr:
    .word 0
wifi_radio_rx_fn_ptr:
    .word 0
wifi_radio_channel_fn_ptr:
    .word 0

.section ".text"

.global wifi_radio_set_devaddr
wifi_radio_set_devaddr:
    ldr r1, =wifi_radio_devaddr
    str r0, [r1]
    bx lr

.global wifi_radio_set_mps_in
wifi_radio_set_mps_in:
    ldr r1, =wifi_radio_mps_in
    str r0, [r1]
    bx lr

.global wifi_radio_set_mps_out
wifi_radio_set_mps_out:
    ldr r1, =wifi_radio_mps_out
    str r0, [r1]
    bx lr

.global wifi_radio_set_present
wifi_radio_set_present:
    ldr r1, =wifi_radio_present
    str r0, [r1]
    bx lr

.global wifi_radio_set_tx_fn
wifi_radio_set_tx_fn:
    ldr r1, =wifi_radio_tx_fn_ptr
    str r0, [r1]
    bx lr

.global wifi_radio_set_rx_fn
wifi_radio_set_rx_fn:
    ldr r1, =wifi_radio_rx_fn_ptr
    str r0, [r1]
    bx lr

.global wifi_radio_set_channel_fn
wifi_radio_set_channel_fn:
    ldr r1, =wifi_radio_channel_fn_ptr
    str r0, [r1]
    bx lr

.global wifi_radio_get_devaddr
wifi_radio_get_devaddr:
    ldr r0, =wifi_radio_devaddr
    ldr r0, [r0]
    bx lr

.global wifi_radio_get_mps_in
wifi_radio_get_mps_in:
    ldr r0, =wifi_radio_mps_in
    ldr r0, [r0]
    bx lr

.global wifi_radio_get_mps_out
wifi_radio_get_mps_out:
    ldr r0, =wifi_radio_mps_out
    ldr r0, [r0]
    bx lr

.global wifi_radio_get_present
wifi_radio_get_present:
    ldr r0, =wifi_radio_present
    ldr r0, [r0]
    bx lr

/* i64 wifi_radio_tx_frame(devaddr: u32, mps: u32, frame_buf: mut ref i64,
 * frame_len: i64, is_broadcast: i64, seq_num: i64) -> i64 -- matches
 * rtl8188cu_tx_frame's own real signature exactly; any future second
 * driver's own tx function must match it too to be registerable here. */
.global wifi_radio_tx_frame
wifi_radio_tx_frame:
    ldr r12, =wifi_radio_tx_fn_ptr
    ldr r12, [r12]
    bx r12

/* i64 wifi_radio_rx_frame(devaddr: u32, mps: u32, frame_out: mut ref i64) -> i64
 * -- deliberately a plain i64 (-1 = no frame, >=0 = real frame_len),
 * not a struct return: matches this project's own established "avoid
 * i64 where a plain small integer suffices, avoid struct-return ABI
 * uncertainty through hand-written assembly" conventions. The real
 * RTL8188CU driver's own rtl8188cu_rx_frame returns a struct
 * (RtlRxFrameResult) -- rtl8188cu_rx_frame_adapter (kernel_main.vani)
 * is the vendor-specific translation that makes it fit this generic
 * shape; a future second driver needs its own equivalent adapter. */
.global wifi_radio_rx_frame
wifi_radio_rx_frame:
    ldr r12, =wifi_radio_rx_fn_ptr
    ldr r12, [r12]
    bx r12

/* i64 wifi_radio_set_channel(devaddr: u32, mps: u32, channel: u32) -> i64 */
.global wifi_radio_set_channel
wifi_radio_set_channel:
    ldr r12, =wifi_radio_channel_fn_ptr
    ldr r12, [r12]
    bx r12
