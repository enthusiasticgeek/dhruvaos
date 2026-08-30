/* Host-side stub implementations for every extern "C" fn kernel_main.
 * vani declares, so the ASAN/UBSAN test harness (host_main.c) can link
 * against kernel_gen.c (vanic's --backend=c output for the real
 * kernel_main.vani) as a plain host process.
 *
 * Two tiers, deliberately not uniform:
 *
 * 1. REAL implementations for everything the DharaFS + crypto/bignum
 *    logic host_main.c actually calls: the raw buffer accessors
 *    (buf_*, matching boot/dharafs_buf.S's exact bit-for-bit
 *    semantics), the scratch-pointer get/set pairs, dharafs_state_
 *    and dharafs_user_ accessors, and host_virtual_disk_read/write (an in-memory
 *    array standing in for a real SD card -- see kernel_main.vani's
 *    own comment on the dev==2 backend). dhruva_alloc_bytes is
 *    malloc-backed here specifically so ASAN's redzones sit at the
 *    real allocation boundary, catching any off-by-one in the vani
 *    code that computes an offset into one of these buffers.
 *
 * 2. Dummy stubs for every other extern -- networking, USB, SD FIFO,
 *    scheduler, governor, shell RX -- that kernel_gen.c's *other*
 *    top-level functions reference but host_main.c's own call graph
 *    never reaches. These exist purely to satisfy the linker (the
 *    whole file is one translation unit; every extern referenced
 *    anywhere in it needs a definition even if host_main() never
 *    calls that code path) and are never exercised.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---- 1a. Heap: dhruva_alloc_bytes / dhruva_heap_used_bytes ---- */

static int64_t g_heap_used = 0;
static int64_t g_alloc_count = 0;

int64_t *dhruva_alloc_bytes(int64_t n) {
    g_heap_used += n;
    g_alloc_count += 1;
    /* calloc, not malloc: the real allocator zeroes new memory (see
     * runtime_stubs.c's dhruva_alloc_bytes), and DharaFS code relies
     * on that for e.g. the continuation-block path-bytes region. */
    return (int64_t *)calloc((size_t)n, 1);
}

int64_t dhruva_heap_used_bytes(void) {
    return g_heap_used;
}

int64_t dhruva_alloc_count_get(void) {
    return g_alloc_count;
}

/* Round 51 fault injection: never armed by the host harness (nothing
 * here tests the real OOM-fatal halt path -- that's round 45's own
 * standalone bare-metal harness's job, see its own comment). Present
 * only so the linker resolves the symbol. */
int64_t dhruva_fault_inject_alloc_arm(int64_t after_n) {
    (void)after_n;
    return 0;
}

/* ---- 1b. Raw buffer accessors -- byte-for-byte match of
 * boot/dharafs_buf.S's ARM assembly (buf is treated as a plain byte
 * pointer, offset is a plain byte offset, no bounds checking here
 * either -- that absence is exactly what this harness's ASAN redzones
 * exist to catch if the vani-level code ever computes a bad offset). */

uint32_t buf_write_byte(int64_t *buf, uint32_t offset, uint32_t value) {
    unsigned char *p = (unsigned char *)buf;
    p[offset] = (unsigned char)value;
    return 0;
}

uint32_t buf_read_byte(int64_t *buf, uint32_t offset) {
    unsigned char *p = (unsigned char *)buf;
    return (uint32_t)p[offset];
}

uint32_t buf_write_u32(int64_t *buf, uint32_t offset, uint32_t value) {
    unsigned char *p = (unsigned char *)buf + offset;
    memcpy(p, &value, 4);
    return 0;
}

