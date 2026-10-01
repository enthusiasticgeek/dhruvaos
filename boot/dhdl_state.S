/* DHDL Phase 0 (2026-09-28, task #294): generic subsystem registration
 * table + indirect-call dispatch, the one genuinely new mechanism the
 * DHDL roadmap needs (docs/DHDL_ROADMAP.md) -- everything else in that
 * roadmap is applying already-shipped patterns (the /config/<name>
 * file convention, .bss+accessor state) to more subsystems.
 *
 * Deliberately NOT a vani-level array of fn-typed values: this
 * project's only precedent for storing/calling a function value
 * (task_create's own entry_fn parameter) passes exactly ONE fn value
 * across the extern "C" boundary per call, at a handful of fixed call
 * sites -- there is no established pattern anywhere in this codebase
 * for a vani-level array of DIFFERENT fn values, indexed and called at
 * runtime. Real function-pointer TABLE storage and indirect dispatch
 * already exists in this project (the scheduler's own task table), and
 * it lives here in hand-written assembly for exactly the same reason:
 * an address is just a 32-bit word, and calling through one (`bx r0`)
 * is a single, well-understood ARM instruction -- no need to discover
 * whether vani's own type system can express this before shipping a
 * small, working mechanism.
 *
 * Deliberately NOT storing subsystem NAMES here either -- string
 * comparison against `Str` literals is vani's own strength (see
 * shell_word_matches, already used for every other shell subcommand),
 * so name<->id mapping stays in kernel_main.vani, and this file only
 * ever touches plain u32 ids and function-pointer words. Small, fixed
 * capacity -- this project's own established "no dynamic collections,
 * fixed-size + linear scan" convention (see dirindex_state.S's own
 * header comment).
 *
 * Raised 8 -> 12 (2026-10-01, task #297, DHDL Phase 3): Phase 1/2
 * already registered 6 (loglevel/sd/gpio/display/dma/ram); Phase 3's
 * 4 USB-backed subsystems (usb/ethernet/wifi/ble) would have been the
 * 9th slot, exactly the trigger this file's own header used to name
 * for when to raise the cap. 12 gives 2 spare slots beyond this
 * round's 10, not a large arbitrary headroom -- raise again the day a
 * 13th subsystem needs registering, not before. */

.section ".bss"
.align 2
dhdl_slot_ids:
    .space 48      /* 12 slots * 4 bytes, u32 id each; 0 = never used */
dhdl_slot_fns:
    .space 48      /* 12 slots * 4 bytes, function-pointer word each */
dhdl_slot_count:
    .word 0

/* DHDL Phase 4 (2026-10-01, task #298): a SEPARATE table for `dhdl
 * set`, not a reuse of the describe table above -- a setter fn takes
 * one u32 argument (the new value) where a describe fn takes none,
 * so the two can't share one dispatch path without the call site
 * somehow knowing which shape to invoke. Same fixed-capacity, same
 * id<->fn-pointer shape, same linear-scan dispatch; only the register
 * plumbing around the final `bx` differs (the value has to survive
 * the scan and land in r0 for the target, where dhdl_call_by_id's
 * scan has nothing to preserve). Not every dhdl_register'd subsystem
 * is expected to ALSO call dhdl_register_setter -- per docs/
 * DHDL_ROADMAP.md, whether a subsystem's live parameters are safe to
 * change at runtime is a per-subsystem safety question, never a
 * property of this mechanism, so most subsystems are expected to
 * stay query-only indefinitely. */
dhdl_setter_ids:
    .space 48      /* 12 slots * 4 bytes, u32 id each; 0 = never used */
dhdl_setter_fns:
    .space 48      /* 12 slots * 4 bytes, function-pointer word each */
dhdl_setter_count:
    .word 0

.section ".text"

/* i64 dhdl_register(id: u32, fn: fn() -> i64) -- r0=id (nonzero),
 * r1=function pointer. Returns 0 on success, -1 if the table is full.
 * Called once per subsystem at boot, same shape as every other one-
 * time init call in kernel_main (dharafs_init, log_level_init, ...). */
