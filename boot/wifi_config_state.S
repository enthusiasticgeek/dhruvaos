/* WiFi credentials, configurable via /config/wifi_ssid and /config/
 * wifi_password (task #197 follow-up, 2026-10-01) -- same `.bss` +
 * accessor pattern every other config-derived state in this project
 * already uses (log_state.S, dhdl_state.S, governor_state.S, ...),
 * read once at boot by wifi_config_init() (kernel_main.vani) via the
 * same dharafs_read()-then-parse shape log_level_init() already
 * established. Two separate buffers/files, not one two-line file --
 * matches how real test credentials are kept on the HOST side too
 * (~/home-wifi-ssid.txt / ~/home-wifi-pwd.txt, never committed), and
 * avoids any newline-escaping awkwardness typing a combined value
 * over the shell's own single-line `write <path> <text>` command.
 *
 * 32 bytes for SSID (the real 802.11 SSID field's own max length,
 * matching wpa2_join_start's `ssid: ref [u8; 32]` parameter exactly
 * -- no reason to allocate more than the protocol itself allows).
 * 64 bytes for the password -- WPA2-PSK passphrases are 8-63 ASCII
 * characters by spec; 64 gives exactly that much room with no slack
 * wasted on an arbitrary round number. Neither buffer is ever
 * printed by any query path (dhdl query wifi reports the SSID only,
 * kernel_main.vani's own wifi_describe) -- the password buffer has
 * no corresponding "describe" exposure anywhere, by design. */

.section ".bss"
.align 4
wifi_config_ssid_buf:
    .space 32
wifi_config_ssid_len:
    .word 0
wifi_config_password_buf:
    .space 64
wifi_config_password_len:
    .word 0

.section ".text"

.global wifi_config_ssid_buf_ptr
wifi_config_ssid_buf_ptr:
    ldr r0, =wifi_config_ssid_buf
    bx lr

.global wifi_config_ssid_len_get
wifi_config_ssid_len_get:
    ldr r0, =wifi_config_ssid_len
    ldr r0, [r0]
    bx lr

.global wifi_config_ssid_len_set
wifi_config_ssid_len_set:
    ldr r1, =wifi_config_ssid_len
    str r0, [r1]
    bx lr

.global wifi_config_password_buf_ptr
wifi_config_password_buf_ptr:
    ldr r0, =wifi_config_password_buf
    bx lr

.global wifi_config_password_len_get
wifi_config_password_len_get:
    ldr r0, =wifi_config_password_len
    ldr r0, [r0]
    bx lr

.global wifi_config_password_len_set
wifi_config_password_len_set:
    ldr r1, =wifi_config_password_len
    str r0, [r1]
    bx lr
