/* Round 2026-11-18: persistent state for the RTL8188CU EFUSE-derived
 * per-channel-group TX power values (kernel_main.vani's own
 * rtl8188cu_efuse_read_and_parse/rtl8188cu_apply_tx_power).
 *
 * Found via a real-HW usbmon ground-truth capture of a working Linux
 * client talking to this exact chip family: this driver never once
 * read the chip's EFUSE (confirmed by grep -- zero accesses to
 * REG_EFUSE_CTRL/0x0030 anywhere), while the real driver reads it in
 * full before ever setting a channel. The real driver's own final
 * register writes (REG_TX_AGC_A_RATE18_06 etc, 0x0e00-0x0e1c) were
 * reverse-derived from the capture and confirmed to be a *direct*
 * broadcast of the EFUSE-derived per-group index (no additive base
 * table -- that table exists in the rtl8xxxu driver's own source but
 * is gated behind CONFIG_RTL8XXXU_UNTESTED and, per `lsusb -t` on the
 * real capture machine, this exact dongle is actually bound to the
 * separate `rtl8192cu` staging driver, not rtl8xxxu, so the simpler
 * directly-verified formula is what's ported here, not the untested
 * one). Boot-time one-shot parse (same "called exactly once per boot"
 * precedent as rtl8188cu_iq_calibrate's own scratch) -- 3 small
 * per-group byte arrays, not the full 512-byte unpacked EFUSE map
 * (which only needs a one-shot heap scratch during the parse itself,
 * per that same precedent). */

.section ".bss"
.align 4
/* 1 = EFUSE rtl_id magic (0x8129) matched and these arrays are valid;
 * 0 = parse failed or never ran -- callers must leave the existing
 * stock PHY_REG defaults untouched rather than apply garbage. */
wifi_efuse_parsed_ok:
    .word 0

/* Per-channel-group (0=ch1-3, 1=ch4-9, 2=ch10+) values, path A only
 * (this chip is 1T1R -- path B is never transmitted on). */
wifi_efuse_cck_a:
    .space 3
wifi_efuse_ofdmbase_a:
    .space 3
wifi_efuse_mcsbase_a:
    .space 3

/* Round 2026-11-21: the dongle's own real, factory-burned MAC address
 * (EFUSE logical offset 0x16, 6 bytes) -- this parse already proved it
 * reconstructs this field correctly during development (it matched a
 * real captured chip's own known MAC), but nothing ever stored or used
 * it: wifi_real_own_mac() has always returned a synthetic, invented
 * address instead (two prior round's own "is this AP's anti-spoofing
 * heuristic rejecting a synthetic-looking MAC" experiments, neither of
 * which used the dongle's own TRUE individual address -- see that
 * function's own header comment). Same "ground truth" principle as
 * everywhere else this investigation already applies: the one real
 * Linux client that's ever actually associated with this AP used
 * exactly this address, not an invented one. */
wifi_efuse_mac:
    .space 6

.section ".text"
.global wifi_efuse_get_parsed_ok
wifi_efuse_get_parsed_ok:
    ldr r0, =wifi_efuse_parsed_ok
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global wifi_efuse_set_parsed_ok
wifi_efuse_set_parsed_ok:
    ldr r1, =wifi_efuse_parsed_ok
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global wifi_efuse_cck_a_get
wifi_efuse_cck_a_get:
    ldr r0, =wifi_efuse_cck_a
    mov r1, #0
    bx lr

.global wifi_efuse_ofdmbase_a_get
wifi_efuse_ofdmbase_a_get:
    ldr r0, =wifi_efuse_ofdmbase_a
    mov r1, #0
    bx lr

.global wifi_efuse_mcsbase_a_get
wifi_efuse_mcsbase_a_get:
    ldr r0, =wifi_efuse_mcsbase_a
    mov r1, #0
    bx lr

.global wifi_efuse_mac_get
wifi_efuse_mac_get:
    ldr r0, =wifi_efuse_mac
    mov r1, #0
    bx lr
