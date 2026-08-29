/* Host-side ASAN/UBSAN test driver for DharaFS + crypto/bignum logic
 * lifted directly from kernel_main.vani (via kernel_gen_patched.c --
 * see unstatic.py's own comment for why the generated file needs
 * patching before a separate translation unit can call into it).
 *
 * Deliberately calls the CORE logic functions (the _raw variants, and
 * dharafs_list_dir_raw only ever in "classify" mode with query_len >
 * 0), never the existing `_self_test` wrapper functions -- those call
 * uart_puts/uart_putc, which lower to raw MMIO pointer dereferences
 * baked directly into the generated C (compiler builtins, not
 * interceptable extern calls) and would segfault dereferencing an
 * unmapped hardware address on a host process. dharafs_list_dir_raw
 * itself has this same trap in its OTHER mode (query_len == 0 prints
 * the listing via uart_puts/uart_putc) -- never call it that way here.
 *
 * Storage goes through the dev==2 host_virtual_disk_read/write
 * backend (host_stubs.c) -- an in-memory array standing in for a real
 * SD card, so DharaFS's actual on-disk format/recovery/compaction
 * logic runs for real, just against host memory instead of hardware.
 *
 * Build/run via build_and_run.sh, which regenerates kernel_gen.c from
 * the CURRENT kernel_main.vani every time -- this harness tests
 * whatever the source currently says, not a stale snapshot.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>

/* ---- vani-defined functions this harness calls directly (see
 * unstatic.py's WHITELIST -- these are exactly the functions patched
 * from `static` to external linkage in kernel_gen_patched.c). ---- */
int64_t fn_dharafs_check_permission(uint32_t owner_uid, uint32_t owner_gid, uint32_t mode, uint32_t req_uid, uint32_t req_gid, int64_t want_read, int64_t want_write, int64_t want_exec);
int64_t fn_dharafs_init(void);
int64_t fn_dharafs_append_raw(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_append(const char *path, const char *data);
int64_t fn_dharafs_read_raw_checked(int64_t *path_buf, int64_t path_len, int64_t *out_buf, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_write_raw_checked(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_delete_raw_checked(int64_t *path_buf, int64_t path_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_find_latest_block_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_compact(int64_t *buf, int64_t *path_buf, int64_t *data_buf);
int64_t fn_dharafs_stat_raw(int64_t *path_buf, int64_t path_len, int64_t *meta_buf);
int64_t fn_dharafs_stat(const char *path, int64_t *meta_buf);
int64_t fn_dharafs_read_raw(int64_t *path_buf, int64_t path_len, int64_t *out_buf);
int64_t fn_dharafs_read(const char *path, int64_t *out_buf);
int64_t fn_dharafs_delete_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_rename_raw(int64_t *old_path_buf, int64_t old_path_len, int64_t *new_path_buf, int64_t new_path_len);
int64_t fn_dharafs_rename_raw_checked(int64_t *old_path_buf, int64_t old_path_len, int64_t *new_path_buf, int64_t new_path_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_verified_companion_path_raw(int64_t *path_buf, int64_t path_len, int64_t *out_buf);
int64_t fn_dharafs_log_rollover_threshold(void);
int64_t fn_dharafs_log_record_max_len(void);
int64_t fn_dharafs_log_path_raw(int64_t *name_buf, int64_t name_len, uint32_t index, int64_t *out_buf);
int64_t fn_dharafs_log_header_path_raw(int64_t *name_buf, int64_t name_len, int64_t *out_buf);
int64_t fn_dharafs_log_append_raw(int64_t *name_buf, int64_t name_len, int64_t *record_buf, int64_t record_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
uint32_t fn_dharafs_attr_immutable(void);
uint32_t fn_dharafs_attr_append_only(void);
uint32_t fn_dharafs_attr_system(void);
int64_t fn_dharafs_mode_is_immutable(uint32_t mode);
int64_t fn_dharafs_mode_is_append_only(uint32_t mode);
int64_t fn_dharafs_is_valid_append_only_write(int64_t *old_buf, int64_t old_len, int64_t *new_buf, int64_t new_len);
int64_t fn_dharafs_set_attr_raw(int64_t *path_buf, int64_t path_len, uint32_t new_attr_bits, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_get_attr_raw(int64_t *path_buf, int64_t path_len);
int64_t fn_dharafs_write_verified_raw(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t owner_uid, uint32_t owner_gid, uint32_t mode);
int64_t fn_dharafs_write_verified_checked(int64_t *path_buf, int64_t path_len, int64_t *data_buf, int64_t data_len, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_read_verified_checked(int64_t *path_buf, int64_t path_len, int64_t *out_buf, uint32_t req_uid, uint32_t req_gid);
int64_t fn_dharafs_delete(const char *path);
int64_t fn_dharafs_dirlist_seen_contains(int64_t *seen, int64_t count, int64_t *path_buf, int64_t seg_start, int64_t seg_len);
int64_t fn_dharafs_dirlist_segment_equals(int64_t *query_buf, int64_t query_len, int64_t *path_buf, int64_t seg_start, int64_t seg_len);
int64_t fn_dharafs_list_dir_raw(int64_t *dir_buf, int64_t dir_len, int64_t *query_buf, int64_t query_len);
int64_t fn_dharafs_block_payload_cap(void);
int64_t fn_dharafs_file_max_len(void);
uint32_t fn_dharafs_default_mode(void);
int64_t fn_sha256_hash(int64_t *msg, int64_t msg_len, int64_t *out);
int64_t fn_sha256_bytes_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_chacha20_encrypt(int64_t *key, int64_t *nonce, uint32_t initial_counter, int64_t *in_buf, int64_t in_len, int64_t *state_buf, int64_t *working_buf, int64_t *keystream_buf, int64_t *out_buf);
int64_t fn_chacha20_bytes_equal(int64_t *a, int64_t *b, int64_t n);
uint32_t fn_bignum_add_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
uint32_t fn_bignum_sub_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
int64_t fn_bignum_mul_raw(int64_t *a, int64_t *b, int64_t *out, int64_t n);
int64_t fn_bignum_cmp_raw(int64_t *a, int64_t *b, int64_t n);
int64_t fn_bignum_limbs_equal(int64_t *a, int64_t *b, int64_t n);
int64_t fn_bignum_set_limbs4(int64_t *buf, uint32_t l0, uint32_t l1, uint32_t l2, uint32_t l3);

/* ---- host_stubs.c helpers ---- */
int64_t *dhruva_alloc_bytes(int64_t n);
uint32_t buf_read_byte(int64_t *buf, uint32_t offset);
uint32_t buf_write_byte(int64_t *buf, uint32_t offset, uint32_t value);
uint32_t buf_read_u32(int64_t *buf, uint32_t offset);
uint32_t buf_write_u32(int64_t *buf, uint32_t offset, uint32_t value);
uint32_t buf_checksum(int64_t *buf, uint32_t start_offset, uint32_t byte_len);
uint32_t dharafs_state_set_block_dev(uint32_t dev);
int64_t host_virtual_disk_read(int64_t block_num, int64_t *buf);
int64_t host_virtual_disk_write(int64_t block_num, int64_t *buf);
void host_virtual_disk_reset(void);

static int g_pass = 0, g_fail = 0;

#define CHECK(cond, desc)                                                 \
    do {                                                                 \
        if (cond) {                                                      \
            g_pass++;                                                    \
        } else {                                                         \
            g_fail++;                                                    \
            printf("FAIL: %s (%s:%d)\n", desc, __FILE__, __LINE__);      \
        }                                                                \
    } while (0)

/* Scratch buffers, sized EXACTLY like the real boot sequence
 * (kernel_main.vani's own dharafs_sd_scratch_set(dhruva_alloc_bytes(512))
 * etc.) so ASAN's redzones sit at the real production boundary. */
static int64_t *g_sd_scratch, *g_path_scratch, *g_data_scratch, *g_stat_scratch, *g_dir_scratch;

extern int64_t dharafs_sd_scratch_set(int64_t *addr);
extern int64_t dharafs_path_scratch_set(int64_t *addr);
extern int64_t dharafs_data_scratch_set(int64_t *addr);
extern int64_t dharafs_stat_scratch_set(int64_t *addr);
extern int64_t dharafs_dir_scratch_set(int64_t *addr);
extern int64_t dharafs_log_path_scratch_set(int64_t *addr);
extern int64_t dharafs_log_header_path_scratch_set(int64_t *addr);
extern int64_t dharafs_log_header_data_scratch_set(int64_t *addr);
extern int64_t dharafs_log_existing_scratch_set(int64_t *addr);
extern int64_t dharafs_log_combined_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_companion_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_digest_a_scratch_set(int64_t *addr);
extern int64_t dharafs_verified_digest_b_scratch_set(int64_t *addr);
extern int64_t dharafs_appendonly_check_scratch_set(int64_t *addr);

static void reset_fs(void) {
    host_virtual_disk_reset();
    dharafs_state_set_block_dev(2);
    g_sd_scratch = dhruva_alloc_bytes(512);
    g_path_scratch = dhruva_alloc_bytes(32);
    g_data_scratch = dhruva_alloc_bytes(4096);
    g_stat_scratch = dhruva_alloc_bytes(12);
    g_dir_scratch = dhruva_alloc_bytes(32);
    dharafs_sd_scratch_set(g_sd_scratch);
    dharafs_path_scratch_set(g_path_scratch);
    dharafs_data_scratch_set(g_data_scratch);
    dharafs_stat_scratch_set(g_stat_scratch);
    dharafs_dir_scratch_set(g_dir_scratch);
    dharafs_log_path_scratch_set(dhruva_alloc_bytes(32));
    dharafs_log_header_path_scratch_set(dhruva_alloc_bytes(32));
    dharafs_log_header_data_scratch_set(dhruva_alloc_bytes(8));
    dharafs_log_existing_scratch_set(dhruva_alloc_bytes(4096));
    dharafs_log_combined_scratch_set(dhruva_alloc_bytes(4096));
    dharafs_verified_companion_scratch_set(dhruva_alloc_bytes(32));
    dharafs_verified_digest_a_scratch_set(dhruva_alloc_bytes(32));
    dharafs_verified_digest_b_scratch_set(dhruva_alloc_bytes(32));
    dharafs_appendonly_check_scratch_set(dhruva_alloc_bytes(4096));
    fn_dharafs_init();
}

static int64_t *mkbuf(const char *bytes, int64_t len) {
    int64_t *b = dhruva_alloc_bytes(len);
    for (int64_t i = 0; i < len; i++) {
        buf_write_byte(b, (uint32_t)i, (uint32_t)(unsigned char)bytes[i]);
    }
    return b;
}

/* ================= DharaFS: basic round trip ================= */

static void test_basic_round_trip(void) {
    reset_fs();
    int64_t *path = mkbuf("/a", 2);
    int64_t *data = mkbuf("hello", 5);
    int64_t st = fn_dharafs_append_raw(path, 2, data, 5, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "basic_round_trip: append succeeds");

    int64_t *out = dhruva_alloc_bytes(5);
    int64_t rd = fn_dharafs_read_raw(path, 2, out);
    CHECK(rd == 5, "basic_round_trip: read returns correct length");
    CHECK(memcmp(out, "hello", 5) == 0, "basic_round_trip: read returns correct bytes");
}

/* ================= Path length boundary: 32 ok, 33 rejected ================= */

static void test_path_length_boundary(void) {
    reset_fs();
    char path32[32];
    memset(path32, 'p', 32);
    int64_t *pbuf = mkbuf(path32, 32);
    int64_t *data = mkbuf("x", 1);
    int64_t st = fn_dharafs_append_raw(pbuf, 32, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "path_length: exactly 32 bytes accepted");

    char path33[33];
    memset(path33, 'q', 33);
    int64_t *pbuf2 = mkbuf(path33, 33);
    int64_t st2 = fn_dharafs_append_raw(pbuf2, 33, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st2 == 1, "path_length: 33 bytes rejected");

    int64_t st3 = fn_dharafs_append_raw(pbuf, 0, data, 1, 0, 0, fn_dharafs_default_mode());
    CHECK(st3 == 1, "path_length: zero-length path rejected (continuation sentinel)");
}

/* ================= File size boundary: 4096 ok, 4097 rejected ================= */

static void test_file_size_boundary(void) {
    reset_fs();
    int64_t *path = mkbuf("/big", 4);
    int64_t max_len = fn_dharafs_file_max_len();
    CHECK(max_len == 4096, "file_size: dharafs_file_max_len() is 4096");

    int64_t *data4096 = dhruva_alloc_bytes(4096);
    for (int64_t i = 0; i < 4096; i++) buf_write_byte(data4096, (uint32_t)i, (uint32_t)(i & 0xff));
    int64_t st = fn_dharafs_append_raw(path, 4, data4096, 4096, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "file_size: exactly 4096 bytes accepted");

    int64_t *out = dhruva_alloc_bytes(4096);
    int64_t rd = fn_dharafs_read_raw(path, 4, out);
    CHECK(rd == 4096, "file_size: 4096-byte multi-block file reads back correct length");
    CHECK(memcmp(out, data4096, 4096) == 0, "file_size: 4096-byte multi-block file reads back correct bytes");

    int64_t *data4097 = dhruva_alloc_bytes(4097);
    int64_t st2 = fn_dharafs_append_raw(path, 4, data4097, 4097, 0, 0, fn_dharafs_default_mode());
    CHECK(st2 == 1, "file_size: 4097 bytes rejected");
}

/* ================= Zero-length data ================= */

static void test_zero_length_data(void) {
    reset_fs();
    int64_t *path = mkbuf("/empty", 6);
    int64_t *data = dhruva_alloc_bytes(1); /* never read since data_len==0 */
    int64_t st = fn_dharafs_append_raw(path, 6, data, 0, 0, 0, fn_dharafs_default_mode());
    CHECK(st == 0, "zero_length_data: append with data_len=0 succeeds");

    int64_t *out = dhruva_alloc_bytes(1);
    int64_t rd = fn_dharafs_read_raw(path, 6, out);
    CHECK(rd == 0, "zero_length_data: read back returns length 0");
}

/* ================= Overwrite: newest record wins ================= */

static void test_overwrite(void) {
    reset_fs();
    int64_t *path = mkbuf("/f", 2);
    int64_t *data1 = mkbuf("version-one", 11);
    int64_t *data2 = mkbuf("version-two-updated", 19);
    CHECK(fn_dharafs_append_raw(path, 2, data1, 11, 0, 0, fn_dharafs_default_mode()) == 0, "overwrite: first write succeeds");
    CHECK(fn_dharafs_append_raw(path, 2, data2, 19, 0, 0, fn_dharafs_default_mode()) == 0, "overwrite: second write succeeds");

    int64_t *out = dhruva_alloc_bytes(19);
    int64_t rd = fn_dharafs_read_raw(path, 2, out);
    CHECK(rd == 19, "overwrite: read returns NEWEST length");
    CHECK(memcmp(out, "version-two-updated", 19) == 0, "overwrite: read returns NEWEST bytes");
}

/* ================= Delete -> tombstone -> read fails ================= */

static void test_delete(void) {
    reset_fs();
    int64_t *path = mkbuf("/gone", 5);
    int64_t *data = mkbuf("x", 1);
    CHECK(fn_dharafs_append_raw(path, 5, data, 1, 0, 0, fn_dharafs_default_mode()) == 0, "delete: append succeeds");
    CHECK(fn_dharafs_delete_raw(path, 5) == 0, "delete: delete succeeds");

    int64_t *out = dhruva_alloc_bytes(1);
    int64_t rd = fn_dharafs_read_raw(path, 5, out);
    CHECK(rd == -1, "delete: read after delete returns -1 (tombstone)");

    int64_t blk = fn_dharafs_find_latest_block_raw(path, 5);
    CHECK(blk >= 0, "delete: tombstone record itself is still findable as the latest block");
}

/* ================= Rename (round 47) ================= */

static void test_rename(void) {
    reset_fs();
    int64_t *old_path = mkbuf("/a", 2);
    int64_t *new_path = mkbuf("/b", 2);
    int64_t *data = mkbuf("hello-world", 11);
    CHECK(fn_dharafs_append_raw(old_path, 2, data, 11, 7, 8, 0644) == 0, "rename: create /a succeeds");
    CHECK(fn_dharafs_rename_raw(old_path, 2, new_path, 2) == 0, "rename: /a -> /b succeeds");

    int64_t *out = dhruva_alloc_bytes(11);
    CHECK(fn_dharafs_read_raw(old_path, 2, out) == -1, "rename: old path no longer readable");
    int64_t rd = fn_dharafs_read_raw(new_path, 2, out);
    CHECK(rd == 11, "rename: new path readable with correct length");
    CHECK(memcmp(out, "hello-world", 11) == 0, "rename: new path has correct bytes");

    int64_t *meta = dhruva_alloc_bytes(12);
    CHECK(fn_dharafs_stat_raw(new_path, 2, meta) == 0, "rename: new path stat succeeds");
    CHECK(buf_read_u32(meta, 0) == 7, "rename: owner_uid preserved across rename");
    CHECK(buf_read_u32(meta, 4) == 8, "rename: owner_gid preserved across rename");

    /* Rename to self is a no-op success, not a self-tombstone. */
    CHECK(fn_dharafs_rename_raw(new_path, 2, new_path, 2) == 0, "rename: /b -> /b (self) succeeds");
    CHECK(fn_dharafs_read_raw(new_path, 2, out) == 11, "rename: self-rename did not delete the file");

    /* Renaming a path that doesn't exist fails cleanly. */
    int64_t *missing = mkbuf("/nope", 5);
    int64_t *dest = mkbuf("/dest", 5);
    CHECK(fn_dharafs_rename_raw(missing, 5, dest, 5) == -1, "rename: nonexistent source returns -1");

    /* Path length boundaries, same 32-byte limit as every other entry point. */
    char path33[33];
    memset(path33, 'z', 33);
    int64_t *huge = mkbuf(path33, 33);
    CHECK(fn_dharafs_rename_raw(new_path, 2, huge, 33) == 1, "rename: new path > 32 bytes rejected");
    CHECK(fn_dharafs_rename_raw(huge, 33, new_path, 2) == 1, "rename: old path > 32 bytes rejected");

    /* Permission model: owner may rename; a non-owner may not, even
     * onto a path that doesn't exist yet (write permission is checked
     * on the OLD path, which is what's actually being removed). */
    reset_fs();
    int64_t *owned = mkbuf("/owned", 6);
    int64_t *stolen = mkbuf("/stolen", 7);
    int64_t *d2 = mkbuf("secret", 6);
    CHECK(fn_dharafs_append_raw(owned, 6, d2, 6, 42, 42, 0644) == 0, "rename_perm: create /owned as uid 42");
    CHECK(fn_dharafs_rename_raw_checked(owned, 6, stolen, 7, 99, 99) == -2, "rename_perm: non-owner rename denied");
    CHECK(fn_dharafs_rename_raw_checked(owned, 6, stolen, 7, 42, 42) == 0, "rename_perm: owner rename succeeds");

    /* Renaming onto an EXISTING file owned by someone else, without
     * permission on that destination, must also be denied -- renaming
     * shouldn't be a backdoor around dharafs_write_raw_checked's own
     * overwrite-permission check. */
    reset_fs();
    int64_t *mine = mkbuf("/mine", 5);
    int64_t *theirs = mkbuf("/theirs", 7);
    int64_t *d3 = mkbuf("m", 1);
    int64_t *d4 = mkbuf("t", 1);
    CHECK(fn_dharafs_append_raw(mine, 5, d3, 1, 42, 42, 0644) == 0, "rename_dest_perm: create /mine as uid 42");
    CHECK(fn_dharafs_append_raw(theirs, 7, d4, 1, 7, 7, 0644) == 0, "rename_dest_perm: create /theirs as uid 7 (world-readable, not world-writable)");
    CHECK(fn_dharafs_rename_raw_checked(mine, 5, theirs, 7, 42, 42) == -2, "rename_dest_perm: renaming onto someone else's file without write permission on it is denied");
}

/* ================= Permission model boundaries ================= */

static void test_permission_boundaries(void) {
    /* mode 0644: owner rw, group r, other r. */
    uint32_t mode = 0x1A4;
    /* Owner (uid match): read allowed, write allowed. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 100, 999, 1, 0, 0) == 1, "perm: owner can read");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 100, 999, 0, 1, 0) == 1, "perm: owner can write");
    /* Group (gid match, uid mismatch): read allowed, write denied. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 200, 1, 0, 0) == 1, "perm: group can read");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 200, 0, 1, 0) == 0, "perm: group cannot write (mode 0644)");
    /* Other (neither match): read allowed, write denied. */
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 999, 1, 0, 0) == 1, "perm: other can read (mode 0644)");
    CHECK(fn_dharafs_check_permission(100, 200, mode, 999, 999, 0, 1, 0) == 0, "perm: other cannot write");
    /* Root (uid 0) always bypasses, even against mode 0. */
    CHECK(fn_dharafs_check_permission(100, 200, 0, 0, 999, 0, 1, 0) == 1, "perm: root bypasses even mode 0");
    /* mode 0 (rwx for nobody): owner itself is denied too. */
    CHECK(fn_dharafs_check_permission(100, 200, 0, 100, 200, 1, 0, 0) == 0, "perm: mode 0 denies even the owner");

    /* End-to-end through the checked wrappers. */
    reset_fs();
    int64_t *path = mkbuf("/secret", 7);
    int64_t *data = mkbuf("s", 1);
    CHECK(fn_dharafs_write_raw_checked(path, 7, data, 1, 42, 42) == 0, "perm_e2e: uid 42 creates /secret (mode defaults to 0644)");
    int64_t *out = dhruva_alloc_bytes(1);
    CHECK(fn_dharafs_read_raw_checked(path, 7, out, 999, 999) == 1, "perm_e2e: any uid can read (mode 0644 world-readable)");
    int64_t *data2 = mkbuf("t", 1);
    CHECK(fn_dharafs_write_raw_checked(path, 7, data2, 1, 999, 999) == -2, "perm_e2e: non-owner write denied (-2)");
    CHECK(fn_dharafs_delete_raw_checked(path, 7, 999, 999) == -2, "perm_e2e: non-owner delete denied (-2)");
    CHECK(fn_dharafs_delete_raw_checked(path, 7, 42, 42) == 0, "perm_e2e: owner delete succeeds");
    CHECK(fn_dharafs_read_raw_checked(path, 7, out, 42, 42) == -1, "perm_e2e: read after owner-delete returns -1 (not found)");

    int64_t *missing = mkbuf("/nope", 5);
    CHECK(fn_dharafs_read_raw_checked(missing, 5, out, 999, 999) == -1, "perm_e2e: read of never-written path returns -1, not -2");
}

/* ================= Directory hierarchy classify mode ================= */

static void test_directory_hierarchy(void) {
    reset_fs();
    CHECK(fn_dharafs_append("/config/mode", "auto") == 0, "dirhier: create /config/mode");
    CHECK(fn_dharafs_append("/config/sub/deep", "x") == 0, "dirhier: create /config/sub/deep");
    CHECK(fn_dharafs_append("/config/other", "y") == 0, "dirhier: create /config/other");

    int64_t *dir = mkbuf("/config", 7);
    int64_t *q_mode = mkbuf("mode", 4);
    int64_t r1 = fn_dharafs_list_dir_raw(dir, 7, q_mode, 4);
    CHECK(r1 == 1, "dirhier: classify('mode') under /config is a FILE (1)");

    int64_t *q_sub = mkbuf("sub", 3);
    int64_t r2 = fn_dharafs_list_dir_raw(dir, 7, q_sub, 3);
    CHECK(r2 == 2, "dirhier: classify('sub') under /config is a SUBDIRECTORY (2)");

    int64_t *q_missing = mkbuf("nope", 4);
    int64_t r3 = fn_dharafs_list_dir_raw(dir, 7, q_missing, 4);
    CHECK(r3 == 0, "dirhier: classify('nope') under /config is NEITHER (0)");
}

/* ================= dirlist_seen_contains / segment_equals unit tests ================= */

static void test_dirlist_helpers(void) {
    int64_t *seen = dhruva_alloc_bytes(128 * 32);
    buf_write_byte(seen, 0, 3);
    buf_write_byte(seen, 1, 'f'); buf_write_byte(seen, 2, 'o'); buf_write_byte(seen, 3, 'o');

    int64_t *path = mkbuf("xxfooyy", 7);
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 1, path, 2, 3) == 1, "dirlist_helpers: seen_contains finds exact match");
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 1, path, 0, 2) == 0, "dirlist_helpers: seen_contains rejects different segment");
    CHECK(fn_dharafs_dirlist_seen_contains(seen, 0, path, 2, 3) == 0, "dirlist_helpers: seen_contains with count=0 always false");

    int64_t *query = mkbuf("foo", 3);
    CHECK(fn_dharafs_dirlist_segment_equals(query, 3, path, 2, 3) == 1, "dirlist_helpers: segment_equals matches");
    CHECK(fn_dharafs_dirlist_segment_equals(query, 3, path, 0, 2) == 0, "dirlist_helpers: segment_equals length mismatch rejects");
}

/* ================= Malformed on-disk records ================= */

/* Writes a fully-formed 512-byte record straight to the virtual disk,
 * bypassing dharafs_append_raw entirely -- lets us construct records
 * no real append path would ever produce, to test recovery/read
 * against genuinely corrupted or adversarial disk contents. */
static void write_raw_record(int64_t block, uint32_t seq, const char *path, int64_t path_len,
                              uint32_t data_len_field, uint32_t next_block_field,
                              const char *data, int64_t data_len, int corrupt_checksum) {
    int64_t *b = dhruva_alloc_bytes(512);
    buf_write_u32(b, 4, seq);
    buf_write_u32(b, 8, (uint32_t)path_len);
    for (int64_t i = 0; i < path_len; i++) buf_write_byte(b, (uint32_t)(12 + i), (uint32_t)(unsigned char)path[i]);
    buf_write_u32(b, 44, data_len_field);
    buf_write_u32(b, 48, next_block_field);
    for (int64_t i = 0; i < data_len; i++) buf_write_byte(b, (uint32_t)(64 + i), (uint32_t)(unsigned char)data[i]);
    uint32_t csum = buf_checksum(b, 4, 508);
    if (corrupt_checksum) csum ^= 0xdeadbeef;
    buf_write_u32(b, 0, csum);
    host_virtual_disk_write(block, b);
}

static void test_corrupted_checksum_skipped(void) {
    reset_fs();
    /* Block 1 with a deliberately WRONG checksum -- recovery/find_latest
     * must skip it, not trust the (corrupted) length/path fields. */
    write_raw_record(1, 1, "/x", 2, 5, 0, "hello", 5, /*corrupt=*/1);
    fn_dharafs_init(); /* re-run recovery scan against the corrupted disk */
    int64_t blk = fn_dharafs_find_latest_block_raw(mkbuf("/x", 2), 2);
    CHECK(blk == -1, "corrupted_checksum: record with bad checksum is never found");
}

static void test_oversized_data_len_field_rejected(void) {
    reset_fs();
    /* A record whose on-disk data_len field claims more than
     * dharafs_file_max_len() -- dharafs_read_raw must reject this
     * outright rather than using it as a copy-loop bound (this is
     * exactly the round-2026-08-27 audit fix noted in kernel_main.
     * vani's own comment on dharafs_read_raw; re-verifying it here). */
    write_raw_record(1, 1, "/y", 2, 0xFFFFFFF0u, 0, "z", 1, /*corrupt=*/0);
    /* dharafs_state_set: next_block must be > 1 for the scan to see block 1. */
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(2, 2);
    int64_t *out = dhruva_alloc_bytes(16);
    int64_t rd = fn_dharafs_read_raw(mkbuf("/y", 2), 2, out);
    CHECK(rd == -1, "oversized_data_len: absurd on-disk data_len field is rejected, not used as a copy bound");
}

/* Runs `fn` in a child process with a wall-clock timeout, so a
 * genuine infinite loop in the code under test can be detected and
 * reported instead of hanging the whole harness forever. Returns 1 if
 * the child exited within the timeout, 0 if it had to be killed
 * (i.e. a hang was detected). */
static int run_with_timeout(void (*fn)(void), int timeout_sec) {
    pid_t pid = fork();
    if (pid == 0) {
        fn();
        _exit(0);
    }
    for (int waited = 0; waited < timeout_sec * 10; waited++) {
        int status;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) return 1;
        usleep(100 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    return 0;
}

static void do_self_referential_continuation_read(void) {
    reset_fs();
    /* HEAD record: total data_len=500 (> 448-byte cap, so this is a
     * genuine multi-block file), next_block=2. */
    write_raw_record(1, 1, "/loop", 5, 500, 2, "", 0, /*corrupt=*/0);
    /* Continuation record at block 2: path_len=0 (continuation
     * marker, required to pass dharafs_read_raw's own check) but
     * data_len(field 44)=0 -- a length no REAL append path would ever
     * write (every real continuation chunk's length is > 0), and
     * next_block points back to ITSELF. */
    write_raw_record(2, 2, "", 0, 0, 2, "", 0, /*corrupt=*/0);
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(3, 3);
    int64_t *out = dhruva_alloc_bytes(500);
    fn_dharafs_read_raw(mkbuf("/loop", 5), 5, out);
}

static void test_self_referential_continuation_chain(void) {
    int ok = run_with_timeout(do_self_referential_continuation_read, 2);
    CHECK(ok == 1,
          "self_referential_chain: dharafs_read_raw terminates on a "
          "malformed disk with a zero-length self-pointing continuation "
          "block (a chain no real append path produces, but a corrupted/"
          "adversarial disk image could) -- if this FAILS, it's a real "
          "hang/DoS bug: the read loop's `remaining` never decreases "
          "when a continuation record's own data_len field is 0, so it "
          "never reaches the loop's only exit condition");
}

/* ================= Verified (SHA-256 companion digest) I/O (round 48) ================= */

extern uint32_t dharafs_state_get_next_block(void);
extern uint32_t dharafs_state_get_next_seq(void);

static void test_verified_integrity(void) {
    reset_fs();
    int64_t *path = mkbuf("/secure", 7);
    int64_t *data = mkbuf("top-secret-config", 17);
    CHECK(fn_dharafs_write_verified_checked(path, 7, data, 17, 0, 0) == 0, "verified: writev succeeds");

    int64_t *out = dhruva_alloc_bytes(17);
    int64_t rd = fn_dharafs_read_verified_checked(path, 7, out, 0, 0);
    CHECK(rd == 17, "verified: readv returns correct length when digest matches");
    CHECK(memcmp(out, "top-secret-config", 17) == 0, "verified: readv returns correct bytes when digest matches");

    int64_t *companion = dhruva_alloc_bytes(32);
    int64_t companion_len = fn_dharafs_verified_companion_path_raw(path, 7, companion);
    CHECK(companion_len == 14, "verified: companion path is path + \".sha256\" (14 bytes)");
    CHECK(memcmp(companion, "/secure.sha256", 14) == 0, "verified: companion path bytes are correct");

    int64_t *out2 = dhruva_alloc_bytes(17);
    CHECK(fn_dharafs_read_raw(path, 7, out2) == 17, "verified: plain dharafs_read_raw still works on a verified file");

    /* Verification is opt-in per path: a plain (non-verified) write
     * has no companion digest, and readv on it must not error. */
    int64_t *plain_path = mkbuf("/plain", 6);
    int64_t *plain_data = mkbuf("nothing-special", 15);
    CHECK(fn_dharafs_append_raw(plain_path, 6, plain_data, 15, 0, 0, 0644) == 0, "verified: plain (non-verified) write succeeds");
    int64_t *out3 = dhruva_alloc_bytes(15);
    CHECK(fn_dharafs_read_verified_checked(plain_path, 6, out3, 0, 0) == 15, "verified: readv on a file with no companion digest just returns plain data length");

    /* Path length boundary: 25 bytes + 7-byte suffix fits exactly in
     * the 32-byte path cap; 26 does not. */
    char path25[25];
    memset(path25, 'p', 25);
    int64_t *out4 = dhruva_alloc_bytes(32);
    CHECK(fn_dharafs_verified_companion_path_raw(mkbuf(path25, 25), 25, out4) == 32, "verified: 25-byte path fits exactly a companion digest path (32 bytes)");
    char path26[26];
    memset(path26, 'q', 26);
    CHECK(fn_dharafs_verified_companion_path_raw(mkbuf(path26, 26), 26, out4) == -1, "verified: 26-byte path has no room for a companion digest");
    CHECK(fn_dharafs_write_verified_checked(mkbuf(path26, 26), 26, data, 17, 0, 0) == -1, "verified: writev on a 26-byte path is rejected (-1), not silently written without a digest");

    /* Tamper detection: directly corrupt the companion digest RECORD
     * on the virtual disk (simulating an attacker or corruption event
     * touching the digest sidecar independently of the data it
     * protects) -- readv must detect the mismatch, not trust it. */
    reset_fs();
    int64_t *path2 = mkbuf("/firmware", 9);
    int64_t *data2 = mkbuf("real-firmware-bytes", 19);
    uint32_t block_before = dharafs_state_get_next_block();
    uint32_t seq_before = dharafs_state_get_next_seq();
    CHECK(fn_dharafs_write_verified_checked(path2, 9, data2, 19, 0, 0) == 0, "tamper: writev succeeds");

    char wrong_digest[32];
    memset(wrong_digest, 0xAB, 32);
    write_raw_record(block_before + 1, seq_before + 2, "/firmware.sha256", 16, 32, 0, wrong_digest, 32, /*corrupt_checksum=*/0);
    extern uint32_t dharafs_state_set(uint32_t, uint32_t);
    dharafs_state_set(block_before + 2, seq_before + 3);

    int64_t *out5 = dhruva_alloc_bytes(19);
    int64_t rd2 = fn_dharafs_read_verified_checked(path2, 9, out5, 0, 0);
    CHECK(rd2 == -3, "tamper: readv detects a companion digest that doesn't match the data");
}

/* ================= Append-only log API (round 49) ================= */

static void test_log_append(void) {
    reset_fs();

    int64_t *name = mkbuf("sensor", 6);
    int64_t *log_path = dhruva_alloc_bytes(32);
    int64_t log_path_len = fn_dharafs_log_path_raw(name, 6, 1, log_path);
    CHECK(log_path_len == 21, "log: path for index 1 is 21 bytes");
    CHECK(memcmp(log_path, "/logs/sensor-0001.log", 21) == 0, "log: path bytes are correct (zero-padded 4-digit index)");

    int64_t *header_path = dhruva_alloc_bytes(32);
    int64_t header_path_len = fn_dharafs_log_header_path_raw(name, 6, header_path);
    CHECK(header_path_len == 16, "log: header path is 16 bytes");
    CHECK(memcmp(header_path, "/logs/sensor.hdr", 16) == 0, "log: header path bytes are correct");

    /* First-ever append to a brand-new log name always rolls over to
     * index 1, regardless of size. */
    char record[400];
    memset(record, 'x', 400);
    int64_t *record_buf = mkbuf(record, 400);
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: first append succeeds (rolls over to index 1)");

    int64_t *out = dhruva_alloc_bytes(4096);
    int64_t rd = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd == 400, "log: file 1 has exactly the first record's bytes");
    CHECK(memcmp(out, record, 400) == 0, "log: file 1 content matches the record written");

    /* 7 more 400-byte appends (total 8 records, 3200 bytes) stay
     * within the rollover threshold (3584) and accumulate into the
     * SAME file. */
    for (int k = 0; k < 7; k++) {
        CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: accumulating append succeeds");
    }
    int64_t rd2 = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd2 == 3200, "log: file 1 accumulated to 8 * 400 = 3200 bytes, no rollover yet");

    /* The 9th append (3200 + 400 = 3600 > 3584) must roll over to a
     * NEW file, index 2, containing ONLY the new record -- file 1
     * stays at 3200 bytes, untouched. */
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 400, 0, 0, 0644) == 0, "log: 9th append succeeds (triggers rollover)");
    int64_t *log_path2 = dhruva_alloc_bytes(32);
    int64_t log_path2_len = fn_dharafs_log_path_raw(name, 6, 2, log_path2);
    int64_t rd3 = fn_dharafs_read_raw(log_path2, log_path2_len, out);
    CHECK(rd3 == 400, "log: file 2 (post-rollover) has exactly the 9th record's bytes");
    int64_t rd4 = fn_dharafs_read_raw(log_path, log_path_len, out);
    CHECK(rd4 == 3200, "log: file 1 is UNCHANGED after rollover (still 3200 bytes)");

    /* Header tracks the CURRENT file correctly after rollover. */
    int64_t *hdr_out = dhruva_alloc_bytes(8);
    int64_t hdr_rd = fn_dharafs_read_raw(header_path, header_path_len, hdr_out);
    CHECK(hdr_rd == 8, "log: header file is exactly 8 bytes");
    CHECK(buf_read_u32(hdr_out, 0) == 2, "log: header's current_index is 2 after rollover");
    CHECK(buf_read_u32(hdr_out, 4) == 400, "log: header's current_size is 400 (just the new file's content)");

    /* A record over the 512-byte per-record cap is rejected. */
    char big_record[513];
    memset(big_record, 'y', 513);
    int64_t *big_record_buf = mkbuf(big_record, 513);
    CHECK(fn_dharafs_log_append_raw(name, 6, big_record_buf, 513, 0, 0, 0644) == 1, "log: record over 512 bytes is rejected");
    CHECK(fn_dharafs_log_record_max_len() == 512, "log: record_max_len() is 512");
    CHECK(fn_dharafs_log_rollover_threshold() == 3584, "log: rollover_threshold() is 3584");

    /* A log name long enough that "/logs/" + name + ".hdr" fits (<=32)
     * but "/logs/" + name + "-0001.log" does NOT (> 32) is rejected
     * with -1, not a half-written, inconsistent state. */
    char long_name[20];
    memset(long_name, 'n', 20);
    int64_t *long_name_buf = mkbuf(long_name, 20);
    int64_t status = fn_dharafs_log_append_raw(long_name_buf, 20, record_buf, 400, 0, 0, 0644);
    CHECK(status == -1, "log: name too long for the log file path (though short enough for the header path) is rejected");

    /* Empty name / empty record rejected. */
    CHECK(fn_dharafs_log_append_raw(name, 0, record_buf, 400, 0, 0, 0644) == 1, "log: empty name rejected");
    CHECK(fn_dharafs_log_append_raw(name, 6, record_buf, 0, 0, 0, 0644) == 1, "log: empty record rejected");
}