uint32_t buf_read_u32(int64_t *buf, uint32_t offset) {
    unsigned char *p = (unsigned char *)buf + offset;
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

/* Rotate-left-by-1-then-add mix, matching buf_checksum's ARM `ror
 * #31` (rotate RIGHT by 31 of a 32-bit value == rotate LEFT by 1). */
uint32_t buf_checksum(int64_t *buf, uint32_t start_offset, uint32_t byte_len) {
    unsigned char *p = (unsigned char *)buf;
    uint32_t csum = 0;
    uint32_t end = start_offset + byte_len;
    for (uint32_t i = start_offset; i < end; i++) {
        csum = ((csum << 1) | (csum >> 31)) + (uint32_t)p[i];
    }
    return csum;
}

/* ---- 1c. Scratch-pointer get/set pairs (uniform NAME_get/NAME_set
 * shape) -- generated via macro since all ~20 share the same shape. */

#define SCRATCH_PTR(NAME)                                     \
    static int64_t *NAME##_ptr = 0;                           \
    int64_t *NAME##_get(void) { return NAME##_ptr; }          \
    int64_t NAME##_set(int64_t *addr) {                       \
        NAME##_ptr = addr;                                    \
        return 0;                                             \
    }

SCRATCH_PTR(arp_resolve_mac_scratch)
SCRATCH_PTR(arp_resolve_scratch)
SCRATCH_PTR(dharafs_data_scratch)
SCRATCH_PTR(dharafs_dir_scratch)
SCRATCH_PTR(dharafs_path_scratch)
SCRATCH_PTR(dharafs_sd_scratch)
SCRATCH_PTR(dharafs_stat_scratch)
SCRATCH_PTR(dhcp_bcast_mac_scratch)
SCRATCH_PTR(dhcp_frame_scratch)
SCRATCH_PTR(dhcp_payload_scratch)
SCRATCH_PTR(dhcp_server_mac_scratch)
SCRATCH_PTR(dwc2_dma_scratch)
SCRATCH_PTR(eval_ops_scratch)
SCRATCH_PTR(eval_values_scratch)
SCRATCH_PTR(net_recv_scratch)
SCRATCH_PTR(net_send_scratch)
SCRATCH_PTR(shell_line_scratch)
SCRATCH_PTR(tcp_empty_payload_scratch)
SCRATCH_PTR(uart_digits_scratch)
SCRATCH_PTR(udp_send_arp_scratch)
SCRATCH_PTR(usb_bulk_data_scratch)
SCRATCH_PTR(dharafs_log_path_scratch)
SCRATCH_PTR(dharafs_log_header_path_scratch)
SCRATCH_PTR(dharafs_log_header_data_scratch)
SCRATCH_PTR(dharafs_log_existing_scratch)
SCRATCH_PTR(dharafs_log_combined_scratch)
SCRATCH_PTR(dharafs_verified_companion_scratch)
SCRATCH_PTR(dharafs_verified_digest_a_scratch)
SCRATCH_PTR(dharafs_verified_digest_b_scratch)
SCRATCH_PTR(dharafs_appendonly_check_scratch)
SCRATCH_PTR(dharafs_rename_new_path_scratch)

/* ---- 1d. dharafs_state_* / dharafs_user_* -- real state, matching
 * boot/dharafs_state.S's semantics closely enough for host testing
 * (a handful of plain static u32s; dev defaults to 2 so a harness
 * that forgets to call dharafs_state_set_block_dev(2) fails loudly
 * via host_virtual_disk_read's own bounds checks rather than silently
 * falling through to a real-hardware backend that doesn't exist
 * here). */

static uint32_t g_next_block = 0;
static uint32_t g_next_seq = 0;
static uint32_t g_log_start = 0;
static uint32_t g_block_dev = 2;
static uint32_t g_uid = 0;
static uint32_t g_gid = 0;

uint32_t dharafs_state_set(uint32_t next_block, uint32_t next_seq) {
    g_next_block = next_block;
    g_next_seq = next_seq;
    return 0;
}
uint32_t dharafs_state_get_next_block(void) { return g_next_block; }
uint32_t dharafs_state_get_next_seq(void) { return g_next_seq; }
uint32_t dharafs_state_set_log_start(uint32_t log_start) {
    g_log_start = log_start;
    return 0;
}
uint32_t dharafs_state_get_log_start(void) { return g_log_start; }
uint32_t dharafs_state_set_block_dev(uint32_t dev) {
    g_block_dev = dev;
    return 0;
}
uint32_t dharafs_state_get_block_dev(void) { return g_block_dev; }