.global dhdl_register
dhdl_register:
    push {r4, r5, lr}
    ldr r2, =dhdl_slot_count
    ldr r3, [r2]
    cmp r3, #12
    bge dhdl_register_full
    ldr r4, =dhdl_slot_ids
    str r0, [r4, r3, lsl #2]
    ldr r4, =dhdl_slot_fns
    str r1, [r4, r3, lsl #2]
    add r3, r3, #1
    str r3, [r2]
    mov r0, #0
    mov r1, #0
    pop {r4, r5, lr}
    bx lr
dhdl_register_full:
    mvn r0, #0
    mvn r1, #0
    pop {r4, r5, lr}
    bx lr

/* i64 dhdl_call_by_id(id: u32) -- r0=id. Linear-scans the table for a
 * matching slot and TAIL-CALLS its stored function pointer -- lr is
 * already restored to this function's own caller before the `bx r0`,
 * so the target's own `bx lr` returns directly to whoever called
 * dhdl_call_by_id, and its i64 return value (r0:r1) is exactly what
 * dhdl_call_by_id itself appears to have returned. Returns -1:-1
 * (both halves of the i64) if no slot matches. */
.global dhdl_call_by_id
dhdl_call_by_id:
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r5, =dhdl_slot_count
    ldr r5, [r5]
    mov r6, #0
dhdl_call_loop:
    cmp r6, r5
    bge dhdl_call_not_found
    ldr r0, =dhdl_slot_ids
    ldr r0, [r0, r6, lsl #2]
    cmp r0, r4
    beq dhdl_call_found
    add r6, r6, #1
    b dhdl_call_loop
dhdl_call_found:
    ldr r0, =dhdl_slot_fns
    ldr r0, [r0, r6, lsl #2]
    pop {r4, r5, r6, lr}
    bx r0
dhdl_call_not_found:
    pop {r4, r5, r6, lr}
    mvn r0, #0
    mvn r1, #0
    bx lr

/* i64 dhdl_list_count() -- how many subsystems are registered. */
.global dhdl_list_count
dhdl_list_count:
    ldr r0, =dhdl_slot_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* u32 dhdl_list_id_at(index: u32) -- deliberately u32, not i64, for
 * the same reason this project's own SD driver comments already
 * document (sdhost_drain_fifo_to_buffer's header comment): an i64
 * parameter is passed as an r0:r1 REGISTER PAIR per AAPCS, a real,
 * previously-hit pitfall this codebase actively avoids wherever a
 * plain small integer is all that's ever needed. Returns the id
 * stored at that slot, or 0 if index is out of range. */
.global dhdl_list_id_at
dhdl_list_id_at:
    ldr r1, =dhdl_slot_count
    ldr r1, [r1]
    cmp r0, r1
    movge r0, #0
    bxge lr
    ldr r1, =dhdl_slot_ids
    ldr r0, [r1, r0, lsl #2]
    bx lr

/* i64 dhdl_register_setter(id: u32, setter: fn(u32) -> i64) -- same
 * shape and same call-once-at-boot contract as dhdl_register above,
 * just targeting the separate setter table. */
.global dhdl_register_setter
dhdl_register_setter:
    push {r4, r5, lr}
    ldr r2, =dhdl_setter_count
    ldr r3, [r2]
    cmp r3, #12
    bge dhdl_register_setter_full
    ldr r4, =dhdl_setter_ids
    str r0, [r4, r3, lsl #2]
    ldr r4, =dhdl_setter_fns
    str r1, [r4, r3, lsl #2]
    add r3, r3, #1
    str r3, [r2]
    mov r0, #0
    mov r1, #0
    pop {r4, r5, lr}
    bx lr
dhdl_register_setter_full:
    mvn r0, #0
    mvn r1, #0
    pop {r4, r5, lr}
    bx lr

/* i64 dhdl_set_by_id(id: u32, value: u32) -- r0=id, r1=value.
 * Linear-scans the setter table for a matching slot and TAIL-CALLS
 * its stored function pointer with r0=value (the shape every
 * registered setter fn expects, `fn(u32) -> i64`) -- same transparent
 * return-value passthrough as dhdl_call_by_id. Returns -1:-1 if no
 * slot matches (the subsystem either doesn't exist or was never
 * registered as settable). */
.global dhdl_set_by_id
dhdl_set_by_id:
    push {r4, r5, r6, r7, lr}
    mov r4, r0              /* id */
    mov r7, r1               /* value, preserved across the scan */
    ldr r5, =dhdl_setter_count
    ldr r5, [r5]
    mov r6, #0
dhdl_set_loop:
    cmp r6, r5
    bge dhdl_set_not_found
    ldr r0, =dhdl_setter_ids
    ldr r0, [r0, r6, lsl #2]
    cmp r0, r4
    beq dhdl_set_found
    add r6, r6, #1
    b dhdl_set_loop
dhdl_set_found:
    ldr r1, =dhdl_setter_fns
    ldr r1, [r1, r6, lsl #2]  /* r1 = target fn pointer */
    mov r0, r7                /* r0 = value, the arg the target expects */
    pop {r4, r5, r6, r7, lr}
    bx r1
dhdl_set_not_found:
    pop {r4, r5, r6, r7, lr}
    mvn r0, #0
    mvn r1, #0
    bx lr
