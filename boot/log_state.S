/* Round 2026-09-28 (log-level configurability): UART log verbosity
 * mask (ARM32). Same shape as every other .bss-plus-accessor file in
 * this project (governor_state.S, throttled_state.S) -- gated print
 * sites live inside #[no_heap]/#[wcet(...)]-tagged task bodies, no
 * dhruva_alloc_bytes available, and need a value that survives across
 * many separate calls (one per wake), with no top-level vani global
 * to hold it instead.
 *
 * One bit per log category, read fresh at every gated call site via
 * log_state_get_mask() rather than cached -- lets `loglevel`-style
 * runtime changes (should this project ever add one) take effect on
 * the very next print, not just the next boot. See kernel_main.vani's
 * own header comment near the LOG_CAT_* usage sites for the current
 * bit assignments and which categories are actually wired up to real
 * gated call sites yet (only DEMO/bit2 and GC/bit3 as of this round --
 * SELFTEST/bit0 and DIAG/bit1 are reserved for a future round, per the
 * user's own explicit choice to keep boot self-test PASS/FAIL verdicts
 * unconditionally visible for now rather than risk regressing this
 * project's own primary real-HW debugging tool).
 *
 * Default (no /config/loglevel file present, or file unreadable/
 * invalid): 0 -- DEMO and GC chatter both quiet out of the box, since
 * the whole point of this feature is a clean default console
 * experience, with the config file as the explicit opt-back-in path
 * for anyone (a future debugging session, most likely) who wants the
 * continuous scheduler/GC liveness proof back. */

.section ".bss"
.align 2
log_mask:
    .word 0

.section ".text"

.global log_state_get_mask
log_state_get_mask:
    ldr r0, =log_mask
    ldr r0, [r0]
    bx lr

.global log_state_set_mask
log_state_set_mask:
    ldr r1, =log_mask
    str r0, [r1]
    mov r0, #0
    bx lr
