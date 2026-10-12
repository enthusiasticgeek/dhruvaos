/* Task #308 Phase 6: deliberately broken "kernel" for the A/B auto-
 * revert drill -- see test/build_bad_kernel.sh and the plan this came
 * from. Its ONLY job is to never reach "PASS", so stage0's attempt-
 * counter/bootlimit fallback has something real to fall back FROM.
 * Not a crash, not a fault -- a kernel that boots fine by stage0's
 * own measure (it jumped here and the CPU is happily executing) but
 * never gets further, exactly the "boots but is useless" case a
 * watchdog/panic handler can't catch and only a boot-count mechanism
 * can.
 *
 * Linked at 0x00200000, the same relocated base boot/rpi1/link.ld
 * uses for the real kernel -- stage0 always jumps there regardless of
 * which slot it picked, so this has to land at the exact address a
 * real candidate would. */
.section ".text.boot"
.global bad_entry
bad_entry:
    b bad_entry
