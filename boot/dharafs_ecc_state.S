/* DharaFS NAND-FTL ECC side-table: a one-sector (512-byte) RAM cache
 * of whatever ECC-table sector (block 8224-8800, see kernel_main.vani's
 * own dharafs_ecc_table_sector_for) was most recently touched, so an
 * in-scope SD block's read/write doesn't pay a SECOND physical SD
 * round trip on every single call -- only when the access pattern
 * actually crosses from one 16-block-sharing-one-sector group to
 * another (DharaFS's own access pattern is mostly sequential appends,
 * so this is the common case staying cheap).
 *
 * Deliberately NOT eagerly loading the whole 577-sector table at boot
 * (that would be a real, measured multi-second real-HW SD latency
 * regression on every single boot, for a feature that should otherwise
 * be invisible overhead) -- same "RAM-cached, flushed only at defined
 * points" shape as dharafs_badblock_bitmap (boot/dharafs_state.S), and
 * the exact same lesson this project's own session that built this ECC
 * layer had JUST re-learned the hard way about that other cache: it
 * must be explicitly flushed at well-known points (dharafs_ecc_cache_
 * flush(), called from the same three call sites dharafs_badblock_
 * bitmap_persist() already is -- compaction completion, `reboot`,
 * `shutdown`) or its last dirty sector's updates are lost on a crash.
 * That loss window is bounded and safe either way: a lost ECC-table
 * update only means a future read of blocks in that one sector can't
 * be CORRECTED if corrupted (falls back to today's plain checksum-
 * failure behavior), never that the system trusts wrong data. */

.section ".bss"
.align 4
dharafs_ecc_cache_sector_num:
    .word 0        /* 0 = "no sector cached yet" -- safe sentinel,
                     * since real ECC-table sectors are always
                     * >= 8224 and this field is never actually a
                     * real sector number otherwise */
dharafs_ecc_cache_dirty:
    .word 0        /* 1 = the cached sector has writes not yet
                     * flushed back to the SD card */
dharafs_ecc_cache_buf_addr:
    .word 0        /* set once at boot via dharafs_ecc_cache_buf_set,
                     * to a 512-byte dhruva_alloc_bytes buffer -- the
                     * cached sector's own raw bytes */

.section ".text"
.align 4

.global dharafs_ecc_cache_set_sector_num
dharafs_ecc_cache_set_sector_num:
    ldr r1, =dharafs_ecc_cache_sector_num
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_ecc_cache_get_sector_num
dharafs_ecc_cache_get_sector_num:
    ldr r0, =dharafs_ecc_cache_sector_num
    ldr r0, [r0]
    bx lr

.global dharafs_ecc_cache_set_dirty
dharafs_ecc_cache_set_dirty:
    ldr r1, =dharafs_ecc_cache_dirty
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_ecc_cache_get_dirty
dharafs_ecc_cache_get_dirty:
    ldr r0, =dharafs_ecc_cache_dirty
    ldr r0, [r0]
    bx lr

.global dharafs_ecc_cache_buf_set
dharafs_ecc_cache_buf_set:
    ldr r1, =dharafs_ecc_cache_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_ecc_cache_buf_get
dharafs_ecc_cache_buf_get:
    ldr r0, =dharafs_ecc_cache_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr
