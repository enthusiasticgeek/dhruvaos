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

/* TASK #164 FOLLOW-UP (2026-09-14): persistent scratch for the real
 * MCU firmware-download sequence (kernel_main.vani's own
 * rtl8188cu_download_firmware/rtl8188cu_start_firmware) -- allocated
 * ONCE here, not via dhruva_alloc_bytes inside the chunk-write loop,
 * matching this project's own established "persistent scratch, never
 * per-call alloc" convention (the same discipline sha256_hash's own
 * round-48 fix and auth_state.S's own HMAC/PBKDF2 scratch already
 * follow) -- a per-call heap allocation inside a ~128-iteration loop
 * (32 chunks/page * up to 4 pages) would leak that many times every
 * single firmware download, on a system with no free().
 *
 * usb_wifi_fw_buf: holds the full firmware file loaded from a
 * dedicated raw SD block range (see rtl8188cu_load_firmware_from_sd's
 * own comment in kernel_main.vani for the block range and why DharaFS
 * itself isn't used -- its own file-size cap, 4096 bytes, is smaller
 * than this ~16KB firmware). Sized for 32 blocks * 512 bytes = 16384
 * bytes, comfortably larger than the 16126-byte file round 58's own
 * investigation verified.
 * usb_wifi_fw_chunk: one writeN_block_size (128-byte, this chip
 * family's own confirmed value) chunk, reused for every USB
 * control-OUT transfer during download. */
.align 4
usb_wifi_fw_buf:
    .space 16384
usb_wifi_fw_chunk:
    .space 128
/* TASK #164 FOLLOW-UP: `wifikey chunk`/`commit` shell command's own
 * running upload-length counter (kernel_main.vani) -- reuses usb_wifi_
 * fw_buf itself as the accumulation target (safe: upload and the real
 * probe-time download never happen concurrently, one operator-driven
 * one-time setup step vs. one boot-time hardware sequence). */
usb_wifi_fw_upload_len:
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

.global usb_wifi_fw_buf_get
usb_wifi_fw_buf_get:
    ldr r0, =usb_wifi_fw_buf
    mov r1, #0
    bx lr

.global usb_wifi_fw_chunk_get
usb_wifi_fw_chunk_get:
    ldr r0, =usb_wifi_fw_chunk
    mov r1, #0
    bx lr

.global usb_wifi_fw_upload_len_get
usb_wifi_fw_upload_len_get:
    ldr r0, =usb_wifi_fw_upload_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_fw_upload_len_set
usb_wifi_fw_upload_len_set:
    ldr r1, =usb_wifi_fw_upload_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

/* TASK #164 FOLLOW-UP (real USB TX/RX for 802.11 frames): bulk
 * endpoint address/max-packet-size and data-toggle state, same shape
 * as usb_net_state.S's own fields -- dwc2_fetch_and_set_configuration
 * (which discovers these while walking the config descriptor) and
 * dwc2_wifi_bulk_out/in (which actually use them) are separate calls
 * with nothing else to carry this across. A separate module from
 * usb_net_state.S, not a shared one, for the same isolation reason
 * usb_net_state.S's own header comment already gives for why IT is
 * separate from usb_msd_state.S: a non-WiFi device enumerating after
 * a WiFi one (or vice versa) must not inherit stale endpoint state. */
.align 4
usb_wifi_bulk_in_epaddr:
    .word 0
usb_wifi_bulk_in_mps:
    .word 0
usb_wifi_bulk_out_epaddr:
    .word 0
usb_wifi_bulk_out_mps:
    .word 0
usb_wifi_in_toggle:
    .word 0
usb_wifi_out_toggle:
    .word 0

.global usb_wifi_get_bulk_in_epaddr
usb_wifi_get_bulk_in_epaddr:
    ldr r0, =usb_wifi_bulk_in_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_bulk_in_epaddr
usb_wifi_set_bulk_in_epaddr:
    ldr r1, =usb_wifi_bulk_in_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_wifi_get_bulk_in_mps
usb_wifi_get_bulk_in_mps:
    ldr r0, =usb_wifi_bulk_in_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_bulk_in_mps
usb_wifi_set_bulk_in_mps:
    ldr r1, =usb_wifi_bulk_in_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_wifi_get_bulk_out_epaddr
usb_wifi_get_bulk_out_epaddr:
    ldr r0, =usb_wifi_bulk_out_epaddr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_bulk_out_epaddr
usb_wifi_set_bulk_out_epaddr:
    ldr r1, =usb_wifi_bulk_out_epaddr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_wifi_get_bulk_out_mps
usb_wifi_get_bulk_out_mps:
    ldr r0, =usb_wifi_bulk_out_mps
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_bulk_out_mps
usb_wifi_set_bulk_out_mps:
    ldr r1, =usb_wifi_bulk_out_mps
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_wifi_get_in_toggle
usb_wifi_get_in_toggle:
    ldr r0, =usb_wifi_in_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_in_toggle
usb_wifi_set_in_toggle:
    ldr r1, =usb_wifi_in_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global usb_wifi_get_out_toggle
usb_wifi_get_out_toggle:
    ldr r0, =usb_wifi_out_toggle
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_wifi_set_out_toggle
usb_wifi_set_out_toggle:
    ldr r1, =usb_wifi_out_toggle
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
