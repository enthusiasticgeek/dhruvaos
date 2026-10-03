/* kernlog persistent configuration state (ARM32).
 *
 * Same shape as dhcp_state.S's own plain-u32-value storage: three
 * runtime-reconfigurable knobs for the kernlog feature (a rotating,
 * severity-gated crash/diagnostic log persisted to DharaFS, built on
 * top of the existing dharafs_log_append_raw primitive -- see
 * kernel_main.vani's own kernlog_write for the full design). Every
 * field is `u32`, matching every other state file in this project for
 * the same defensive AAPCS-register-pairing reason (see netif_state.S's
 * own comment on netif_set_slot_len for the bug class this convention
 * exists to prevent by construction).
 *
 * Defaults (applied if /config/kernlog_maxsize or /config/kernlog_
 * backups is absent/unreadable at boot, kernlog_config_init's own
 * concern, not this file's): min_level=CRITICAL(2), maxsize=2048 bytes,
 * backups=3 generations -- the exact numbers the user asked for when
 * this feature was scoped (2026-10-03). */

.section ".bss"
.align 4
kernlog_min_level:
    .word 0        /* 0=unset (kernlog_config_init treats this the same
                     * as "use the default," 2=CRITICAL) -- gates which
                     * kernlog_write calls actually persist: anything
                     * below this level is a no-op before any DharaFS
                     * access is even attempted. */
kernlog_maxsize:
    .word 0        /* 0=unset/use default. Per-generation rollover
                     * threshold in bytes, passed straight through to
                     * dharafs_log_append_raw's own (now parameterized)
                     * rollover_threshold argument -- independent of the
                     * shared dharafs_log_rollover_threshold() constant
                     * the generic `log <name> <text>` shell command
                     * still uses unchanged. */
kernlog_backups:
    .word 0        /* 0=unset/use default. Generation-retention count,
                     * passed straight through to dharafs_log_append_
                     * raw's own (now parameterized) retention_count
                     * argument -- independent of the shared dharafs_
                     * log_retention_count() constant (5) the generic
                     * `log` shell command still uses unchanged. */

.section ".text"

.global kernlog_state_get_min_level
kernlog_state_get_min_level:
    ldr r0, =kernlog_min_level
    ldr r0, [r0]
    bx lr

.global kernlog_state_set_min_level
kernlog_state_set_min_level:
    ldr r1, =kernlog_min_level
    str r0, [r1]
    mov r0, #0
    bx lr

.global kernlog_state_get_maxsize
kernlog_state_get_maxsize:
    ldr r0, =kernlog_maxsize
    ldr r0, [r0]
    bx lr

.global kernlog_state_set_maxsize
kernlog_state_set_maxsize:
    ldr r1, =kernlog_maxsize
    str r0, [r1]
    mov r0, #0
    bx lr

.global kernlog_state_get_backups
kernlog_state_get_backups:
    ldr r0, =kernlog_backups
    ldr r0, [r0]
    bx lr

.global kernlog_state_set_backups
kernlog_state_set_backups:
    ldr r1, =kernlog_backups
    str r0, [r1]
    mov r0, #0
    bx lr