/* ================= File attributes (round 50) ================= */

static void test_attributes(void) {
    reset_fs();

    /* Basic set/get round trip, owner setting immutable on their own file. */
    int64_t *path = mkbuf("/firmware.bin", 13);
    int64_t *data = mkbuf("v1", 2);
    CHECK(fn_dharafs_append_raw(path, 13, data, 2, 42, 42, 0644) == 0, "attr: create /firmware.bin as uid 42");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == 0, "attr: new file has no attributes set");
    uint32_t immutable = fn_dharafs_attr_immutable();
    CHECK(fn_dharafs_set_attr_raw(path, 13, immutable, 42, 42) == 0, "attr: owner sets immutable");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == (int64_t)immutable, "attr: get_attr reflects the immutable bit");

    /* Immutable blocks write, delete, and being a rename source or destination. */
    int64_t *data2 = mkbuf("v2", 2);
    CHECK(fn_dharafs_write_raw_checked(path, 13, data2, 2, 42, 42) == -4, "attr: write to immutable file is blocked (-4)");
    CHECK(fn_dharafs_delete_raw_checked(path, 13, 42, 42) == -4, "attr: delete of immutable file is blocked (-4)");
    int64_t *dest = mkbuf("/renamed.bin", 12);
    CHECK(fn_dharafs_rename_raw_checked(path, 13, dest, 12, 42, 42) == -4, "attr: renaming an immutable file (as source) is blocked (-4)");
    int64_t *other = mkbuf("/other.bin", 10);
    int64_t *odata = mkbuf("o", 1);
    CHECK(fn_dharafs_append_raw(other, 10, odata, 1, 42, 42, 0644) == 0, "attr: create /other.bin");
    CHECK(fn_dharafs_rename_raw_checked(other, 10, path, 13, 42, 42) == -4, "attr: renaming ONTO an immutable file (as destination) is blocked (-4)");

    /* A non-root owner cannot clear immutable once set; root can. */
    CHECK(fn_dharafs_set_attr_raw(path, 13, 0, 42, 42) == -2, "attr: non-root owner cannot clear immutable (-2)");
    CHECK(fn_dharafs_set_attr_raw(path, 13, 0, 0, 0) == 0, "attr: root CAN clear immutable");
    CHECK(fn_dharafs_get_attr_raw(path, 13) == 0, "attr: immutable is actually cleared after root's change");
    /* Now that it's cleared, normal operations work again. */
    CHECK(fn_dharafs_write_raw_checked(path, 13, data2, 2, 42, 42) == 0, "attr: write succeeds again once immutable is cleared");

    /* A non-owner, non-root caller cannot set attributes at all. */
    CHECK(fn_dharafs_set_attr_raw(path, 13, immutable, 99, 99) == -2, "attr: non-owner cannot set attributes (-2)");

    /* Append-only: valid extensions succeed, anything else is blocked. */
    reset_fs();
    int64_t *apath = mkbuf("/audit.log", 10);
    int64_t *a1 = mkbuf("event1;", 7);
    CHECK(fn_dharafs_append_raw(apath, 10, a1, 7, 7, 7, 0644) == 0, "attr_append: create /audit.log");
    uint32_t append_only = fn_dharafs_attr_append_only();
    CHECK(fn_dharafs_set_attr_raw(apath, 10, append_only, 7, 7) == 0, "attr_append: owner sets append-only");

    int64_t *a2 = mkbuf("event1;event2;", 14);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, a2, 14, 7, 7) == 0, "attr_append: valid extension (old content as exact prefix) succeeds");
    int64_t *out = dhruva_alloc_bytes(14);
    CHECK(fn_dharafs_read_raw(apath, 10, out) == 14, "attr_append: content actually extended");
    CHECK(memcmp(out, "event1;event2;", 14) == 0, "attr_append: extended content is correct");

    int64_t *bad_not_prefix = mkbuf("totally-different", 17);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_not_prefix, 17, 7, 7) == -4, "attr_append: a write that doesn't start with the old content is blocked (-4)");
    int64_t *bad_shorter = mkbuf("event1", 6);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_shorter, 6, 7, 7) == -4, "attr_append: a SHORTER write (truncation) is blocked (-4)");
    int64_t *bad_same = mkbuf("event1;event2;", 14);
    CHECK(fn_dharafs_write_raw_checked(apath, 10, bad_same, 14, 7, 7) == 0, "attr_append: re-writing the exact same content is a valid (zero-length) extension");

    /* Append-only also blocks delete, but NOT rename (real chattr +a semantics). */
    CHECK(fn_dharafs_delete_raw_checked(apath, 10, 7, 7) == -4, "attr_append: delete of append-only file is blocked (-4)");
    int64_t *arenamed = mkbuf("/audit-renamed.log", 18);
    CHECK(fn_dharafs_rename_raw_checked(apath, 10, arenamed, 18, 7, 7) == 0, "attr_append: rename of an append-only file (as source) DOES succeed");
    int64_t *out2 = dhruva_alloc_bytes(14);
    CHECK(fn_dharafs_read_raw(arenamed, 18, out2) == 14, "attr_append: content survives the rename intact");

    /* Direct unit tests of the pure prefix-check helper. */
    int64_t *old_c = mkbuf("abc", 3);
    int64_t *new_c1 = mkbuf("abcdef", 6);
    int64_t *new_c2 = mkbuf("abd", 3);
    int64_t *new_c3 = mkbuf("ab", 2);
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c1, 6) == 1, "append_only_helper: real extension is valid");
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c2, 3) == 0, "append_only_helper: same-length but different content is invalid");
    CHECK(fn_dharafs_is_valid_append_only_write(old_c, 3, new_c3, 2) == 0, "append_only_helper: shorter content is invalid");

    /* System attribute: settable/queryable, no enforcement of its own. */
    reset_fs();
    int64_t *spath = mkbuf("/marker", 7);
    int64_t *sdata = mkbuf("s", 1);
    CHECK(fn_dharafs_append_raw(spath, 7, sdata, 1, 3, 3, 0644) == 0, "attr_system: create /marker");
    uint32_t system_attr = fn_dharafs_attr_system();
    CHECK(fn_dharafs_set_attr_raw(spath, 7, system_attr, 3, 3) == 0, "attr_system: owner sets system attribute");
    CHECK(fn_dharafs_get_attr_raw(spath, 7) == (int64_t)system_attr, "attr_system: get_attr reflects it");
    int64_t *sdata2 = mkbuf("t", 1);
    CHECK(fn_dharafs_write_raw_checked(spath, 7, sdata2, 1, 3, 3) == 0, "attr_system: write still works (no enforcement for this attribute)");
    CHECK(fn_dharafs_delete_raw_checked(spath, 7, 3, 3) == 0, "attr_system: delete still works (no enforcement for this attribute)");
    /* Non-root CAN clear system (only immutable/append-only are protected from clearing). */
    reset_fs();
    int64_t *spath2 = mkbuf("/marker2", 8);
    CHECK(fn_dharafs_append_raw(spath2, 8, sdata, 1, 5, 5, 0644) == 0, "attr_system2: create /marker2");
    CHECK(fn_dharafs_set_attr_raw(spath2, 8, system_attr, 5, 5) == 0, "attr_system2: owner sets system");
    CHECK(fn_dharafs_set_attr_raw(spath2, 8, 0, 5, 5) == 0, "attr_system2: non-root owner CAN clear system");
}

