/* Dhruva round 66 -- GATT's own discovered-services/characteristics
 * tables, the persistent state gatt_discover_primary_services/
 * gatt_discover_characteristics (kernel_main.vani) build up across a
 * connection's discovery phase and later GATT read/write calls look
 * handles up in.
 *
 * Fixed-size tables (8 services, 32 characteristics total across all
 * services), matching this project's own established "fixed-size,
 * no dynamic allocation for control structures" discipline (MAX_TASKS,
 * the ARP cache, TCP connection slots, ...) -- generous for a typical
 * embedded BLE peripheral's own service/characteristic count without
 * needing a real allocator.
 *
 * Every accessor here takes AT MOST 2 plain u32 arguments (an index
 * plus, for setters, one field's value) -- deliberately, to fit
 * entirely in r0/r1 with ZERO scratch registers beyond r0-r3/r12
 * needed anywhere in this file. This project has hit the "r4-r11 are
 * callee-saved, clobbering them unsaved corrupts a live compiler
 * value" bug class twice now in small assembly accessors exactly this
 * shape (see feedback_aapcs_callee_saved_registers_asm and project
 * memory on round 65's task_f corruption bug) -- the fix here isn't
 * "remember to push/pop," it's designing the API so there's nothing
 * to save in the first place: one field written or read per call,
 * never a multi-field struct-at-once setter that would need more
 * registers than r0/r1 can hold.
 */

.section ".bss"
.align 4
gatt_service_count:
    .word 0
gatt_service_start_handle:
    .space 32   /* 8 words */
gatt_service_end_handle:
    .space 32
gatt_service_uuid16:
    .space 32
gatt_char_count:
    .word 0
gatt_char_decl_handle:
    .space 128  /* 32 words */
gatt_char_properties:
    .space 128
gatt_char_value_handle:
    .space 128
gatt_char_uuid16:
    .space 128
gatt_char_service_index:
    .space 128

.section ".text"

.global gatt_service_get_count
gatt_service_get_count:
    ldr r0, =gatt_service_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global gatt_service_set_count
gatt_service_set_count:
    ldr r1, =gatt_service_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_service_get_start_handle_at
gatt_service_get_start_handle_at:
    ldr r1, =gatt_service_start_handle
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_service_set_start_handle_at
gatt_service_set_start_handle_at:
    ldr r2, =gatt_service_start_handle
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_service_get_end_handle_at
gatt_service_get_end_handle_at:
    ldr r1, =gatt_service_end_handle
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_service_set_end_handle_at
gatt_service_set_end_handle_at:
    ldr r2, =gatt_service_end_handle
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_service_get_uuid16_at
gatt_service_get_uuid16_at:
    ldr r1, =gatt_service_uuid16
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_service_set_uuid16_at
gatt_service_set_uuid16_at:
    ldr r2, =gatt_service_uuid16
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_count
gatt_char_get_count:
    ldr r0, =gatt_char_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global gatt_char_set_count
gatt_char_set_count:
    ldr r1, =gatt_char_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_decl_handle_at
gatt_char_get_decl_handle_at:
    ldr r1, =gatt_char_decl_handle
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_char_set_decl_handle_at
gatt_char_set_decl_handle_at:
    ldr r2, =gatt_char_decl_handle
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_properties_at
gatt_char_get_properties_at:
    ldr r1, =gatt_char_properties
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_char_set_properties_at
gatt_char_set_properties_at:
    ldr r2, =gatt_char_properties
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_value_handle_at
gatt_char_get_value_handle_at:
    ldr r1, =gatt_char_value_handle
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_char_set_value_handle_at
gatt_char_set_value_handle_at:
    ldr r2, =gatt_char_value_handle
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_uuid16_at
gatt_char_get_uuid16_at:
    ldr r1, =gatt_char_uuid16
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_char_set_uuid16_at
gatt_char_set_uuid16_at:
    ldr r2, =gatt_char_uuid16
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_char_get_service_index_at
gatt_char_get_service_index_at:
    ldr r1, =gatt_char_service_index
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_char_set_service_index_at
gatt_char_set_service_index_at:
    ldr r2, =gatt_char_service_index
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr
