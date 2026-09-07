/* Dhruva round 93 -- static IP configuration, the DHCP-alternative
 * path from the user's own original networking vision ("it should
 * work dhcp/static ip as well as..."). Brand-new design, no
 * kernel_main.vani precedent (Pi 1's own DHCP was always the only way
 * this project ever acquired an address).
 *
 * A single scalar instance (ip/netmask/gateway/source), same shape as
 * round 91's dhcp_state.S -- this device has exactly one network
 * configuration at a time, not a table. `source` (0=NONE, 1=STATIC,
 * 2=DHCP) records which path populated it, so a caller can tell a
 * genuinely unconfigured device apart from one that just happens to
 * be sitting on 0.0.0.0 (never a real value here -- netconfig_set_
 * static_rpi4 rejects it, matching arp_cache's own "0 means unused"
 * convention elsewhere in this project).
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]]):
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
netconfig_ip:      .word 0
netconfig_netmask: .word 0
netconfig_gateway: .word 0
netconfig_source:  .word 0

.section ".text"

.macro NETCONFIG_ACCESSOR name, sym
.global netconfig_get_\name
netconfig_get_\name:
    adrp x0, \sym
    add x0, x0, :lo12:\sym
    ldr w0, [x0]
    ret
.global netconfig_set_\name
netconfig_set_\name:
    adrp x1, \sym
    add x1, x1, :lo12:\sym
    str w0, [x1]
    mov x0, #0
    ret
.endm

NETCONFIG_ACCESSOR ip, netconfig_ip
NETCONFIG_ACCESSOR netmask, netconfig_netmask
NETCONFIG_ACCESSOR gateway, netconfig_gateway
NETCONFIG_ACCESSOR source, netconfig_source

/* u32 netconfig_reset(void) -- back to genuinely unconfigured. */
.global netconfig_reset
netconfig_reset:
    adrp x0, netconfig_ip
    add x0, x0, :lo12:netconfig_ip
    str wzr, [x0]
    adrp x1, netconfig_netmask
    add x1, x1, :lo12:netconfig_netmask
    str wzr, [x1]
    adrp x2, netconfig_gateway
    add x2, x2, :lo12:netconfig_gateway
    str wzr, [x2]
    adrp x3, netconfig_source
    add x3, x3, :lo12:netconfig_source
    str wzr, [x3]
    mov x0, #0
    ret