/* ================= Crypto / bignum smoke tests through the real
 * on-disk-adjacent entry points (byte-for-byte correctness matters
 * here just as much as for DharaFS, since these back the security-
 * hardening roadmap's planned encrypted-storage work). ================= */

static void test_sha256_boundaries(void) {
    /* FIPS 180-4 empty-string vector. */
    int64_t *msg0 = dhruva_alloc_bytes(1);
    int64_t *out0 = dhruva_alloc_bytes(32);
    fn_sha256_hash(msg0, 0, out0);
    static const unsigned char expect_empty[32] = {
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8,
        0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55};
    int64_t *exp0 = mkbuf((const char *)expect_empty, 32);
    CHECK(fn_sha256_bytes_equal(out0, exp0, 32) == 1, "sha256: empty-string vector matches FIPS 180-4");

    /* Message length exactly at the 55/56/64-byte padding boundaries. */
    for (int64_t len = 54; len <= 65; len++) {
        int64_t *msg = dhruva_alloc_bytes(len > 0 ? len : 1);
        for (int64_t i = 0; i < len; i++) buf_write_byte(msg, (uint32_t)i, (uint32_t)('a' + (i % 26)));
        int64_t *out = dhruva_alloc_bytes(32);
        int64_t st = fn_sha256_hash(msg, len, out);
        char desc[80];
        snprintf(desc, sizeof(desc), "sha256: len=%lld does not crash/corrupt (padding boundary)", (long long)len);
        CHECK(st == 0, desc);
    }
}

static void test_chacha20_boundaries(void) {
    int64_t *key = dhruva_alloc_bytes(32);
    int64_t *nonce = dhruva_alloc_bytes(12);
    int64_t *state_buf = dhruva_alloc_bytes(64);
    int64_t *working_buf = dhruva_alloc_bytes(64);
    int64_t *keystream_buf = dhruva_alloc_bytes(64);

    /* Zero-length message: must not touch keystream/out at all. */
    int64_t *in0 = dhruva_alloc_bytes(1);
    int64_t *out0 = dhruva_alloc_bytes(1);
    int64_t st0 = fn_chacha20_encrypt(key, nonce, 0, in0, 0, state_buf, working_buf, keystream_buf, out0);
    CHECK(st0 == 0, "chacha20: zero-length message handled cleanly");

    /* Exact block boundary (64 bytes) and one-past (65 bytes). */
    for (int64_t len = 63; len <= 65; len++) {
        int64_t *in = dhruva_alloc_bytes(len);
        int64_t *out = dhruva_alloc_bytes(len);
        for (int64_t i = 0; i < len; i++) buf_write_byte(in, (uint32_t)i, (uint32_t)(i & 0xff));
        int64_t st = fn_chacha20_encrypt(key, nonce, 0, in, len, state_buf, working_buf, keystream_buf, out);
        char desc[96];
        snprintf(desc, sizeof(desc), "chacha20: len=%lld encrypts without corruption at block boundary", (long long)len);
        CHECK(st == 0, desc);
        /* Round trip: decrypting the ciphertext with the same
         * keystream must recover the original plaintext exactly
         * (ChaCha20 is XOR-based, so encrypt == decrypt). */
        int64_t *roundtrip = dhruva_alloc_bytes(len);
        fn_chacha20_encrypt(key, nonce, 0, out, len, state_buf, working_buf, keystream_buf, roundtrip);
        char desc2[96];
        snprintf(desc2, sizeof(desc2), "chacha20: len=%lld round-trips back to plaintext", (long long)len);
        CHECK(memcmp(in, roundtrip, (size_t)len) == 0, desc2);
    }
}

