/* BLE target device name, configurable via /config/ble_target_name
 * (task #311 follow-up, "do same ble too", 2026-10-01) -- same `.bss`
 * + accessor pattern as boot/wifi_config_state.S (and every other
 * config-derived state in this project: log_state.S, dhdl_state.S,
 * governor_state.S, ...), read once at boot by ble_config_init()
 * (kernel_main.vani) via the same dharafs_read()-then-parse shape
 * wifi_config_init()/log_level_init() already established.
 *
 * Only ONE field, unlike WiFi's SSID+password pair: a BLE central
 * connecting to a peripheral has no password-equivalent step in this
 * driver's scope (GATT here runs unencrypted, no SMP/pairing layer
 * exists anywhere in this codebase -- see gatt_server_* functions,
 * none of which check a bonded/encrypted state). Matched against the
 * advertised Local Name (AD type 0x08/0x09) in each LE Advertising
 * Report during scan, not a fixed address -- the practical analogue
 * of WiFi's human-readable SSID, since a real peripheral's own
 * Bluetooth address generally isn't known ahead of time the way an
 * AP's SSID is chosen by its owner.
 *
 * 32 bytes -- same cap as WiFi's own SSID buffer, and more than
 * enough for a Local Name AD structure's own max length (31 bytes of
 * total advertising data per packet, Bluetooth Core Spec Vol 3 Part
 * C, so a name can never exceed that anyway). */

.section ".bss"
.align 4
ble_config_target_name_buf:
    .space 32
ble_config_target_name_len:
    .word 0

.section ".text"

.global ble_config_target_name_buf_ptr
ble_config_target_name_buf_ptr:
    ldr r0, =ble_config_target_name_buf
    bx lr

.global ble_config_target_name_len_get
ble_config_target_name_len_get:
    ldr r0, =ble_config_target_name_len
    ldr r0, [r0]
    bx lr

.global ble_config_target_name_len_set
ble_config_target_name_len_set:
    ldr r1, =ble_config_target_name_len
    str r0, [r1]
    bx lr
