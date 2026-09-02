/* Dhruva round 66 -- GATT SERVER's own attribute database: Dhruva's
 * own exposed services/characteristics, the state gatt_server_add_
 * service/_characteristic (kernel_main.vani) build up and gatt_
 * server_handle_request dispatches ATT requests against.
 *
 * A flat, handle-ordered table (not separate service/characteristic
 * tables like the CLIENT side's gatt_state.S) -- a real GATT server's
 * own attribute database genuinely IS just one ordered list where a
 * "service" is one entry (type 0x2800) and each "characteristic" is
 * two more (a 0x2803 declaration, then its own value entry, typed by
 * the characteristic's own UUID) -- matching the wire protocol
 * directly rather than a higher-level model requiring translation at
 * dispatch time. 32 attributes max (same fixed-size-table convention
 * as gatt_state.S), each attribute's own HANDLE is simply its array
 * index + 1 (GATT handles start at 0x0001) -- deliberately not stored
 * separately, one less field to keep in sync.
 *
 * Every accessor here still takes at most 2 arguments, same reasoning
 * as gatt_state.S's own header comment (this project's own AAPCS
 * bug class, caught and fixed twice already this same round rather
 * than re-risked a third time). Value bytes specifically use a
 * CALLER-COMPUTED combined index (attr_index * 20 + byte_offset,
 * multiplication done safely in vani, not here) instead of a genuine
 * 2D (attr_index, byte_offset) access, so even byte-level value
 * storage stays a single-index, single-value 2-argument accessor. */

.section ".bss"
.align 4
gatt_server_attr_count:
    .word 0
gatt_server_attr_uuid16:
    .space 128  /* 32 words */
gatt_server_attr_value_len:
    .space 128
gatt_server_attr_writable:
    .space 128  /* 0 or 1 per attribute */
gatt_server_attr_value_bytes:
    .space 640  /* 32 attributes * 20 bytes max value each, byte-addressed */

.section ".text"

.global gatt_server_attr_get_count
gatt_server_attr_get_count:
    ldr r0, =gatt_server_attr_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global gatt_server_attr_set_count
gatt_server_attr_set_count:
    ldr r1, =gatt_server_attr_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_server_attr_get_uuid16_at
gatt_server_attr_get_uuid16_at:
    ldr r1, =gatt_server_attr_uuid16
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_server_attr_set_uuid16_at
gatt_server_attr_set_uuid16_at:
    ldr r2, =gatt_server_attr_uuid16
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_server_attr_get_value_len_at
gatt_server_attr_get_value_len_at:
    ldr r1, =gatt_server_attr_value_len
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_server_attr_set_value_len_at
gatt_server_attr_set_value_len_at:
    ldr r2, =gatt_server_attr_value_len
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global gatt_server_attr_get_writable_at
gatt_server_attr_get_writable_at:
    ldr r1, =gatt_server_attr_writable
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global gatt_server_attr_set_writable_at
gatt_server_attr_set_writable_at:
    ldr r2, =gatt_server_attr_writable
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 gatt_server_attr_get_value_byte(i64 combined_index) -- caller
 * (vani) computes combined_index = attr_index*20 + byte_offset. */
.global gatt_server_attr_get_value_byte
gatt_server_attr_get_value_byte:
    ldr r1, =gatt_server_attr_value_bytes
    ldrb r0, [r1, r0]
    mov r1, #0
    bx lr

.global gatt_server_attr_set_value_byte
gatt_server_attr_set_value_byte:
    ldr r2, =gatt_server_attr_value_bytes
    strb r1, [r2, r0]
    mov r0, #0
    mov r1, #0
    bx lr
