/* DharaFS NAND-FTL wear-leveling table: a one-sector (512-byte) RAM
 * cache of whatever wear-table sector (block 9220-9364, see
 * kernel_main.vani's own dharafs_wear_table_sector_for) was most
 * recently touched -- same "RAM-cached, flushed only at defined
 * points" shape as dharafs_ecc_state.S's own cache, for the exact same
 * reason: this table is sparse (8 bytes/erase-unit, 64 entries/sector)
 * and DharaFS's own access pattern is mostly sequential, so caching
 * the one sector currently being touched avoids a second physical SD
 * round trip on every single erase.
 *
 * Deliberately NOT eagerly loading the whole 145-sector table at boot,
 * same reasoning as the ECC cache. Flushed at the same three points
 * dharafs_badblock_bitmap_persist()/dharafs_ecc_cache_flush() already
 * are (compaction completion, `reboot`, `shutdown`) -- a crash before
 * that only means a P/E-cycle count update in the still-dirty sector
 * is lost, which just makes THAT erase-unit look slightly less worn
 * than it really is to dharafs_wear_least_worn_unit_in_range for one
 * boot; never a correctness bug (wear leveling is a bias, not a hard
 * guarantee), unlike the ECC table where a lost update could leave a
 * block uncorrectable. */

.section ".bss"
.align 4
dharafs_wear_cache_sector_num:
    .word 0        /* 0 = "no sector cached yet" -- safe sentinel,
                     * since real wear-table sectors are always
                     * >= 9220 and this field is never actually a
                     * real sector number otherwise */
dharafs_wear_cache_dirty:
    .word 0        /* 1 = the cached sector has writes not yet
                     * flushed back to the SD card */
dharafs_wear_cache_buf_addr:
    .word 0        /* set once at boot via dharafs_wear_cache_buf_set,
                     * to a 512-byte dhruva_alloc_bytes buffer -- the
                     * cached sector's own raw bytes */

.section ".text"
.align 4

.global dharafs_wear_cache_set_sector_num
dharafs_wear_cache_set_sector_num:
    ldr r1, =dharafs_wear_cache_sector_num
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_wear_cache_get_sector_num
dharafs_wear_cache_get_sector_num:
    ldr r0, =dharafs_wear_cache_sector_num
    ldr r0, [r0]
    bx lr

.global dharafs_wear_cache_set_dirty
dharafs_wear_cache_set_dirty:
    ldr r1, =dharafs_wear_cache_dirty
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_wear_cache_get_dirty
dharafs_wear_cache_get_dirty:
    ldr r0, =dharafs_wear_cache_dirty
    ldr r0, [r0]
    bx lr

.global dharafs_wear_cache_buf_set
dharafs_wear_cache_buf_set:
    ldr r1, =dharafs_wear_cache_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_wear_cache_buf_get
dharafs_wear_cache_buf_get:
    ldr r0, =dharafs_wear_cache_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr
