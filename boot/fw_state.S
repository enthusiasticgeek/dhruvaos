/* Dhruva Round 60 -- packet filtering rule table, same .bss-plus-
 * accessor shape as every other small state module in this project
 * (usb_msd_state.S/usb_net_state.S/usb_bt_state.S/usb_wifi_state.S).
 *
 * A small FIXED array (8 rules), matching this project's own "small
 * fixed arrays, not dynamic allocation" convention elsewhere
 * (MAX_MUTEXES=4, MAX_TASKS=16, MAX_HOST_TCP_CONN) -- no need for
 * anything bigger for a single-host demo firewall.
 *
 * Each rule: proto (0=any, 1=ICMP, 6=TCP, 17=UDP -- matching the real
 * IPv4 protocol numbers this project's own ipv4_get_protocol already
 * returns, so no translation table is needed), src_ip + src_ip_valid
 * (0=wildcard), dst_port + dst_port_valid (0=wildcard, meaningless for
 * ICMP which has no ports), action (0=deny, 1=allow). First-match-wins
 * in array order (real iptables semantics), falling through to
 * fw_default_policy if nothing matches.
 *
 * fw_add_rule is the only WRITE path other than fw_flush/fw_set_
 * default_policy -- deliberately one function that appends to the next
 * free slot, rather than separate per-field setters callers would have
 * to sequence correctly themselves (a rule's 6 fields are only ever
 * meaningful written together, unlike e.g. usb_net_state.S's
 * independently-settable endpoint fields). Read access (needed by both
 * filter_check_frame's own matching loop and the `fw list` shell
 * command) still uses individual per-field getters, since vani has no
 * struct/array return-by-value this project's own code generation
 * conventions already lean on elsewhere. */

.section ".bss"
.align 4
fw_rule_count:
    .word 0
fw_default_policy:
    .word 0             /* 0=deny, 1=allow -- .bss zero-init means
                         * "deny by default" until fw_set_default_
                         * policy or fw_add_rule ever runs; see
                         * kernel_main.vani's own boot-time comment on
                         * why the REAL starting default is allow, set
                         * explicitly there, not implicitly here. */
fw_rule_proto:
    .word 0, 0, 0, 0, 0, 0, 0, 0
fw_rule_src_ip:
    .word 0, 0, 0, 0, 0, 0, 0, 0
fw_rule_src_ip_valid:
    .word 0, 0, 0, 0, 0, 0, 0, 0
fw_rule_dst_port:
    .word 0, 0, 0, 0, 0, 0, 0, 0
fw_rule_dst_port_valid:
    .word 0, 0, 0, 0, 0, 0, 0, 0
fw_rule_action:
    .word 0, 0, 0, 0, 0, 0, 0, 0

.section ".text"

.global fw_get_rule_count
fw_get_rule_count:
    ldr r0, =fw_rule_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fw_get_default_policy
fw_get_default_policy:
    ldr r0, =fw_default_policy
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fw_set_default_policy
fw_set_default_policy:
    ldr r1, =fw_default_policy
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global fw_flush
fw_flush:
    ldr r0, =fw_rule_count
    mov r1, #0
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr

/* u32 fw_add_rule(proto, src_ip, src_ip_valid, dst_port, dst_port_
 * valid, action) -- 6 args, so AAPCS spills the last two (dst_port_
 * valid, action) onto the stack (r0-r3 hold the first four). Returns
 * 0 on success, 0xFFFFFFFF if the table is already full (8 rules).
 *
 * BUG FIX (found round 72, 2026-09-05, via a real live symptom -- a
 * caller's own live local values went silently wrong immediately
 * after calling this function, first suspected as a vani-compiler
 * codegen bug and disassembled to rule that out before finding the
 * real cause here): storing 6 fields needs more than the 4 scratch
 * registers (r0-r3) AAPCS actually grants a callee -- this function
 * used r4/r5/r6 as extra scratch (holding the 2 stack-loaded args
 * plus a repeatedly-reloaded table-field-address register) WITHOUT
 * saving/restoring them, silently clobbering whatever the CALLER had
 * live in those same registers. r4-r11 are callee-saved per AAPCS;
 * any hand-written asm function that touches them must push/pop them,
 * exactly like every OTHER hand-written function in this codebase
 * that legitimately needs more than 4 registers already does (see
 * e.g. fn_filter_build_test_frame_dst's own compiler-generated `push
 * {r4, r5, r11, lr}` / `pop {r4, r5, r11, pc}"). Same bug CLASS as
 * this project's own previously-documented AAPCS-callee-saved-
 * register incidents (project memory:
 * feedback_aapcs_callee_saved_registers_asm) -- a new instance, not a
 * regression of an old one; every OTHER function in this file only
 * ever used r0-r3 already and needed no such fix. Pushing 3 registers
 * (12 bytes) shifts the caller's own stack-passed arguments down by
 * 12 bytes too -- the two `ldr ..., [sp, #N]` offsets below account
 * for that explicitly. */
.global fw_add_rule
fw_add_rule:
    push {r4, r5, r6}
    ldr r12, =fw_rule_count
    ldr r12, [r12]
    cmp r12, #8
    bge fw_add_rule_full

    ldr r4, [sp, #12]          /* dst_port_valid (5th arg, stack -- +12 for the 3 pushed registers above) */
    ldr r5, [sp, #16]          /* action (6th arg, stack -- +12 likewise) */

    ldr r6, =fw_rule_proto
    str r0, [r6, r12, lsl #2]
    ldr r6, =fw_rule_src_ip
    str r1, [r6, r12, lsl #2]
    ldr r6, =fw_rule_src_ip_valid
    str r2, [r6, r12, lsl #2]
    ldr r6, =fw_rule_dst_port
    str r3, [r6, r12, lsl #2]
    ldr r6, =fw_rule_dst_port_valid
    str r4, [r6, r12, lsl #2]
    ldr r6, =fw_rule_action
    str r5, [r6, r12, lsl #2]

    add r12, r12, #1
    ldr r6, =fw_rule_count
    str r12, [r6]

    pop {r4, r5, r6}
    mov r0, #0
    mov r1, #0
    bx lr
fw_add_rule_full:
    pop {r4, r5, r6}
    mvn r0, #0
    mov r1, #0
    bx lr

.global fw_get_rule_proto
fw_get_rule_proto:
    ldr r1, =fw_rule_proto
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fw_get_rule_src_ip
fw_get_rule_src_ip:
    ldr r1, =fw_rule_src_ip
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fw_get_rule_src_ip_valid
fw_get_rule_src_ip_valid:
    ldr r1, =fw_rule_src_ip_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fw_get_rule_dst_port
fw_get_rule_dst_port:
    ldr r1, =fw_rule_dst_port
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fw_get_rule_dst_port_valid
fw_get_rule_dst_port_valid:
    ldr r1, =fw_rule_dst_port_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fw_get_rule_action
fw_get_rule_action:
    ldr r1, =fw_rule_action
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr
