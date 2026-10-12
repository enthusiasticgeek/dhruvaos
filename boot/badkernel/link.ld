/* Task #308 Phase 6: linker script for the deliberately-broken "bad
 * kernel" auto-revert drill. Linked at 0x00200000 -- the same
 * relocated base boot/rpi1/link.ld uses for the real kernel (Phase 2)
 * -- since stage0 always jumps there regardless of which slot it
 * picked; a candidate kernel that expected anything else would never
 * even reach this file's single instruction correctly. */
ENTRY(bad_entry)

SECTIONS
{
    . = 0x00200000;
    .text.boot : { *(.text.boot) }
}