uint32_t dharafs_user_set(uint32_t uid, uint32_t gid) {
    g_uid = uid;
    g_gid = gid;
    return 0;
}
uint32_t dharafs_user_get_uid(void) { return g_uid; }
uint32_t dharafs_user_get_gid(void) { return g_gid; }

static uint32_t g_commit_count = 0;
uint32_t dharafs_commit_count_increment(void) { g_commit_count += 1; return g_commit_count; }
uint32_t dharafs_commit_count_get(void) { return g_commit_count; }

/* ---- 1e. host_virtual_disk_read/write -- the in-memory "SD card"
 * dharafs_block_read/dharafs_block_write's dev==2 branch calls. Sized
 * to dharafs_init's own max_blk=2048 recovery-scan bound (kernel_main.
 * vani) so an out-of-range block_num is a genuine test bug (caught by
 * the bounds check below, which aborts loudly rather than silently
 * corrupting adjacent memory -- the harness's OWN safety net, not a
 * standin for the real kernel's; the real kernel's own MMIO-backed
 * SDHOST/USB backends have their own hardware-level range limits). */

#define HOST_DISK_BLOCKS 2048
#define HOST_DISK_BLOCK_BYTES 512
static unsigned char g_virtual_disk[HOST_DISK_BLOCKS * HOST_DISK_BLOCK_BYTES];

int64_t host_virtual_disk_read(int64_t block_num, int64_t *buf) {
    if (block_num < 0 || block_num >= HOST_DISK_BLOCKS) {
        return -1;
    }
    memcpy(buf, g_virtual_disk + (size_t)block_num * HOST_DISK_BLOCK_BYTES,
           HOST_DISK_BLOCK_BYTES);
    return 0;
}

int64_t host_virtual_disk_write(int64_t block_num, int64_t *buf) {
    if (block_num < 0 || block_num >= HOST_DISK_BLOCKS) {
        return -1;
    }
    memcpy(g_virtual_disk + (size_t)block_num * HOST_DISK_BLOCK_BYTES, buf,
           HOST_DISK_BLOCK_BYTES);
    return 0;
}

/* Test-harness-only helper (not a kernel_main.vani extern): resets the
 * virtual disk and all DharaFS state between test cases, so one
 * adversarial test's leftover blocks can't mask a bug in the next. */
void host_virtual_disk_reset(void) {
    memset(g_virtual_disk, 0, sizeof(g_virtual_disk));
    g_next_block = 0;
    g_next_seq = 0;
    g_log_start = 0;
    g_uid = 0;
    g_gid = 0;
}

/* ---- 1f. test_fill_pattern / test_compare_buffers -- faithful
 * implementations (deterministic repeating pattern; byte-for-byte
 * compare), even though host_main.c's own call graph doesn't reach
 * these (only the _self_test wrappers this harness deliberately
 * avoids call them) -- cheap to get right and avoids a silent-wrong-
 * answer trap if a future edit to host_main.c starts exercising a
 * path that does use them. */

int64_t test_fill_pattern(int64_t *buf, int64_t byte_count) {
    unsigned char *p = (unsigned char *)buf;
    for (int64_t i = 0; i < byte_count; i++) {
        p[i] = (unsigned char)(i & 0xff);
    }
    return 0;
}

int64_t test_compare_buffers(int64_t *a, int64_t *b, int64_t byte_count) {
    return memcmp(a, b, (size_t)byte_count) == 0 ? 0 : 1;
}

/* ---- 1g. ptr_to_u32 -- host-safe truncation. Never used by any code
 * path this harness exercises (it exists in kernel_main.vani for
 * MMIO/DMA address plumbing), so truncating a 64-bit host pointer is
 * fine here even though it would be lossy/wrong on a real host build
 * meant to run for real. */
