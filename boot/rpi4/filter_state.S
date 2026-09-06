/* Dhruva round 88 -- Phase A step 3 of the networking/SSH/WiFi scope
 * (see project memory project_dhruva_networking_ssh_wifi_scope_
 * 2026_09_06.md): packet filter rule table, direct port of
 * kernel_main.vani's own boot/fw_state.S design (same 8-slot fixed
 * array, same field layout, same first-match-wins-in-array-order
 * semantics falling through to a default policy) -- see that file's
 * own header comment for the full rationale, unchanged here.
 *
 * The AAPCS64 calling convention makes this port's `filter_add_rule`
 * structurally simpler than Pi 1's ARM32 `fw_add_rule`: AArch64 gives
 * a callee 8 argument registers (x0-x7), so all 6 of this function's
 * arguments arrive in registers with no stack spill at all -- Pi 1's
 * own fw_add_rule needed 2 stack-spilled args (5th/6th, per AAPCS32's
 * only-4-register convention) and, in a real bug found round 72 (see
 * [[feedback_aapcs_callee_saved_registers_asm]]), extra scratch
 * registers it forgot to save/restore. Neither hazard exists here:
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
filter_rule_count:      .word 0
filter_default_policy:  .word 0   /* 0=deny, 1=allow -- .bss zero-init
                                    * means "deny" until kernel_main_
                                    * rpi4.vani's own boot sequence
                                    * explicitly sets allow, same
                                    * reasoning as Pi 1's own comment */
.align 4
filter_rule_proto:          .space 32  /* 8 * 4 bytes/u32 */
.align 4
filter_rule_src_ip:         .space 32
.align 4
filter_rule_src_ip_valid:   .space 32
.align 4
filter_rule_dst_port:       .space 32
.align 4
filter_rule_dst_port_valid: .space 32
.align 4
filter_rule_action:         .space 32

.section ".text"

.global filter_get_rule_count
filter_get_rule_count:
    adrp x0, filter_rule_count
    add x0, x0, :lo12:filter_rule_count
    ldr w0, [x0]
    ret

.global filter_get_default_policy
filter_get_default_policy:
    adrp x0, filter_default_policy
    add x0, x0, :lo12:filter_default_policy
    ldr w0, [x0]
    ret

/* u32 filter_set_default_policy(u32 value) */
.global filter_set_default_policy
filter_set_default_policy:
    adrp x1, filter_default_policy
    add x1, x1, :lo12:filter_default_policy
    str w0, [x1]
    mov x0, #0
    ret

.global filter_flush
filter_flush:
    adrp x0, filter_rule_count
    add x0, x0, :lo12:filter_rule_count
    str wzr, [x0]
    mov x0, #0
    ret

/* i64 filter_add_rule(u32 proto, u32 src_ip, u32 src_ip_valid,
 *                     u32 dst_port, u32 dst_port_valid, u32 action)
 * -- x0-x5 hold all six args directly, no stack spill needed on
 * AArch64. Returns 0 on success, -1 if the table is already full
 * (8 rules). */
.global filter_add_rule
filter_add_rule:
    adrp x6, filter_rule_count
    add x6, x6, :lo12:filter_rule_count
    ldr w7, [x6]
    cmp w7, #8
    b.ge .Lfar_full

    adrp x8, filter_rule_proto
    add x8, x8, :lo12:filter_rule_proto
    str w0, [x8, w7, uxtw #2]

    adrp x9, filter_rule_src_ip
    add x9, x9, :lo12:filter_rule_src_ip
    str w1, [x9, w7, uxtw #2]

    adrp x10, filter_rule_src_ip_valid
    add x10, x10, :lo12:filter_rule_src_ip_valid
    str w2, [x10, w7, uxtw #2]

    adrp x11, filter_rule_dst_port
    add x11, x11, :lo12:filter_rule_dst_port
    str w3, [x11, w7, uxtw #2]

    adrp x12, filter_rule_dst_port_valid
    add x12, x12, :lo12:filter_rule_dst_port_valid
    str w4, [x12, w7, uxtw #2]

    adrp x13, filter_rule_action
    add x13, x13, :lo12:filter_rule_action
    str w5, [x13, w7, uxtw #2]

    add w7, w7, #1
    str w7, [x6]
    mov x0, #0
    ret

.Lfar_full:
    mov x0, #-1
    ret

.global filter_get_rule_proto
filter_get_rule_proto:
    adrp x1, filter_rule_proto
    add x1, x1, :lo12:filter_rule_proto
    ldr w0, [x1, w0, uxtw #2]
    ret

.global filter_get_rule_src_ip
filter_get_rule_src_ip:
    adrp x1, filter_rule_src_ip
    add x1, x1, :lo12:filter_rule_src_ip
    ldr w0, [x1, w0, uxtw #2]
    ret

.global filter_get_rule_src_ip_valid
filter_get_rule_src_ip_valid:
    adrp x1, filter_rule_src_ip_valid
    add x1, x1, :lo12:filter_rule_src_ip_valid
    ldr w0, [x1, w0, uxtw #2]
    ret

.global filter_get_rule_dst_port
filter_get_rule_dst_port:
    adrp x1, filter_rule_dst_port
    add x1, x1, :lo12:filter_rule_dst_port
    ldr w0, [x1, w0, uxtw #2]
    ret

.global filter_get_rule_dst_port_valid
filter_get_rule_dst_port_valid:
    adrp x1, filter_rule_dst_port_valid
    add x1, x1, :lo12:filter_rule_dst_port_valid
    ldr w0, [x1, w0, uxtw #2]
    ret

.global filter_get_rule_action
filter_get_rule_action:
    adrp x1, filter_rule_action
    add x1, x1, :lo12:filter_rule_action
    ldr w0, [x1, w0, uxtw #2]
    ret
