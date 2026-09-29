/* 2026-09-29: temporary, capped fire-count for task_custom_demo_wake_
 * body's own real-HW UART-corruption diagnostic (kernel_main.vani) --
 * see that call site's own comment for the full "why". Same .bss-
 * word-plus-accessor shape as every other tiny persistent counter in
 * this project (sleep_ticks_diag_fire_count, swi_fast_count, ...).
 * Deliberately its OWN counter, not sharing swi_entry.S's existing
 * sleep_ticks_diag_fire_count -- that budget is already earmarked for
 * task_a's own (unrelated) resume-pc diagnostic; sharing it here would
 * silently steal fire budget from an already-proven, still-useful
 * diagnostic. Remove this whole file (and its one call site) once the
 * UART corruption investigation closes. */

.section ".bss"
.align 2
custom_diag_fire_count:
    .word 0

.section ".text"

.global custom_diag_fire_count_get
custom_diag_fire_count_get:
    ldr r0, =custom_diag_fire_count
    ldr r0, [r0]
    bx lr

.global custom_diag_fire_count_set
custom_diag_fire_count_set:
    ldr r1, =custom_diag_fire_count
    str r0, [r1]
    mov r0, #0
    bx lr