uint32_t ptr_to_u32(int64_t *p) { return (uint32_t)(uintptr_t)p; }

/* ==================================================================
 * 2. Dummy stubs -- never exercised by host_main.c's call graph, only
 * present to satisfy the linker (see file header comment).
 * ================================================================== */

int64_t mem_barrier(void) { return 0; }
int64_t cpu_wfi(void) { return 0; }
int64_t enable_irqs(void) { return 0; }
int64_t dhruva_prio_lock(int64_t ceiling) { return ceiling; }
int64_t dhruva_prio_unlock(int64_t base_priority) { return base_priority; }
int64_t task_sleep_ticks(int64_t ticks) { return ticks; }
int64_t scheduler_ready_count(void) { return 0; }
uint32_t scheduler_get_tick_count(void) { return 0; }
int64_t scheduler_set_tick_count_test_only(uint32_t value) { return (int64_t)value; }

int64_t *task_a_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t *task_b_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t *task_c_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t *task_d_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t *task_e_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t *task_f_init_stack(int64_t *stack_base, int64_t stack_bytes) { return stack_base + stack_bytes; }
int64_t start_multitasking(int64_t *sp_a, int64_t *sp_b, int64_t *sp_c, int64_t *sp_d, int64_t *sp_e, int64_t *sp_f) {
    (void)sp_a; (void)sp_b; (void)sp_c; (void)sp_d; (void)sp_e; (void)sp_f;
    return 0;
}

int64_t sdhost_drain_fifo_to_buffer(int64_t *buf, int64_t word_count) { (void)buf; (void)word_count; return 0; }
int64_t sdhost_fill_fifo_from_buffer(int64_t *buf, int64_t word_count) { (void)buf; (void)word_count; return 0; }
int64_t sd_state_get_is_sdhc(void) { return 0; }
int64_t sd_state_get_rca(void) { return 0; }
int64_t sd_state_set(int64_t rca, int64_t is_sdhc) { (void)rca; (void)is_sdhc; return 0; }

static uint32_t g_arp_count = 0, g_arp_next_slot = 0;
static uint32_t g_arp_ip[16];
static int64_t *g_arp_macs_buf = 0;
uint32_t arp_cache_get_count(void) { return g_arp_count; }
uint32_t arp_cache_set_count(uint32_t count) { g_arp_count = count; return 0; }
uint32_t arp_cache_get_next_slot(void) { return g_arp_next_slot; }
uint32_t arp_cache_set_next_slot(uint32_t slot) { g_arp_next_slot = slot; return 0; }
uint32_t arp_cache_get_ip(uint32_t index) { return g_arp_ip[index % 16]; }
uint32_t arp_cache_set_ip(uint32_t index, uint32_t value) { g_arp_ip[index % 16] = value; return 0; }
int64_t *arp_cache_get_macs_buf(void) { return g_arp_macs_buf; }
uint32_t arp_cache_set_macs_buf(int64_t *buf) { g_arp_macs_buf = buf; return 0; }

