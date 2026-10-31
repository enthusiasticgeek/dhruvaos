/* DharaFS NAND-FTL two-tier bad-block classification (2026-10-31):
 * a "suspect" table, separate from dharafs_badblock_bitmap's own
 * CONFIRMED-bad bits (boot/dharafs_state.S).
 *
 * Why a separate structure, not just a looser bitmap threshold: this
 * project's own 42-round "SD wedge saga" found the dominant real
 * failure mode on this specific hardware (BCM2835 SDHOST) was
 * CONTROLLER/DRIVER bugs that a reinit clears, not genuine NAND-style
 * media wear -- matching Linux UBI's own precedent of torture-testing
 * a suspect PEB before confirming it bad, rather than blacklisting on
 * the very first failure (see kernel_main.vani's own dharafs_
 * badblock_report_failure for the full policy). A suspect here must
 * fail again on a SEPARATE boot (not just a second attempt within the
 * same boot) before being promoted to the confirmed bitmap --
 * deliberately, since only an actual reboot gives sdhost_init() a
 * genuinely fresh controller reset; retrying within the same boot
 * session already happens via the normal 3-attempt ladder and proved
 * insufficient on its own.
 *
 * 512-byte block, matching every other DharaFS metadata block's own
 * layout convention: [0:4) checksum, [4:512) up to 127 entries of
 * one u32 block number each (120 used, leaving headroom); 0 means
 * "empty slot" (block 0 is never a real suspect -- the log's own
 * scan always starts at block 1). Deliberately NOT mirrored the way
 * dharafs_badblock_bitmap_block_0/1 now are: losing a suspect entry
 * to a crash before the next flush point is the SAFE direction to
 * fail in (the block just gets a fresh benefit of the doubt next
 * time), unlike losing a CONFIRMED-bad entry.
 *
 * dharafs_suspect_count is a cached, RAM-only running count of
 * currently-occupied slots -- checked first by every read/write's own
 * success path (the overwhelmingly common case) so a healthy card
 * with zero suspects pays an O(1) check, never a 120-entry linear
 * scan, to decide whether a just-succeeded access needs to forgive
 * anything. */

.section ".bss"
.align 4
dharafs_suspect_buf_addr:
    .word 0        /* set once at boot via dharafs_suspect_buf_set,
                     * to a 512-byte dhruva_alloc_bytes buffer */
dharafs_suspect_dirty:
    .word 0
dharafs_suspect_count:
    .word 0

.section ".text"
.align 4

.global dharafs_suspect_buf_set
dharafs_suspect_buf_set:
    ldr r1, =dharafs_suspect_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_suspect_buf_get
dharafs_suspect_buf_get:
    ldr r0, =dharafs_suspect_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_suspect_dirty_set
dharafs_suspect_dirty_set:
    ldr r1, =dharafs_suspect_dirty
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_suspect_dirty_get
dharafs_suspect_dirty_get:
    ldr r0, =dharafs_suspect_dirty
    ldr r0, [r0]
    bx lr

.global dharafs_suspect_count_set
dharafs_suspect_count_set:
    ldr r1, =dharafs_suspect_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_suspect_count_get
dharafs_suspect_count_get:
    ldr r0, =dharafs_suspect_count
    ldr r0, [r0]
    bx lr
