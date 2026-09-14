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