static uint32_t g_dhcp_client_state, g_dhcp_leased_ip, g_dhcp_lease_start_tick;
static uint32_t g_dhcp_lease_time, g_dhcp_offered_ip, g_dhcp_server_ip, g_dhcp_xid;
uint32_t dhcp_state_get_client_state(void) { return g_dhcp_client_state; }
uint32_t dhcp_state_set_client_state(uint32_t v) { g_dhcp_client_state = v; return 0; }
uint32_t dhcp_state_get_leased_ip(void) { return g_dhcp_leased_ip; }
uint32_t dhcp_state_set_leased_ip(uint32_t v) { g_dhcp_leased_ip = v; return 0; }
uint32_t dhcp_state_get_lease_start_tick(void) { return g_dhcp_lease_start_tick; }
uint32_t dhcp_state_set_lease_start_tick(uint32_t v) { g_dhcp_lease_start_tick = v; return 0; }
uint32_t dhcp_state_get_lease_time(void) { return g_dhcp_lease_time; }
uint32_t dhcp_state_set_lease_time(uint32_t v) { g_dhcp_lease_time = v; return 0; }
uint32_t dhcp_state_get_offered_ip(void) { return g_dhcp_offered_ip; }
uint32_t dhcp_state_set_offered_ip(uint32_t v) { g_dhcp_offered_ip = v; return 0; }
uint32_t dhcp_state_get_server_ip(void) { return g_dhcp_server_ip; }
uint32_t dhcp_state_set_server_ip(uint32_t v) { g_dhcp_server_ip = v; return 0; }
uint32_t dhcp_state_get_xid(void) { return g_dhcp_xid; }
uint32_t dhcp_state_set_xid(uint32_t v) { g_dhcp_xid = v; return 0; }

static int64_t g_netif_head, g_netif_tail, g_netif_count;
static int64_t g_netif_slot_len[16];
static int64_t *g_netif_queue_buf = 0;
int64_t netif_get_head(void) { return g_netif_head; }
int64_t netif_advance_head(void) { g_netif_head++; return g_netif_head; }
int64_t netif_get_tail(void) { return g_netif_tail; }
int64_t netif_advance_tail(void) { g_netif_tail++; return g_netif_tail; }
int64_t netif_get_count(void) { return g_netif_count; }
int64_t netif_get_slot_len(int64_t slot_index) { return g_netif_slot_len[slot_index % 16]; }
int64_t netif_set_slot_len(int64_t slot_index, int64_t value) { g_netif_slot_len[slot_index % 16] = value; return 0; }
int64_t *netif_get_queue_buf(void) { return g_netif_queue_buf; }
int64_t netif_set_queue_buf(int64_t *buf) { g_netif_queue_buf = buf; return 0; }

static uint32_t g_governor_last_mhz;
static int64_t g_governor_history[4];
int64_t governor_apply_freq_mhz(int64_t mhz) { g_governor_last_mhz = (uint32_t)mhz; return 0; }
int64_t governor_get_last_applied_mhz(void) { return g_governor_last_mhz; }
int64_t governor_set_last_applied_mhz(int64_t mhz) { g_governor_last_mhz = (uint32_t)mhz; return 0; }
int64_t governor_history_push(int64_t new_sample) {
    g_governor_history[0] = g_governor_history[1];
    g_governor_history[1] = g_governor_history[2];
    g_governor_history[2] = g_governor_history[3];
    g_governor_history[3] = new_sample;
    return 0;
}
int64_t governor_history_get0(void) { return g_governor_history[0]; }
int64_t governor_history_get1(void) { return g_governor_history[1]; }
int64_t governor_history_get2(void) { return g_governor_history[2]; }
int64_t governor_history_get3(void) { return g_governor_history[3]; }
int64_t governor_history_reset(void) {
    g_governor_history[0] = g_governor_history[1] = g_governor_history[2] = g_governor_history[3] = 0;
    return 0;
}

static uint32_t g_shell_line_len = 0, g_shell_line_ready = 0;
static unsigned char g_shell_line[256];
uint32_t shell_rx_push_char(uint32_t c) {
    if (g_shell_line_len < sizeof(g_shell_line)) {
        g_shell_line[g_shell_line_len++] = (unsigned char)c;
    }
    return 0;
}
uint32_t shell_get_line_len(void) { return g_shell_line_len; }
uint32_t shell_get_line_byte(uint32_t offset) { return offset < g_shell_line_len ? g_shell_line[offset] : 0; }
uint32_t shell_get_line_ready(void) { return g_shell_line_ready; }
uint32_t shell_clear_line(void) { g_shell_line_len = 0; g_shell_line_ready = 0; return 0; }

