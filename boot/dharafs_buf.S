/* Dhruva Phase 3 -- generic byte-buffer accessors for the log-
 * structured filesystem (ARM32).
 *
 * Same underlying reason as sdcard_state.S's FIFO transfer helpers:
 * vani has no operation that turns a `mut ref i64` into the plain
 * integer address mmio_read_u32/mmio_write_u32 need, so any code that
 * has to read/write specific byte offsets within a raw buffer (here,
 * filesystem record fields -- checksum, sequence number, path bytes,
 * data bytes) needs a small hand-written-assembly bridge. The
 * filesystem's actual record format/recovery/append logic all stays
 * in kernel_main.vani; these are pure accessors, no policy.
 *
 * Every parameter here is deliberately `u32`, not `i64`, specifically
 * to sidestep the two AAPCS bug classes Phase 3's SD driver hit and
 * had to fix after the fact (see sdcard_state.S's file-level comment
 * for the full writeup): a `u32` argument or return value is a
 * genuine single 32-bit value under AAPCS, needing exactly one
 * register with no even-pair padding and no high-word return slot to
 * forget -- confirmed empirically (not assumed) by compiling a
 * throwaway probe function and checking its actual callsite
 * disassembly before writing any of the code below. Every function
 * here fits entirely in r0-r3 with no stack-spilled arguments and no
 * use of r4-r11, so there's also nothing to save/restore -- the third
 * bug class from that same writeup doesn't apply here by construction,
 * not by discipline. */

.section ".text"

/* u32 buf_write_byte(mut ref i64 buf, u32 offset, u32 value) */
.global buf_write_byte
buf_write_byte:
    strb r2, [r0, r1]
    mov r0, #0
    bx lr

/* u32 buf_read_byte(mut ref i64 buf, u32 offset) */
.global buf_read_byte
buf_read_byte:
    ldrb r0, [r0, r1]
    bx lr

/* u32 buf_write_u32(mut ref i64 buf, u32 offset, u32 value) */
.global buf_write_u32
buf_write_u32:
    str r2, [r0, r1]
    mov r0, #0
    bx lr

/* u32 buf_read_u32(mut ref i64 buf, u32 offset) */
.global buf_read_u32
buf_read_u32:
    ldr r0, [r0, r1]
    bx lr

/* u32 buf_checksum(mut ref i64 buf, u32 start_offset, u32 len)
 * A simple rotate-and-add mix, not a real CRC -- enough to reliably
 * distinguish a torn/partial write from a genuine one for this
 * project's power-yank testing, without pulling in a real CRC32
 * table for what's still a v1 filesystem. */
.global buf_checksum
buf_checksum:
    mov r3, #0             /* running checksum */
    add r2, r1, r2         /* r2 = end offset (start + len) */
buf_checksum_loop:
    cmp r1, r2
    beq buf_checksum_done
    ldrb r12, [r0, r1]
    mov r3, r3, ror #31    /* rotate left by 1 before mixing in */
    add r3, r3, r12
    add r1, r1, #1
    b buf_checksum_loop
buf_checksum_done:
    mov r0, r3
    bx lr