static void test_bignum_boundaries(void) {
    /* Multiply by zero. */
    int64_t *a = dhruva_alloc_bytes(16);
    int64_t *zero = dhruva_alloc_bytes(16);
    int64_t *prod = dhruva_alloc_bytes(32);
    fn_bignum_set_limbs4(a, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff);
    fn_bignum_set_limbs4(zero, 0, 0, 0, 0);
    fn_bignum_mul_raw(a, zero, prod, 4);
    int64_t *expect_zero8 = dhruva_alloc_bytes(32);
    CHECK(fn_bignum_limbs_equal(prod, expect_zero8, 8) == 1, "bignum: max_value * 0 == 0 (8 limbs)");

    /* Borrow-on-subtract: 0 - 1 must wrap to all-0xff and report a borrow. */
    int64_t *one = dhruva_alloc_bytes(16);
    fn_bignum_set_limbs4(one, 1, 0, 0, 0);
    int64_t *diff = dhruva_alloc_bytes(16);
    uint32_t borrow = fn_bignum_sub_raw(zero, one, diff, 4);
    CHECK(borrow == 1, "bignum: 0 - 1 reports a borrow");
    int64_t *expect_allff = dhruva_alloc_bytes(16);
    fn_bignum_set_limbs4(expect_allff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff);
    CHECK(fn_bignum_limbs_equal(diff, expect_allff, 4) == 1, "bignum: 0 - 1 wraps to 0xff...ff");

    /* Carry-on-add: max_value + 1 must wrap to 0 and report a carry. */
    int64_t *sum = dhruva_alloc_bytes(16);
    uint32_t carry = fn_bignum_add_raw(a, one, sum, 4);
    CHECK(carry == 1, "bignum: max_value + 1 reports a carry");
    int64_t *expect_zero4 = dhruva_alloc_bytes(16);
    CHECK(fn_bignum_limbs_equal(sum, expect_zero4, 4) == 1, "bignum: max_value + 1 wraps to 0");

    /* Comparison boundary. */
    CHECK(fn_bignum_cmp_raw(a, one, 4) == 1, "bignum: max_value > 1");
    CHECK(fn_bignum_cmp_raw(one, a, 4) == -1, "bignum: 1 < max_value");
    CHECK(fn_bignum_cmp_raw(a, a, 4) == 0, "bignum: a == a");
}

int main(void) {
    test_basic_round_trip();
    test_path_length_boundary();
    test_file_size_boundary();
    test_zero_length_data();
    test_overwrite();
    test_delete();
    test_rename();
    test_permission_boundaries();
    test_directory_hierarchy();
    test_dirlist_helpers();
    test_corrupted_checksum_skipped();
    test_oversized_data_len_field_rejected();
    test_self_referential_continuation_chain();
    test_verified_integrity();
    test_log_append();
    test_attributes();
    test_sha256_boundaries();
    test_chacha20_boundaries();
    test_bignum_boundaries();

    printf("\n%d PASS, %d FAIL\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