#define MAX_HOST_TCP_CONN 8
static uint32_t g_tcp_local_ip[MAX_HOST_TCP_CONN], g_tcp_local_port[MAX_HOST_TCP_CONN];
static uint32_t g_tcp_local_seq[MAX_HOST_TCP_CONN], g_tcp_remote_ip[MAX_HOST_TCP_CONN];
static uint32_t g_tcp_remote_port[MAX_HOST_TCP_CONN], g_tcp_remote_seq[MAX_HOST_TCP_CONN];
static uint32_t g_tcp_state[MAX_HOST_TCP_CONN], g_tcp_rtx_count[MAX_HOST_TCP_CONN];
static uint32_t g_tcp_rtx_deadline[MAX_HOST_TCP_CONN], g_tcp_rtx_len[MAX_HOST_TCP_CONN];
static uint32_t g_tcp_rtx_seq[MAX_HOST_TCP_CONN];
static int64_t g_tcp_rtx_buf[MAX_HOST_TCP_CONN][256];

#define TCP_GETSET(FIELD) \
    uint32_t tcp_conn_get_##FIELD(uint32_t conn_id) { return g_tcp_##FIELD[conn_id % MAX_HOST_TCP_CONN]; } \
    uint32_t tcp_conn_set_##FIELD(uint32_t conn_id, uint32_t value) { g_tcp_##FIELD[conn_id % MAX_HOST_TCP_CONN] = value; return 0; }

TCP_GETSET(local_ip)
TCP_GETSET(local_port)
TCP_GETSET(local_seq)
TCP_GETSET(remote_ip)
TCP_GETSET(remote_port)
TCP_GETSET(remote_seq)
TCP_GETSET(state)
TCP_GETSET(rtx_count)
TCP_GETSET(rtx_deadline)
TCP_GETSET(rtx_len)
TCP_GETSET(rtx_seq)

int64_t *tcp_conn_get_rtx_buf(uint32_t conn_id) { return g_tcp_rtx_buf[conn_id % MAX_HOST_TCP_CONN]; }

static uint32_t g_usb_msd_bot, g_usb_msd_bulk_in_epaddr, g_usb_msd_bulk_in_mps;
static uint32_t g_usb_msd_bulk_out_epaddr, g_usb_msd_bulk_out_mps, g_usb_msd_in_toggle, g_usb_msd_out_toggle;
uint32_t usb_msd_get_bot(void) { return g_usb_msd_bot; }
uint32_t usb_msd_set_bot(uint32_t v) { g_usb_msd_bot = v; return 0; }
uint32_t usb_msd_get_bulk_in_epaddr(void) { return g_usb_msd_bulk_in_epaddr; }
uint32_t usb_msd_set_bulk_in_epaddr(uint32_t v) { g_usb_msd_bulk_in_epaddr = v; return 0; }
uint32_t usb_msd_get_bulk_in_mps(void) { return g_usb_msd_bulk_in_mps; }
uint32_t usb_msd_set_bulk_in_mps(uint32_t v) { g_usb_msd_bulk_in_mps = v; return 0; }
uint32_t usb_msd_get_bulk_out_epaddr(void) { return g_usb_msd_bulk_out_epaddr; }
uint32_t usb_msd_set_bulk_out_epaddr(uint32_t v) { g_usb_msd_bulk_out_epaddr = v; return 0; }
uint32_t usb_msd_get_bulk_out_mps(void) { return g_usb_msd_bulk_out_mps; }
uint32_t usb_msd_set_bulk_out_mps(uint32_t v) { g_usb_msd_bulk_out_mps = v; return 0; }
uint32_t usb_msd_get_in_toggle(void) { return g_usb_msd_in_toggle; }
uint32_t usb_msd_set_in_toggle(uint32_t v) { g_usb_msd_in_toggle = v; return 0; }
uint32_t usb_msd_get_out_toggle(void) { return g_usb_msd_out_toggle; }
uint32_t usb_msd_set_out_toggle(uint32_t v) { g_usb_msd_out_toggle = v; return 0; }
