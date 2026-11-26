/* Dhruva -- shared, persistent scratch buffers for the FS layer, the
 * interactive shell's command dispatch, and the expression evaluator
 * (ARM32).
 *
 * BUG this file exists to fix (found via a real, reproducible
 * crash-and-reboot-then-GC-runaway-loop under Phase 6's checkpoint
 * regression test -- see dharafs_compact's own doc comment in
 * kernel_main.vani for the first half of this same story): almost
 * every FS primitive (dharafs_find_latest_block_raw, dharafs_append_raw,
 * dharafs_delete_raw, dharafs_read, dharafs_read_raw, dharafs_list, plus the Str-based
 * dharafs_find_latest_block/dharafs_append/dharafs_delete wrappers) called
 * dhruva_alloc_bytes for its own internal scratch buffer on *every
 * call*, not just once. dhruva_alloc_bytes is a bump allocator that
 * never frees (see runtime_stubs.c) -- fine for something called once
 * at boot, but these are the FS layer's actual per-operation
 * workhorses, called every GC wake (task_e, every 20 ticks) and every
 * shell command (task_f). shell_dispatch's own per-command buffers
 * (line_buf, path_buf, out_buf/data_buf, expr_buf/error_buf) and
 * eval_expr_raw's own value/operator stacks had the exact same shape
 * of bug. Fixing dharafs_compact's own three buffers alone (its own
 * separate, earlier bug) was not enough -- the heap kept draining
 * through all of these until dhruva_alloc_bytes returned null and
 * something wrote straight through it with no null check, corrupting
 * low memory (the vector table lives at address 0) and crashing the
 * whole system a handful of shell commands into any real session.
 *
 * Every buffer below is allocated exactly once, in kernel_main(),
 * before start_multitasking -- the same pattern task_e's own gc_buf/
 * compact_buf/compact_path_buf/compact_data_buf already established.
 * Safe to share a single instance of each across many call sites
 * because (a) task_e and task_f are the only two tasks that ever touch
 * any of them, both at the same priority, and the scheduler's own
 * "ties favor the incumbent" rule (context_switch.S) means one can
 * never preempt the other mid-operation without an explicit sleep in
 * between -- and neither the FS layer nor shell_dispatch nor
 * eval_expr_raw ever sleeps mid-call; and (b) within any single call
 * chain, whichever function still needs a buffer's contents always
 * finishes reading them before any nested call that reuses the same
 * buffer for something else runs (verified call site by call site,
 * not assumed) -- exactly the same reasoning dharafs_list's own pre-
 * existing comment about buf/path_buf already relied on for its two
 * allocations, just carried through consistently instead of paired
 * with a fresh allocation every time. */

.section ".bss"
.align 4
dharafs_sd_scratch_addr:
    .word 0             /* 512 bytes: one on-disk block's worth,
                         * shared by every FS primitive that reads or
                         * builds exactly one raw SD block for its own
                         * internal use */
// TASK #357 follow-up (2026-10-18/19, real-HW SENTINEL corruption
// investigation): dedicated, NOT shared with dharafs_sd_scratch above
// -- this one gets written from inside the SD read/write wedge-retry
// path itself (sdhost_read_block/sdhost_write_block, kernel_main.vani),
// which runs CONCURRENTLY with whatever outer DharaFS call is already
// using dharafs_sd_scratch for the actual block being read/written.
// Reusing that buffer here would clobber the in-flight operation's own
// data mid-retry -- a separate 512-byte block is the only safe choice.
sd_wedge_ckpt_scratch_addr:
    .word 0             /* 512 bytes */
dharafs_path_scratch_addr:
    .word 0             /* 32 bytes: one path's worth */
dharafs_data_scratch_addr:
    .word 0             /* 464 bytes: one record's data payload, or
                         * (shared, never at the same time) one eval
                         * expression's source text */
// DharaFS persisted-checkpoint plan, foreground catch-up (2026-10-30):
// dedicated, NOT shared with compact_buf/compact_path_buf/compact_
// data_buf (task_e's own, kernel_main.vani) or with dharafs_sd_
// scratch/path_scratch/data_scratch above -- this file's own header
// comment already establishes why dharafs_compact's three buffer
// parameters must be separate from the generic FS scratch buffers
// (dharafs_read_raw's internal use of dharafs_sd_scratch would clobber
// a caller-owned `buf` of the same identity mid-call). The `dharafs
// catchup` shell command calls dharafs_compact() many times back to
// back from task_f, a genuinely different caller than task_e's own
// periodic wake -- reusing task_e's buffers isn't an option (they're
// task_e's own locals, no accessor exists), and reusing the generic
// scratch buffers would hit the exact aliasing hazard this file's own
// header already warns about.
dharafs_catchup_buf_addr:
    .word 0             /* 512 bytes, matches dharafs_sd_scratch's own
                         * sizing rationale (one on-disk block) */
dharafs_catchup_path_buf_addr:
    .word 0             /* 32 bytes, matches dharafs_path_scratch */
dharafs_catchup_data_buf_addr:
    .word 0             /* 20480 bytes, matches task_e's own compact_
                         * data_buf (dharafs_file_max_len(), task #164) */
// DharaFS Phase 3 (Round C, 2026-10-30): dedicated buffers for the
// honest-ENOSPC reclaim-then-retry's own dharafs_compact() calls (see
// dharafs_compact_drain_one_pass's header comment, kernel_main.vani).
// Not shared with dharafs_catchup_buf/etc above for the exact same
// reason those aren't shared with task_e's own compact_buf: this is a
// genuinely different caller (dharafs_write_raw_checked/dharafs_
// delete_raw_checked, reached from task_f's shell dispatch), and
// dharafs_compact's own internal use of a caller-owned `buf` parameter
// means two logically-concurrent callers can never safely share one
// instance.
dharafs_reclaim_buf_addr:
    .word 0             /* 512 bytes, matches dharafs_sd_scratch's own
                         * sizing rationale (one on-disk block) */
dharafs_reclaim_path_buf_addr:
    .word 0             /* 32 bytes, matches dharafs_path_scratch */
dharafs_reclaim_data_buf_addr:
    .word 0             /* 20480 bytes, matches task_e's own compact_
                         * data_buf (dharafs_file_max_len(), task #164) */
dharafs_stat_scratch_addr:
    .word 0             /* Round 42: 12 bytes -- dharafs_stat_raw's output
                         * (owner_uid/owner_gid/mode, 4 bytes each) */
dharafs_dir_scratch_addr:
    .word 0             /* Round 42: 32 bytes -- dharafs_list_dir_raw's own
                         * `dir` argument, held stable across its whole
                         * scan. Deliberately separate from dharafs_path_
                         * scratch, which that same scan reuses
                         * per-record for each candidate's OWN path --
                         * aliasing the two would corrupt `dir` the
                         * moment the first record's path got copied
                         * into what the caller thought was a stable
                         * buffer. */
shell_line_scratch_addr:
    .word 0             /* 128 bytes: shell_dispatch's own copy of the
                         * current input line */
eval_values_scratch_addr:
    .word 0             /* 128 bytes: eval_expr_raw's value stack, 16
                         * slots of 8 bytes each (a hi/lo u32 pair per
                         * i64) -- was 64 bytes / 4 bytes-per-slot until
                         * round 2's audit found that storing each value
                         * as a single truncating u32 silently corrupted
                         * any number beyond +-2 billion the instant it
                         * was pushed (see eval_write_value/
                         * eval_read_value in kernel_main.vani) */
eval_ops_scratch_addr:
    .word 0             /* 64 bytes: eval_expr_raw's operator stack */
uart_digits_scratch_addr:
    .word 0             /* 24 bytes: uart_put_i64's reversed-digit
                         * scratch -- a small, generic print helper
                         * called from many places (including live
                         * eval commands, not just boot self-tests), so
                         * it gets its own dedicated buffer rather than
                         * risking aliasing one already in active use
                         * by whatever called it. */
dwc2_dma_scratch_addr:
    .word 0             /* 64 bytes: the DWC2 host channel's DMA
                         * buffer for control transfers (SETUP packet,
                         * descriptor data). This model is DMA-only
                         * (FIFO/slave-mode MMIO is unimplemented, see
                         * kernel_main.vani's dwc2 section header
                         * comment) -- HCDMA(n) must point at a real
                         * buffer, and the same "never call
                         * dhruva_alloc_bytes on every call" lesson
                         * from the FS/shell bug applies here too, since
                         * enumeration issues many transfers over one
                         * session. Not shared with the FS-layer
                         * scratch buffers above -- USB has no
                         * established call-graph relationship to those
                         * yet, so it gets its own dedicated buffer
                         * rather than assuming sharing is safe without
                         * verifying it the way those were. */
usb_downstream_desc_scratch_addr:
    .word 0             /* 18 bytes: dwc2_enumerate_one_downstream_
                         * device's own GET_DESCRIPTOR result buffer
                         * (shared by its 8-byte address-0 fetch and its
                         * later 18-byte post-SET_ADDRESS fetch -- 18
                         * bytes covers both, and the two fetches are
                         * sequential, never concurrent, so one buffer
                         * is safe). BUG FOUND 2026-11-12 (real-HW heap-
                         * exhaustion FATAL during WiFi-enumeration
                         * investigation): this function used to call
                         * dhruva_alloc_bytes(8)/dhruva_alloc_bytes(18)
                         * fresh on every call -- and it's called once
                         * per OUTER port-bring-up retry attempt (up to
                         * usb_first_contact_retry_count()=5 times) for
                         * EACH hub port checked, with nothing ever
                         * freeing those allocations (this allocator has
                         * no free at all). Exactly the same "never call
                         * dhruva_alloc_bytes on every call" lesson
                         * dwc2_dma_scratch's own comment above already
                         * documents for this exact USB enumeration
                         * code -- this function just didn't follow it.
                         * Normally harmless (a few hundred bytes), but
                         * a boot with several ports repeatedly failing
                         * enumeration (seen live this session, chasing
                         * an unrelated WiFi RX bug) burns through enough
                         * of the already-thin boot-time heap headroom
                         * to hit a real FATAL out-of-memory halt. */
hub_port_status_scratch_addr:
    .word 0             /* 4 bytes: GET_PORT_STATUS result buffer,
                         * shared by dwc2_hub_bring_up_port, dwc2_hub_
                         * port_debounce_connected and usb_hotplug_
                         * sample_port_connected. BUG FOUND 2026-11-13
                         * (same session, same class as usb_downstream_
                         * desc_scratch above, found while that OTHER
                         * fix's own fresh boot still hit the identical
                         * FATAL): all three of these functions called
                         * dhruva_alloc_bytes(4) fresh on every call, and
                         * all three run once per port-retry attempt --
                         * dwc2_hub_port_debounce_connected and dwc2_hub_
                         * bring_up_port are even called from the SAME
                         * outer retry loop, so a port that keeps failing
                         * leaked two 4-byte blocks per attempt, not one.
                         * None of the three calls overlap (each reads
                         * its own result and returns before the next is
                         * ever called), so one shared buffer is safe. */
rtl_lan_reg_scratch_addr:
    .word 0             /* 4 bytes: shared read/write scratch for
                         * lan9512_reg_read/write and rtl_reg_read8/16/32
                         * + rtl_reg_write8/16/32 -- the WORST instance
                         * of this same bug class found this session.
                         * These are the low-level register-access
                         * primitives for RTL8188CU MAC bring-up (RF
                         * table programming, CCK/OFDM enable, LC
                         * calibration, firmware handshake, ...), called
                         * from everywhere in that bring-up sequence --
                         * easily 100+ times in a single boot's worth of
                         * chip init, each one a fresh dhruva_alloc_
                         * bytes(1/2/4) with nothing ever freed. This is
                         * the real dominant contributor to the real-HW
                         * "FATAL: dhruva_alloc_bytes out of memory"
                         * halt that kept recurring even after the hub-
                         * port-status leak (above) was fixed -- MAC
                         * bring-up burns through far more heap per boot
                         * than a few port-retry attempts ever could.
                         * Safe to share one buffer across all 8 call
                         * sites: every one of them completes its control
                         * transfer and copies the result out to local
                         * u32s before returning, and rtl_rf_reg_read/
                         * write (which call these) do so sequentially,
                         * never with two live at once. */
netif_tx_wrap_scratch_addr:
    .word 0             /* 520 bytes: netif_send_frame's own LAN9512
                         * TX-framing wrapped_buf (8-byte TX_CMD_A/B
                         * header + up to 512 bytes of frame). BUG FOUND
                         * 2026-11-13 (real-HW live crash, not a QEMU
                         * finding): this is THE call site that matches
                         * the live FATAL's own "requested 520 bytes"
                         * message exactly -- confirmed by direct grep
                         * for dhruva_alloc_bytes(520), not inferred.
                         * netif_send_frame is the single egress choke
                         * point for every outgoing frame (ARP/IPv4/
                         * ICMP/UDP/TCP, per its own header comment) --
                         * a DHCP client endlessly retrying DISCOVER with
                         * no server on the bench (exactly this session's
                         * setup) calls it repeatedly, each call leaking
                         * another 520 bytes with nothing ever freed.
                         * Only live in the LAN9512 (usb_net_get_kind()
                         * ==2) branch; the CDC-ECM branch never touches
                         * it, so no overlap with netif_tx_chunk_scratch
                         * below even though that one IS shared across
                         * both branches. */
netif_tx_chunk_scratch_addr:
    .word 0             /* 64 bytes: netif_send_frame's per-USB-packet
                         * chunk buffer -- chunk_buf (CDC-ECM branch,
                         * kind==1) and chunk_buf2 (LAN9512 branch,
                         * kind==2) are the SAME never-free bug, just in
                         * mutually-exclusive branches (usb_net_get_kind()
                         * is one fixed value for the whole boot), so one
                         * shared buffer covers both. Within the kind==2
                         * branch this chunk buffer and netif_tx_wrap_
                         * scratch above are both alive at once (the
                         * chunking loop re-reads wrap while filling
                         * chunk), which is exactly why they need
                         * separate storage, not one shared slot. */
netif_rx_raw_scratch_addr:
    .word 0             /* 520 bytes: netif_recv_frame's own LAN9512
                         * RX-framing raw_buf (4-byte status + 2-byte
                         * NET_IP_ALIGN pad + up to 514 bytes of frame+
                         * FCS). Same bug, RX side: netif_recv_frame is
                         * the single ingress funnel, polled continuously
                         * by the network stack regardless of whether a
                         * frame actually arrived, so this leak accrues
                         * even faster than the TX side above -- the
                         * likely dominant contributor to the live "520
                         * bytes" FATAL, not just a contributor. */
netif_rx_chunk_scratch_addr:
    .word 0             /* 64 bytes: netif_recv_frame's per-USB-packet
                         * chunk buffer -- chunk_buf (kind==1) and
                         * chunk_buf3 (kind==2), same mutual-exclusion
                         * reasoning as netif_tx_chunk_scratch above.
                         * Separate from the TX-side scratch slots (not
                         * reused across send/recv): the two functions
                         * aren't documented as mutually exclusive in
                         * time the way the hub-port and RF-register
                         * call sites are, so each direction keeps its
                         * own storage. */
tcp_empty_payload_scratch_addr:
    .word 0             /* 1 byte: the placeholder payload pointer
                         * every TCP control segment (SYN, ACK, FIN,
                         * ...) passes to tcp_send_segment with
                         * payload_len=0 -- its CONTENT is never read
                         * or written (tcp_build_header's own payload
                         * copy loop never executes when payload_len is
                         * 0), only a valid non-null pointer is needed.
                         * Found via the exact same audit as every
                         * other entry in this file: tcp_conn_handle_
                         * segment allocated a fresh one of these on
                         * every one of its five response branches, and
                         * it's called once per INCOMING SEGMENT --
                         * potentially many times over one real TCP
                         * connection's lifetime, the identical "called
                         * repeatedly at runtime, not just once at
                         * boot" shape as the FS-layer bug this file
                         * was created to fix. */
net_send_scratch_addr:
    .word 0             /* netif_frame_slot_size() bytes (1514 as of
                         * round 66, was a hardcoded 512 -- see
                         * kernel_main.vani's own netif_frame_slot_size
                         * comment for the full fix): the one Ethernet+IP(+UDP/TCP)
                         * frame buffer ipv4_send/udp_send/
                         * tcp_send_segment each build their outgoing
                         * frame into. Found via the SAME audit as
                         * tcp_empty_payload_scratch above, and just as
                         * serious: these three ARE this whole
                         * project's real network send path, each
                         * originally allocating its own fresh 512-byte
                         * buffer on every single call -- undetected so
                         * far only because nothing has driven them in
                         * a real loop yet (self-tests call each a
                         * handful of times), but tcp_send_segment
                         * alone is reachable from tcp_conn_handle_
                         * segment (once per incoming TCP segment) as
                         * well as every tcp_conn_* API function, so
                         * any real, sustained use of this networking
                         * stack -- exactly what it exists for -- would
                         * have exhausted the 64KB heap in well under
                         * 150 sends. Safe to share one instance
                         * across all three: none of them call each
                         * other (each independently builds a complete
                         * frame from scratch, no nesting), so there's
                         * no point where two of them could need this
                         * buffer's contents to coexist.
                         *
                         * NOT YET verified safe against a second
                         * concurrent task using this networking stack
                         * (unlike the FS-layer buffers above, whose
                         * task_e/task_f-only, tied-priority safety
                         * argument was checked call site by call
                         * site) -- nothing calls into networking from
                         * any task today, only single-threaded boot
                         * self-tests. Re-verify this sharing argument
                         * before wiring any task up to send network
                         * traffic. */
net_recv_scratch_addr:
    .word 0             /* netif_frame_slot_size() bytes (1514 as of
                         * round 66, was a hardcoded 512): socket_udp_recv's own internal
                         * received-frame buffer -- same bug, same
                         * fix. A future TCP-level socket_tcp_recv
                         * equivalent would need the same treatment;
                         * tcp_conn_handle_segment itself doesn't need
                         * this one since its `frame` is always a
                         * caller-supplied parameter, never its own
                         * internal allocation. */
udp_send_arp_scratch_addr:
    .word 0             /* 6 bytes: socket_udp_send's own resolved-
                         * destination-MAC buffer (round 21 audit,
                         * 2026-08-28). Same "never dhruva_alloc_bytes
                         * on every call" reasoning as every other
                         * buffer in this file -- socket_udp_send is
                         * meant to be reused by real callers (an echo
                         * server, per this project's own existing
                         * comment on the layer it belongs to), not
                         * just its own single-call self-test. */
arp_resolve_scratch_addr:
    .word 0             /* 64 bytes: arp_resolve_start's own outgoing
                         * ARP-request frame buffer (round 22 audit,
                         * 2026-08-28) -- same shape/size as arp_self_
                         * test's own req_frame, but this one backs a
                         * LIVE function meant to be called repeatedly
                         * (once per address that needs resolving),
                         * not a single self-test call. */
dhcp_server_mac_scratch_addr:
    .word 0             /* 6 bytes: round 22 audit, 2026-08-28 --
                         * holds the DHCP server's MAC, either just
                         * extracted from an ACK frame's own Ethernet
                         * source address (learned for free, no ARP
                         * round trip needed) or read back via
                         * arp_cache_lookup right before a unicast
                         * lease-renewal REQUEST. Dedicated rather than
                         * reusing udp_send_arp_scratch above -- same
                         * per-buffer-single-purpose discipline this
                         * whole file already follows (see e.g. this
                         * file's own USB-vs-FS-scratch reasoning
                         * further up), even though the two would
                         * never actually collide in practice (DHCP
                         * sends go through udp_send directly, never
                         * through socket_udp_send). */
arp_resolve_mac_scratch_addr:
    .word 0             /* 6 bytes: arp_resolve_poll's own transient
                         * holding spot for a just-parsed reply's
                         * sender MAC, before arp_cache_insert. Kept
                         * separate from dhcp_server_mac_scratch above
                         * even though nothing currently calls both in
                         * the same graph -- same reasoning, a name
                         * that says what actually uses it beats a
                         * borrowed one that would read as a hidden
                         * coupling that doesn't exist. */
netif_arp_autoanswer_sender_mac_scratch_addr:
    .word 0             /* 6 bytes: netif_recv_frame's own ARP-auto-
                         * answer hook (protocol-audit sweep, found via
                         * a direct comparison against u-boot/net/
                         * arp.c's arp_receive() and Linux's
                         * arp_process() -- both answer an incoming
                         * REQUEST transparently at the netif layer;
                         * this project previously had NO code path
                         * that ever did, at all -- arp_build_reply was
                         * only ever called from self-tests). Holds the
                         * requesting peer's MAC, extracted from the
                         * just-dequeued REQUEST frame, before building
                         * the reply. */
netif_arp_autoanswer_my_mac_scratch_addr:
    .word 0             /* 6 bytes: this board's own MAC, fetched via
                         * netif_get_mac right before building the
                         * auto-answer reply -- kept separate from
                         * every other my_mac scratch in this file
                         * (same per-buffer-single-purpose discipline),
                         * since netif_recv_frame is the one consumer
                         * here with no caller-supplied buffer to reuse. */
netif_arp_autoanswer_reply_scratch_addr:
    .word 0             /* 64 bytes: the auto-generated ARP reply frame
                         * itself, built then immediately handed to
                         * netif_send_frame from inside netif_recv_frame
                         * -- same size as every other one-ARP-frame
                         * buffer in this file (e.g. arp_resolve_scratch
                         * above). */
tcp_unmatched_rst_peer_mac_scratch_addr:
    .word 0             /* 6 bytes: tcp_conn_poll's own RST-on-
                         * unmatched-port hook (protocol-audit sweep --
                         * compared against Linux's tcp_v4_send_reset,
                         * the "no socket matches incoming packet"
                         * path). Holds the Ethernet source MAC pulled
                         * straight out of the just-dequeued segment's
                         * own frame (there's no ARP-cache entry to
                         * rely on here -- this is, by definition, a
                         * peer we have no established state for), so
                         * the RST can be addressed straight back at
                         * whoever sent the unmatched segment. */
dns_query_scratch_addr:
    .word 0             /* 64 bytes: dns_resolve's own outgoing DNS
                         * query buffer (RFC 1035 -- single A-record
                         * query/response client, scoped like u-boot's
                         * own net/dns.c). Fixed size, built fresh per
                         * call, same "never dhruva_alloc_bytes on
                         * every call" discipline every other live
                         * (not just self-test) networking buffer in
                         * this file already follows. */
dns_resp_scratch_addr:
    .word 0             /* 512 bytes: dns_resolve_poll's own incoming
                         * DNS response buffer -- 512 gives real
                         * headroom over a realistic single-A-record
                         * response (~40-60 bytes), same "don't trust
                         * a synthetic size" lesson DHCP's own 512->
                         * 1024 bump already taught this project. */
dns_server_mac_scratch_addr:
    .word 0             /* 6 bytes: dns_resolve_start's own holding
                         * spot for the DNS server's MAC, learned via
                         * arp_cache_lookup before unicasting the
                         * query -- same per-buffer-single-purpose
                         * discipline as every other scratch in this
                         * file (not reused from e.g. dhcp_server_mac_
                         * scratch, a different peer role entirely). */
shell_hostname_scratch_addr:
    .word 0             /* 64 bytes: the shell's own copy-out spot for
                         * a hostname argument (nslookup's own, or
                         * ping's hostname-fallback argument) -- safe
                         * to share between the two since they're
                         * mutually exclusive shell commands (one
                         * shell task, one command at a time), same
                         * reasoning shell_my_mac_scratch/shell_ping_
                         * dst_mac_scratch already get reused across
                         * multiple call sites within one command. */
kernlog_line_scratch_addr:
    .word 0             /* 512 bytes: kernlog_write's own composed-line
                         * build buffer (timestamp + level + message),
                         * capped to match dharafs_log_record_max_len()
                         * -- the one real ceiling this buffer must
                         * never exceed, since dharafs_log_append_raw
                         * itself rejects anything longer. Persistent
                         * for the same "never dhruva_alloc_bytes on
                         * every call" reason as every other buffer in
                         * this file: kernlog_write fires from fault
                         * handlers and hot error paths, not a one-shot
                         * boot step. */
dhcp_payload_scratch_addr:
    .word 0             /* 300 bytes: the DHCP client's own message
                         * build buffer (DISCOVER/REQUEST), shared by
                         * dhcp_client_start and dhcp_client_poll --
                         * same "never dhruva_alloc_bytes on every
                         * call" reasoning as every other buffer in
                         * this file, since dhcp_client_poll is meant
                         * to be called repeatedly (once per received
                         * frame) for as long as address acquisition
                         * takes. 240 bytes of fixed BOOTP header/magic
                         * cookie plus up to 16 bytes of options
                         * (message type + requested-IP + server-ID +
                         * end) comfortably fits. */
dhcp_frame_scratch_addr:
    .word 0             /* netif_frame_slot_size() bytes (1514 as of
                         * round 66, was a hardcoded 512 -- see docs/
                         * TODO.md's own bug entry: a real DHCPOFFER
                         * with many options exceeded the old 512 and
                         * was silently dropped): dhcp_client_poll's own received-
                         * frame buffer, same shape as net_recv_scratch
                         * above but kept separate (not shared with
                         * socket_udp_recv) since nothing has verified
                         * the two could safely alias yet -- same
                         * "don't assume sharing is safe without
                         * checking" caution net_send_scratch's own
                         * comment already flags for a different pair
                         * of buffers. */
dhcp_bcast_mac_scratch_addr:
    .word 0             /* 8 bytes: the FF:FF:FF:FF:FF:FF Ethernet
                         * broadcast address DHCPDISCOVER/DHCPREQUEST
                         * both go out to (the server's real MAC isn't
                         * known until an OFFER names it) -- built once
                         * per send rather than turned into a
                         * compile-time constant only because vani has
                         * no way to write a byte-buffer literal
                         * directly; still just one persistent buffer,
                         * not a fresh allocation per call. */
dhcp_server_client_mac_scratch_addr:
    .word 0             /* Round 107: 6 bytes -- the DHCP SERVER's own
                         * holding spot for whichever client's MAC it's
                         * currently processing (extracted from the
                         * incoming frame's own Ethernet source
                         * address/chaddr field), used across handle_
                         * discover/handle_request/build_offer_ack/
                         * build_nak/send_reply within one poll call.
                         * Deliberately NOT dhcp_server_mac_scratch
                         * above -- that buffer holds a different thing
                         * entirely (the CLIENT role's own record of
                         * the SERVER's MAC, learned from an ACK) --
                         * reusing it here would be the same borrowed-
                         * name hidden-coupling mistake arp_resolve_
                         * mac_scratch's own comment above already
                         * warns against. */
dhcp_server_payload_scratch_addr:
    .word 0             /* Round 107: 300 bytes, same size/reasoning as
                         * dhcp_payload_scratch above -- the DHCP
                         * SERVER's own OFFER/ACK/NAK message build
                         * buffer. Kept separate from the CLIENT's own
                         * dhcp_payload_scratch even though nothing
                         * calls both roles concurrently today, matching
                         * boot/dhcp_server_state.S's own header comment
                         * ("client and server are independent roles
                         * this project may eventually run
                         * simultaneously"). */
dhcp_server_frame_scratch_addr:
    .word 0             /* Round 107: netif_frame_slot_size() bytes,
                         * same size/reasoning as dhcp_frame_scratch
                         * above -- the DHCP SERVER's own received-frame
                         * buffer, kept separate from the client's. */
usb_bulk_data_scratch_addr:
    .word 0             /* Round 35: 512 bytes -- dwc2_bulk_out/
                         * dwc2_bulk_in's own DMA buffer, separate from
                         * dwc2_dma_scratch (64 bytes, control transfers
                         * only). USB mass storage's CBW (31B)/CSW (13B)
                         * fit easily in either, but READ(10)/WRITE(10)
                         * need to move a full 512-byte sector -- a
                         * dedicated buffer sized for that real need
                         * rather than growing the control-transfer
                         * scratch (which every already-proven control
                         * transfer call site still only ever needs 64
                         * bytes for) and risking a change to code that
                         * didn't need to change. */
dharafs_log_path_scratch_addr:
    .word 0             /* Round 49: 32 bytes -- dharafs_log_append_raw's
                         * own current-log-file path buffer. Same "never
                         * dhruva_alloc_bytes on every call" reasoning as
                         * every other buffer in this file -- a log is
                         * exactly the "called repeatedly at runtime"
                         * shape this file exists to fix (sensor logging
                         * appends once per reading, not once at boot). */
dharafs_log_header_path_scratch_addr:
    .word 0             /* Round 49: 32 bytes -- the log's own small
                         * ".hdr" file's path (current file index +
                         * current size), separate from dharafs_log_path_
                         * scratch above since both need to be live at
                         * once within a single dharafs_log_append_raw
                         * call. */
dharafs_log_header_data_scratch_addr:
    .word 0             /* Round 49: 8 bytes -- the header's own 8-byte
                         * payload (u32 current_index, u32 current_size),
                         * read then overwritten with the new values
                         * within one call -- safe since every field is
                         * read into a local before this buffer is
                         * reused for the write-back. */
dharafs_log_existing_scratch_addr:
    .word 0             /* Round 49: 4096 bytes (dharafs_file_max_len())
                         * -- the current log file's existing content,
                         * read back so a new record can be concatenated
                         * onto it before re-appending the whole file
                         * (this project's append-to-an-existing-path
                         * primitive is always "replace with the newest
                         * full content", not a true byte-level append). */
dharafs_log_combined_scratch_addr:
    .word 0             /* Round 49: 4096 bytes -- existing content +
                         * the new record, built here before being
                         * written back as the log file's new full
                         * content. Bounded safely under 4096 by
                         * dharafs_log_append_raw's own rollover
                         * threshold (3584) plus its own per-record size
                         * cap (512) -- see that function's own comment. */
dharafs_verified_companion_scratch_addr:
    .word 0             /* Round 48 BUG FIX (found during round 49's
                         * own audit, before this ever shipped further):
                         * dharafs_write_verified_raw/dharafs_read_
                         * verified_checked originally called dhruva_
                         * alloc_bytes fresh on every call for this
                         * 32-byte companion-path buffer -- the exact
                         * "never dhruva_alloc_bytes on every call" bug
                         * this whole file exists to prevent, and catv/
                         * writev are meant to be called repeatedly, not
                         * once at boot. Shared by both functions since
                         * neither ever calls the other (same reasoning
                         * as every other shared buffer in this file). */
dharafs_verified_digest_a_scratch_addr:
    .word 0             /* Round 48 bug fix: 32 bytes -- the freshly
                         * COMPUTED digest, in both the write path
                         * (computed once from the data just written)
                         * and the read path (computed from the data
                         * just read, compared against digest_b below). */
dharafs_verified_digest_b_scratch_addr:
    .word 0             /* Round 48 bug fix: 32 bytes -- the STORED
                         * digest read back off disk, read path only
                         * (compared against digest_a above). Kept
                         * separate from digest_a since both need to be
                         * live at once for the comparison. */
dharafs_appendonly_check_scratch_addr:
    .word 0             /* Round 50: 4096 bytes (dharafs_file_max_len())
                         * -- dharafs_attr_check_write's own OLD-content
                         * buffer for validating an append-only write's
                         * prefix. Deliberately NOT dharafs_data_scratch,
                         * which the caller's NEW data already occupies
                         * -- aliasing the two would corrupt the very
                         * buffer being compared against. */
shell_my_mac_scratch_addr:
    .word 0             /* BUG FIX (found via a post-round-51 sweep for
                         * the "dhruva_alloc_bytes on every call" bug
                         * class, same pattern as dharafs_rename_new_
                         * path_scratch above): ping/ifconfig/tcpecho/
                         * udpecho/tcprtx each allocated their OWN fresh
                         * 8-byte "my_mac" buffer via netif_get_mac() on
                         * every single call -- every one of these is an
                         * ordinary, repeatable shell command. Shared
                         * across all five (same reasoning dharafs_path_
                         * scratch already uses across cat/rm/write/mv:
                         * shell_dispatch only ever runs one command
                         * block per call, so there's no aliasing hazard
                         * between mutually-exclusive command paths). */
shell_ping_dst_mac_scratch_addr:
    .word 0             /* 8 bytes -- ping's own resolved-destination
                         * MAC. */
shell_ping_payload_scratch_addr:
    .word 0             /* 4 bytes -- ping's own outgoing ICMP payload
                         * ("ping" as 4 literal bytes). */
shell_ping_recv_payload_scratch_addr:
    .word 0             /* 4 bytes -- ping's own incoming ICMP reply
                         * payload. */
shell_ping_recv_meta_scratch_addr:
    .word 0             /* 8 bytes -- ping's own icmp_poll metadata
                         * (identifier/seq). */
shell_tcpecho_payload_scratch_addr:
    .word 0             /* 64 bytes -- tcpecho's own outgoing text. */
shell_tcp_poll_scratch_addr:
    .word 0             /* 512 bytes -- the generic throwaway buffer
                         * tcp_conn_poll needs for handshake/close
                         * frames whose content tcpecho/tcprtx don't
                         * care about. Shared by both commands (same
                         * generic role, mutually exclusive execution). */
shell_tcpecho_recv_payload_scratch_addr:
    .word 0             /* 64 bytes -- tcpecho's own echoed-back reply
                         * payload. */
shell_udpecho_payload_scratch_addr:
    .word 0             /* 64 bytes -- udpecho's own outgoing text. */
shell_udpecho_recv_payload_scratch_addr:
    .word 0             /* 64 bytes -- udpecho's own received datagram
                         * payload (both the initial send's own echo
                         * check and the actual echo-back reuse this
                         * same buffer sequentially within one call). */
shell_udpecho_recv_meta_scratch_addr:
    .word 0             /* 8 bytes -- udpecho's own socket_udp_recv
                         * metadata (src/dst port). */
shell_tcprtx_drop_buf_scratch_addr:
    .word 0             /* 64 bytes -- tcprtx's own deliberately-
                         * dropped-frame buffer (the simulated packet
                         * loss this command exists to test). */
sha256_padded_scratch_addr:
    .word 0             /* BUG FIX (documented follow-up from round 48,
                         * fixed now at the user's own request): sha256_
                         * hash allocated its own padded-message buffer
                         * fresh via dhruva_alloc_bytes on every call --
                         * fine when its only caller was a once-at-boot
                         * self-test (round 41), but round 48's writev/
                         * catv call it on every real verified write/
                         * read. Sized to the worst case for the
                         * largest real caller: total_len = msg_len + 1
                         * + zero_pad + 8, zero_pad in [0,63], msg_len
                         * capped at dharafs_file_max_len() (4096) by
                         * every real caller upstream (dharafs_append_
                         * raw itself rejects anything larger before it
                         * could ever reach here) -- 4096+1+63+8 = 4168. */
sha256_h_scratch_addr:
    .word 0             /* 32 bytes -- the running hash state (8 u32
                         * words). */
sha256_k_scratch_addr:
    .word 0             /* 256 bytes -- the 64-entry round-constant
                         * table, IDENTICAL on every call (sha256_
                         * k_init always writes the same 64 constants)
                         * -- computing it fresh into a fresh buffer
                         * every call was doubly wasteful, not just a
                         * heap-growth bug. */
sha256_w_scratch_addr:
    .word 0             /* 256 bytes -- the message schedule, fully
                         * overwritten by sha256_compress at the start
                         * of every block, so reusing this across calls
                         * (and across blocks within one call) is safe. */
dharafs_rename_new_path_scratch_addr:
    .word 0             /* BUG FIX (found during a post-round-51 sweep
                         * for the exact "dhruva_alloc_bytes on every
                         * call" bug class this whole file exists to
                         * prevent -- round 49's own audit already
                         * caught one instance of this in round 48's
                         * code; this is a second one, in round 47's):
                         * dharafs_rename (Str wrapper) and the shell
                         * `mv` command both allocated a fresh 32-byte
                         * buffer via dhruva_alloc_bytes for the NEW
                         * path on every single call -- `mv` is an
                         * ordinary, repeatable shell command, so every
                         * real rename permanently leaked 32 bytes.
                         * dharafs_path_scratch (the one shared path
                         * buffer) is already claimed by the OLD path
                         * in both call sites, so this needs its own
                         * slot, same reasoning as dharafs_dir_scratch's
                         * own comment on why it can't just reuse
                         * dharafs_path_scratch either. */
gatt_send_scratch_addr:
    .word 0             /* 256 bytes -- gatt_att_send's own outgoing
                         * ACL(4)+L2CAP(4)+ATT PDU buffer (round 66).
                         * 256 comfortably covers any ATT PDU this
                         * round's own operations build (max real size
                         * is Read By Group Type's request/response at
                         * 7-ish bytes plus a handful of discovered
                         * entries, nowhere near a real ATT_MTU's own
                         * upper bound of 247) with headroom to spare. */
gatt_recv_scratch_addr:
    .word 0             /* 256 bytes -- gatt_att_recv's own incoming
                         * buffer, same size/reasoning as gatt_send_
                         * scratch above. */
fsqueue_path_scratch_addr:
    .word 0             /* 32 bytes -- dharafs_queue_dispatch_one's own
                         * copy of the queued request's path, decoded
                         * from fsqueue_state.S's byte-addressed
                         * storage before handing off to dharafs_
                         * append_raw/dharafs_delete_raw, same
                         * one-allocation-at-boot pattern as every
                         * other FS scratch buffer above. */
fsqueue_data_scratch_addr:
    .word 0             /* 448 bytes -- same, for the queued write's
                         * data payload (fsqueue_max_data_bytes()). */
poly1305_block_scratch_addr:
    .word 0             /* 16 bytes -- poly1305_mac's own scratch for
                         * building the final zero-padded partial
                         * block, same one-allocation-at-boot pattern. */
sha512_h_scratch_addr:
    .word 0             /* 64 bytes -- SHA-512's 8 x 64-bit running
                         * state words. Same round-65-hardening
                         * reasoning as sha256_h/w/k_scratch (see
                         * sha256_compress's own comment): always
                         * re-fetched fresh via *_scratch_get() at
                         * every point of use inside sha512_compress,
                         * never held live in one register/local across
                         * its whole 80-round loop body. */
sha512_k_scratch_addr:
    .word 0             /* 640 bytes -- the 80 round constants (8 bytes
                         * each), initialized once at boot
                         * (sha512_k_init) since they never change. */
sha512_w_scratch_addr:
    .word 0             /* 640 bytes -- the 80-word message schedule. */
sha512_padded_scratch_addr:
    .word 0             /* 4224 bytes -- sized to the worst case for a
                         * 4096-byte message (this project's own
                         * dharafs_file_max_len() bound, same ceiling
                         * SHA-256's own padded scratch uses): with_one=
                         * 4097, zero_pad=111, total_len=4097+111+16=
                         * 4224 (SHA-512 uses a 128-byte block and a
                         * 16-byte, not 8-byte, length trailer). */
uart_dma_scratch_addr:
    .word 0             /* Task #357: 512 bytes -- uart_puts's own DMA-
                         * path copy buffer (kernel_main.vani). Longest
                         * single uart_puts string literal measured in
                         * this file today is 257 bytes; 512 is this
                         * project's own established "generous costs
                         * nothing for a one-time persistent buffer"
                         * margin (same reasoning as usb_bulk_data_
                         * scratch/dns_resp_scratch above, both also
                         * 512). Separate from dwc2_dma_scratch/usb_
                         * bulk_data_scratch -- UART and USB DMA never
                         * run concurrently today, but this buffer's
                         * whole reason to exist is per-subsystem
                         * isolation, not a shared pool. */
rtl_rx_raw_scratch_addr:
    .word 0             /* BUG FOUND 2026-11-16 (real-HW board HANG,
                         * "wifi listen 11" -- confirmed the SAME bug
                         * class rtl_lan_reg_scratch's own comment above
                         * already documents for this exact RTL8188CU
                         * bring-up code, just a different function):
                         * rtl8188cu_rx_frame called dhruva_alloc_bytes
                         * (512) fresh on EVERY call for its own raw USB-
                         * transfer accumulation buffer, and this
                         * function is the single receive choke point
                         * polled every iteration of wifi_passive_
                         * listen's/wifi_scan_for_ssid's/wifi_real_join's
                         * loops -- regardless of whether a frame was
                         * actually heard that poll. "wifi listen 1" and
                         * "wifi listen 6" (300 polls each, lighter
                         * traffic) left enough already-leaked headroom
                         * that "wifi listen 11" (heaviest beacon traffic
                         * of the three channels checked) tipped the
                         * 768KB heap over into a genuine FATAL out-of-
                         * memory halt -- with no exit() call on this
                         * path (dhruva_oom_fatal's own raw `cpsid i;
                         * while(1)`, see runtime_stubs.c), and the
                         * real-HW watchdog not observed to recover it
                         * either (separate, still-open investigation --
                         * see project memory). 512 bytes: one max-size
                         * RX USB-transfer accumulation buffer. */

/* BUG FOUND 2026-11-19 (methodical full-stack audit): this chip can
 * bundle multiple received frames into one USB bulk-IN transfer
 * (confirmed against the real driver's own pkt_cnt field); rtl8188cu_
 * rx_frame used to always parse only the FIRST frame at a fixed
 * buffer offset and silently discard any others. These three words
 * let it "remember" an unfinished bundle across calls: how many more
 * frames remain, and the byte offset in rtl_rx_raw_scratch where the
 * next one starts, so the next caller drains it (no new USB read)
 * instead of the data being lost the moment this function returns.
 * rtl_rx_bundle_total_len is the bundle's own total valid length
 * (`got` from the original read), needed to know when there's no
 * longer enough remaining data for another real descriptor. */
.align 4
rtl_rx_bundle_remaining:
    .word 0
rtl_rx_bundle_offset:
    .word 0
rtl_rx_bundle_total_len:
    .word 0

rtl_rx_chunk_scratch_addr:
    .word 0             /* Same bug/fix as rtl_rx_raw_scratch above --
                         * rtl8188cu_rx_frame's own per-USB-packet chunk
                         * buffer, previously a fresh dhruva_alloc_bytes
                         * (64) on every call. 64 bytes: one max packet
                         * size (RTL8188CU's bulk-IN endpoint mps). */
rtl_tx_buf_scratch_addr:
    .word 0             /* Same bug class, TX side: rtl8188cu_tx_frame
                         * called dhruva_alloc_bytes(RTL_TXDESC_LEN +
                         * frame_len) fresh on every single TX (every
                         * Probe/Auth/Assoc/EAPOL/data frame sent) --
                         * found during the same 2026-11-16 sweep as
                         * rtl_rx_raw_scratch above, after that RX-side
                         * fix caused a real board hang and prompted a
                         * sibling-function check. 512 bytes: that
                         * function's own hard size cap (`if (RTL_
                         * TXDESC_LEN + frame_len) > 512 { return -1; }`),
                         * so this is already sized to the true worst
                         * case, not an assumption. */
// 2026-11-16 full heap-leak audit (triggered by the real board hang
// above -- user asked to sweep every function, not just the one that
// crashed). Two severity tiers below, both real, both fixed the same
// way:
//
//   SEVERE (same shape as rtl_rx_raw_scratch -- allocated inside a
//   function called repeatedly from a live, bounded RETRY loop, so
//   each retry leaks again): icmp_poll (up to 8x per `ping`, see
//   shell_dispatch's own ping command) and wpa2_join_step_eapol (up to
//   WIFI_RX_POLL_CAP times per `wifi join`, once per genuinely-parsed
//   EAPOL frame including ordinary Message-1 retransmissions -- see
//   that function's own WAIT_EAPOL_MSG1 branch).
//
//   MINOR (allocated once per CALL, hoisted above any internal loop --
//   not a per-poll leak, but still a real permanent leak every time the
//   owning shell command runs, and WiFi commands were run many times
//   during tonight's investigation): wifi_real_join, wifi_scan_for_ssid,
//   wifi_passive_listen, rtl8188cu_mac_bringup, rtl8188cu_load_firmware_
//   from_sd_raw -- these, plus rtl_rx_raw_scratch/rtl_tx_buf_scratch
//   above, are the real contributors to the "baseline" heap usage that
//   let wifi listen 11's per-poll leak tip the board over so much
//   sooner than a clean-heap boot would have.
//
// A further BLE-side tier (l2cap_sig_poll, gatt_server_poll, every
// gatt_discover_*/gatt_client_*/gatt_server_* function, every
// hci_send_command_*, ble_real_connect, ble_scan_for_target) and a
// fourth tier (critical_config_*, the three shell_dispatch_* command
// handlers, the usb_msd_* SCSI commands, dwc2_probe_device0/dwc2_fetch_
// and_set_configuration/dwc2_hub_fetch_port_count, dns_resolve) have
// the SAME one-shot-per-call shape as the MINOR tier above -- found by
// the same audit, reported alongside it, but NOT YET fixed here: BLE's
// call sites are all currently unreachable (zero live callers today,
// confirmed by direct grep -- a real bug the moment something wires
// them into a live poll loop, but not an active leak today), and the
// fourth tier is real but lower-frequency/not tonight's active focus.
icmp_poll_src_mac_scratch_addr:
    .word 0             /* 8 bytes -- icmp_poll's own copy of this
                         * board's MAC (icmp_self_test's two fixed calls
                         * and ping's 8-iteration retry loop both drive
                         * this function repeatedly). */
icmp_poll_echo_payload_scratch_addr:
    .word 0             /* 56 bytes -- icmp_poll's own received-payload
                         * scratch (same function, same reasoning). */
wpa2_eapol_bssid_scratch_addr:
    .word 0             /* 6 bytes -- wpa2_join_step_eapol's own BSSID
                         * copy, WAIT_EAPOL_MSG1 branch only (re-entered
                         * on every genuinely-parsed EAPOL frame seen
                         * while still in that state, including ordinary
                         * Message-1 retransmissions). */
wpa2_eapol_own_mac_scratch_addr:
    .word 0             /* 6 bytes -- same branch, this board's own MAC. */
wpa2_eapol_snonce_scratch_addr:
    .word 0             /* 32 bytes -- same branch, the fresh SNonce
                         * wpa_nonce_generate_heap writes before
                         * processing Message 1. */
wifi_join_password_scratch_addr:
    .word 0             /* 64 bytes -- wifi_real_join's own copy of the
                         * configured WiFi password. One-shot per `wifi
                         * join` call (hoisted above its own loops), not
                         * a per-poll leak, but `wifi join` was run many
                         * times tonight. */
wifi_join_ssid_scratch_addr:
    .word 0             /* 32 bytes -- wifi_real_join's own copy of the
                         * configured SSID. */
wifi_join_pmk_scratch_addr:
    .word 0             /* 32 bytes -- wifi_real_join's own derived PMK. */
wifi_join_ctx_scratch_addr:
    .word 0             /* WPA2_JOIN_CTX_SIZE bytes -- wifi_real_
                         * join's own WPA2 join-state context. */
wifi_join_preq_scratch_addr:
    .word 0             /* 64 bytes -- wifi_real_join's own built Probe
                         * Request frame. */
wifi_join_rx_scratch_addr:
    .word 0             /* 512 bytes -- wifi_real_join's own received-
                         * frame scratch, shared sequentially by its
                         * mgmt-wait and EAPOL-wait loops (never both
                         * live at once -- the mgmt loop fully completes,
                         * success or failure, before the EAPOL loop
                         * ever starts). */
wifi_join_mgmt_scratch_addr:
    .word 0             /* 90 bytes -- wifi_real_join's own built mgmt
                         * (Auth/Assoc Request) frame. */
wifi_join_eapol_rx_scratch_addr:
    .word 0             /* DATA_FRAME_EAPOL_MAX_LEN (224) bytes --
                         * wifi_real_join's own copy of a received
                         * EAPOL frame's payload. */
wifi_join_eapol_tx_scratch_addr:
    .word 0             /* WPA2_JOIN_MSG2_LEN (121) bytes -- wifi_real_
                         * join's own built EAPOL response (Message 2
                         * with RSNE Key Data = 121, Message 4 = 99). */
wifi_join_gtk_scratch_addr:
    .word 0             /* 32 bytes -- wifi_real_join's own decrypted GTK
                         * output. */
wifi_join_wrapped_scratch_addr:
    .word 0             /* 256 bytes -- wifi_real_join's own built,
                         * fully-wrapped outgoing EAPOL data frame. */
wifi_join_bssid_scratch_addr:
    .word 0             /* 6 bytes -- wifi_real_join's own copy of the
                         * joined BSSID, used only in its final connected
                         * -report call. */
wifi_scan_tx_scratch_addr:
    .word 0             /* 64 bytes -- wifi_scan_for_ssid's own built
                         * Probe Request frame. Called once per channel
                         * (1/6/11) from wifi_real_join, each call still
                         * one-shot (hoisted above its own retry loop). */
wifi_scan_rx_scratch_addr:
    .word 0             /* 512 bytes -- wifi_scan_for_ssid's own
                         * received-frame scratch. Not shared with
                         * wifi_join_rx_scratch above even though neither
                         * is ever concurrently live with the other
                         * (wifi_scan_for_ssid fully returns before
                         * wifi_real_join's own loops start) -- kept
                         * separate for the same "a name that says what
                         * actually uses it beats a borrowed one" reason
                         * this whole file already follows elsewhere,
                         * since wifi_scan_for_ssid is also callable on
                         * its own (not just from inside wifi_real_join). */
wifi_listen_rx_scratch_addr:
    .word 0             /* 512 bytes -- wifi_passive_listen's own
                         * received-frame scratch (`wifi listen`, the
                         * RX-only diagnostic command -- not shared with
                         * either WiFi-join scratch above for the same
                         * reason wifi_scan_rx_scratch isn't). */
rtl8188cu_mac_buf_scratch_addr:
    .word 0             /* 6 bytes -- rtl8188cu_mac_bringup's own copy of
                         * the station MAC passed to rtl8188cu_set_mac_
                         * addr. One-shot per radio bring-up, but the
                         * radio gets fully re-initialized on every single
                         * `wifi join`/`wifi listen`/`wifi scan` command. */
rtl8188cu_fw_load_scratch_addr:
    .word 0             /* 512 bytes -- rtl8188cu_load_firmware_from_sd_
                         * raw's own SD-block read scratch. Same "re-run
                         * every WiFi command" reasoning as rtl8188cu_
                         * mac_buf_scratch above. */

/* 2026-11-17 (remote diagnostic instrumentation, "wifi mgmtlog"/"wifi
 * rxstats"): wifi_mgmtlog_record's own ring buffer (16 slots x 32
 * bytes = 512 bytes) and running RX counters. Records EVERY
 * management frame rtl8188cu_rx_frame successfully decodes, before
 * any BSSID/subtype filtering a caller's own join/scan state machine
 * applies afterward -- the whole point is independence from that
 * state machine, so a real Authentication Response arriving but
 * getting filtered out downstream is still visible here. */
wifi_mgmtlog_scratch_addr:
    .word 0             /* 512 bytes, the ring buffer itself */
wifi_mgmtlog_cursor:
    .word 0             /* next slot index to write, 0-15, wraps */
wifi_mgmtlog_total_count:
    .word 0             /* total mgmt frames ever recorded (unwrapped) */
wifi_stat_beacon_count:
    .word 0
wifi_stat_probereq_count:
    .word 0
wifi_stat_proberesp_count:
    .word 0
wifi_stat_auth_count:
    .word 0
wifi_stat_assocresp_count:
    .word 0
wifi_stat_deauth_count:
    .word 0
wifi_stat_disassoc_count:
    .word 0
wifi_stat_other_mgmt_count:
    .word 0
wifi_stat_fcs_bad_count:
    .word 0             /* rtl8188cu_rx_frame's own info.fcs_ok!=1 reject */
wifi_stat_short_frame_count:
    .word 0             /* rtl8188cu_rx_frame's own got<RTL_RXDESC_LEN reject */
wifi_stat_report_frame_count:
    .word 0             /* rtl8188cu_rx_frame's own info.is_report!=0 reject
                         * -- a real, EXPECTED chip-generated report frame,
                         * not a dropped 802.11 frame; counted separately
                         * so it's never mistaken for one. */

/* 2026-11-17 (real-HW incident: a WiFi dongle that stopped answering
 * ANY USB control transfer -- SETUP phase failing on every single
 * subsequent register read/write -- made rtl8188cu_download_firmware's
 * own 3-attempt retry loop grind through dozens of doomed register
 * pokes per attempt (rtl8188cu_power_on/mac_queue_setup/reset_8051's
 * own cleanup sequence, repeated on every attempt), each individually
 * bounded (dwc2_wait_chan0_done's own ~2s cap) but with NO overall
 * circuit breaker once the device is truly gone -- several minutes of
 * real wall-clock time spent reconfirming the same "gone" fact over
 * and over, during which the board looked completely hung. dwc2_
 * control_out/_in (kernel_main.vani) increment this on every SETUP/
 * DATA/STATUS phase failure and reset it to 0 on any success; callers
 * doing a multi-attempt retry (rtl8188cu_download_firmware's own
 * fw_attempt loop) check it between attempts and bail immediately
 * once it's clearly not transient, instead of trusting that "it's
 * only ~2s per call" stays true in aggregate. */
usb_wifi_ctrl_fail_streak:
    .word 0

.section ".text"

.global dharafs_sd_scratch_set
dharafs_sd_scratch_set:
    ldr r1, =dharafs_sd_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_sd_scratch_get
dharafs_sd_scratch_get:
    ldr r0, =dharafs_sd_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sd_wedge_ckpt_scratch_set
sd_wedge_ckpt_scratch_set:
    ldr r1, =sd_wedge_ckpt_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sd_wedge_ckpt_scratch_get
sd_wedge_ckpt_scratch_get:
    ldr r0, =sd_wedge_ckpt_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_path_scratch_set
dharafs_path_scratch_set:
    ldr r1, =dharafs_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_path_scratch_get
dharafs_path_scratch_get:
    ldr r0, =dharafs_path_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_data_scratch_set
dharafs_data_scratch_set:
    ldr r1, =dharafs_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_data_scratch_get
dharafs_data_scratch_get:
    ldr r0, =dharafs_data_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_catchup_buf_set
dharafs_catchup_buf_set:
    ldr r1, =dharafs_catchup_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_catchup_buf_get
dharafs_catchup_buf_get:
    ldr r0, =dharafs_catchup_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_catchup_path_buf_set
dharafs_catchup_path_buf_set:
    ldr r1, =dharafs_catchup_path_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_catchup_path_buf_get
dharafs_catchup_path_buf_get:
    ldr r0, =dharafs_catchup_path_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_catchup_data_buf_set
dharafs_catchup_data_buf_set:
    ldr r1, =dharafs_catchup_data_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_catchup_data_buf_get
dharafs_catchup_data_buf_get:
    ldr r0, =dharafs_catchup_data_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_reclaim_buf_set
dharafs_reclaim_buf_set:
    ldr r1, =dharafs_reclaim_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_reclaim_buf_get
dharafs_reclaim_buf_get:
    ldr r0, =dharafs_reclaim_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_reclaim_path_buf_set
dharafs_reclaim_path_buf_set:
    ldr r1, =dharafs_reclaim_path_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_reclaim_path_buf_get
dharafs_reclaim_path_buf_get:
    ldr r0, =dharafs_reclaim_path_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_reclaim_data_buf_set
dharafs_reclaim_data_buf_set:
    ldr r1, =dharafs_reclaim_data_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_reclaim_data_buf_get
dharafs_reclaim_data_buf_get:
    ldr r0, =dharafs_reclaim_data_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_stat_scratch_set
dharafs_stat_scratch_set:
    ldr r1, =dharafs_stat_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_stat_scratch_get
dharafs_stat_scratch_get:
    ldr r0, =dharafs_stat_scratch_addr
    ldr r0, [r0]
    bx lr

.global dharafs_dir_scratch_set
dharafs_dir_scratch_set:
    ldr r1, =dharafs_dir_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_dir_scratch_get
dharafs_dir_scratch_get:
    ldr r0, =dharafs_dir_scratch_addr
    ldr r0, [r0]
    bx lr

.global shell_line_scratch_set
shell_line_scratch_set:
    ldr r1, =shell_line_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_line_scratch_get
shell_line_scratch_get:
    ldr r0, =shell_line_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global eval_values_scratch_set
eval_values_scratch_set:
    ldr r1, =eval_values_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global eval_values_scratch_get
eval_values_scratch_get:
    ldr r0, =eval_values_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global eval_ops_scratch_set
eval_ops_scratch_set:
    ldr r1, =eval_ops_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global eval_ops_scratch_get
eval_ops_scratch_get:
    ldr r0, =eval_ops_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global uart_digits_scratch_set
uart_digits_scratch_set:
    ldr r1, =uart_digits_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global uart_digits_scratch_get
uart_digits_scratch_get:
    ldr r0, =uart_digits_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dwc2_dma_scratch_set
dwc2_dma_scratch_set:
    ldr r1, =dwc2_dma_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dwc2_dma_scratch_get
dwc2_dma_scratch_get:
    ldr r0, =dwc2_dma_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_downstream_desc_scratch_set
usb_downstream_desc_scratch_set:
    ldr r1, =usb_downstream_desc_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global usb_downstream_desc_scratch_get
usb_downstream_desc_scratch_get:
    ldr r0, =usb_downstream_desc_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global hub_port_status_scratch_set
hub_port_status_scratch_set:
    ldr r1, =hub_port_status_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global hub_port_status_scratch_get
hub_port_status_scratch_get:
    ldr r0, =hub_port_status_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global rtl_lan_reg_scratch_set
rtl_lan_reg_scratch_set:
    ldr r1, =rtl_lan_reg_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_lan_reg_scratch_get
rtl_lan_reg_scratch_get:
    ldr r0, =rtl_lan_reg_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_tx_wrap_scratch_set
netif_tx_wrap_scratch_set:
    ldr r1, =netif_tx_wrap_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_tx_wrap_scratch_get
netif_tx_wrap_scratch_get:
    ldr r0, =netif_tx_wrap_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_tx_chunk_scratch_set
netif_tx_chunk_scratch_set:
    ldr r1, =netif_tx_chunk_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_tx_chunk_scratch_get
netif_tx_chunk_scratch_get:
    ldr r0, =netif_tx_chunk_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_rx_raw_scratch_set
netif_rx_raw_scratch_set:
    ldr r1, =netif_rx_raw_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_rx_raw_scratch_get
netif_rx_raw_scratch_get:
    ldr r0, =netif_rx_raw_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_rx_chunk_scratch_set
netif_rx_chunk_scratch_set:
    ldr r1, =netif_rx_chunk_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_rx_chunk_scratch_get
netif_rx_chunk_scratch_get:
    ldr r0, =netif_rx_chunk_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global tcp_empty_payload_scratch_set
tcp_empty_payload_scratch_set:
    ldr r1, =tcp_empty_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global tcp_empty_payload_scratch_get
tcp_empty_payload_scratch_get:
    ldr r0, =tcp_empty_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global net_send_scratch_set
net_send_scratch_set:
    ldr r1, =net_send_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global net_send_scratch_get
net_send_scratch_get:
    ldr r0, =net_send_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global net_recv_scratch_set
net_recv_scratch_set:
    ldr r1, =net_recv_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global net_recv_scratch_get
net_recv_scratch_get:
    ldr r0, =net_recv_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global udp_send_arp_scratch_set
udp_send_arp_scratch_set:
    ldr r1, =udp_send_arp_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global udp_send_arp_scratch_get
udp_send_arp_scratch_get:
    ldr r0, =udp_send_arp_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global arp_resolve_scratch_set
arp_resolve_scratch_set:
    ldr r1, =arp_resolve_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global arp_resolve_scratch_get
arp_resolve_scratch_get:
    ldr r0, =arp_resolve_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_server_mac_scratch_set
dhcp_server_mac_scratch_set:
    ldr r1, =dhcp_server_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_server_mac_scratch_get
dhcp_server_mac_scratch_get:
    ldr r0, =dhcp_server_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global arp_resolve_mac_scratch_set
arp_resolve_mac_scratch_set:
    ldr r1, =arp_resolve_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global arp_resolve_mac_scratch_get
arp_resolve_mac_scratch_get:
    ldr r0, =arp_resolve_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_arp_autoanswer_sender_mac_scratch_set
netif_arp_autoanswer_sender_mac_scratch_set:
    ldr r1, =netif_arp_autoanswer_sender_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_arp_autoanswer_sender_mac_scratch_get
netif_arp_autoanswer_sender_mac_scratch_get:
    ldr r0, =netif_arp_autoanswer_sender_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_arp_autoanswer_my_mac_scratch_set
netif_arp_autoanswer_my_mac_scratch_set:
    ldr r1, =netif_arp_autoanswer_my_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_arp_autoanswer_my_mac_scratch_get
netif_arp_autoanswer_my_mac_scratch_get:
    ldr r0, =netif_arp_autoanswer_my_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_arp_autoanswer_reply_scratch_set
netif_arp_autoanswer_reply_scratch_set:
    ldr r1, =netif_arp_autoanswer_reply_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global netif_arp_autoanswer_reply_scratch_get
netif_arp_autoanswer_reply_scratch_get:
    ldr r0, =netif_arp_autoanswer_reply_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global tcp_unmatched_rst_peer_mac_scratch_set
tcp_unmatched_rst_peer_mac_scratch_set:
    ldr r1, =tcp_unmatched_rst_peer_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global tcp_unmatched_rst_peer_mac_scratch_get
tcp_unmatched_rst_peer_mac_scratch_get:
    ldr r0, =tcp_unmatched_rst_peer_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dns_query_scratch_set
dns_query_scratch_set:
    ldr r1, =dns_query_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dns_query_scratch_get
dns_query_scratch_get:
    ldr r0, =dns_query_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dns_resp_scratch_set
dns_resp_scratch_set:
    ldr r1, =dns_resp_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dns_resp_scratch_get
dns_resp_scratch_get:
    ldr r0, =dns_resp_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dns_server_mac_scratch_set
dns_server_mac_scratch_set:
    ldr r1, =dns_server_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dns_server_mac_scratch_get
dns_server_mac_scratch_get:
    ldr r0, =dns_server_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernlog_line_scratch_set
kernlog_line_scratch_set:
    ldr r1, =kernlog_line_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global kernlog_line_scratch_get
kernlog_line_scratch_get:
    ldr r0, =kernlog_line_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_hostname_scratch_set
shell_hostname_scratch_set:
    ldr r1, =shell_hostname_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_hostname_scratch_get
shell_hostname_scratch_get:
    ldr r0, =shell_hostname_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_payload_scratch_set
dhcp_payload_scratch_set:
    ldr r1, =dhcp_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_payload_scratch_get
dhcp_payload_scratch_get:
    ldr r0, =dhcp_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_frame_scratch_set
dhcp_frame_scratch_set:
    ldr r1, =dhcp_frame_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_frame_scratch_get
dhcp_frame_scratch_get:
    ldr r0, =dhcp_frame_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_bcast_mac_scratch_set
dhcp_bcast_mac_scratch_set:
    ldr r1, =dhcp_bcast_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_bcast_mac_scratch_get
dhcp_bcast_mac_scratch_get:
    ldr r0, =dhcp_bcast_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_server_client_mac_scratch_set
dhcp_server_client_mac_scratch_set:
    ldr r1, =dhcp_server_client_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_server_client_mac_scratch_get
dhcp_server_client_mac_scratch_get:
    ldr r0, =dhcp_server_client_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_server_payload_scratch_set
dhcp_server_payload_scratch_set:
    ldr r1, =dhcp_server_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_server_payload_scratch_get
dhcp_server_payload_scratch_get:
    ldr r0, =dhcp_server_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dhcp_server_frame_scratch_set
dhcp_server_frame_scratch_set:
    ldr r1, =dhcp_server_frame_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_server_frame_scratch_get
dhcp_server_frame_scratch_get:
    ldr r0, =dhcp_server_frame_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global usb_bulk_data_scratch_set
usb_bulk_data_scratch_set:
    ldr r1, =usb_bulk_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global usb_bulk_data_scratch_get
usb_bulk_data_scratch_get:
    ldr r0, =usb_bulk_data_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_log_path_scratch_set
dharafs_log_path_scratch_set:
    ldr r1, =dharafs_log_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_log_path_scratch_get
dharafs_log_path_scratch_get:
    ldr r0, =dharafs_log_path_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_log_header_path_scratch_set
dharafs_log_header_path_scratch_set:
    ldr r1, =dharafs_log_header_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_log_header_path_scratch_get
dharafs_log_header_path_scratch_get:
    ldr r0, =dharafs_log_header_path_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_log_header_data_scratch_set
dharafs_log_header_data_scratch_set:
    ldr r1, =dharafs_log_header_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_log_header_data_scratch_get
dharafs_log_header_data_scratch_get:
    ldr r0, =dharafs_log_header_data_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_log_existing_scratch_set
dharafs_log_existing_scratch_set:
    ldr r1, =dharafs_log_existing_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_log_existing_scratch_get
dharafs_log_existing_scratch_get:
    ldr r0, =dharafs_log_existing_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_log_combined_scratch_set
dharafs_log_combined_scratch_set:
    ldr r1, =dharafs_log_combined_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_log_combined_scratch_get
dharafs_log_combined_scratch_get:
    ldr r0, =dharafs_log_combined_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_verified_companion_scratch_set
dharafs_verified_companion_scratch_set:
    ldr r1, =dharafs_verified_companion_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_verified_companion_scratch_get
dharafs_verified_companion_scratch_get:
    ldr r0, =dharafs_verified_companion_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_verified_digest_a_scratch_set
dharafs_verified_digest_a_scratch_set:
    ldr r1, =dharafs_verified_digest_a_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_verified_digest_a_scratch_get
dharafs_verified_digest_a_scratch_get:
    ldr r0, =dharafs_verified_digest_a_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_verified_digest_b_scratch_set
dharafs_verified_digest_b_scratch_set:
    ldr r1, =dharafs_verified_digest_b_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_verified_digest_b_scratch_get
dharafs_verified_digest_b_scratch_get:
    ldr r0, =dharafs_verified_digest_b_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_appendonly_check_scratch_set
dharafs_appendonly_check_scratch_set:
    ldr r1, =dharafs_appendonly_check_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_appendonly_check_scratch_get
dharafs_appendonly_check_scratch_get:
    ldr r0, =dharafs_appendonly_check_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_rename_new_path_scratch_set
dharafs_rename_new_path_scratch_set:
    ldr r1, =dharafs_rename_new_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_rename_new_path_scratch_get
dharafs_rename_new_path_scratch_get:
    ldr r0, =dharafs_rename_new_path_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_my_mac_scratch_set
shell_my_mac_scratch_set:
    ldr r1, =shell_my_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_my_mac_scratch_get
shell_my_mac_scratch_get:
    ldr r0, =shell_my_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_ping_dst_mac_scratch_set
shell_ping_dst_mac_scratch_set:
    ldr r1, =shell_ping_dst_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_ping_dst_mac_scratch_get
shell_ping_dst_mac_scratch_get:
    ldr r0, =shell_ping_dst_mac_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_ping_payload_scratch_set
shell_ping_payload_scratch_set:
    ldr r1, =shell_ping_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_ping_payload_scratch_get
shell_ping_payload_scratch_get:
    ldr r0, =shell_ping_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_ping_recv_payload_scratch_set
shell_ping_recv_payload_scratch_set:
    ldr r1, =shell_ping_recv_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_ping_recv_payload_scratch_get
shell_ping_recv_payload_scratch_get:
    ldr r0, =shell_ping_recv_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_ping_recv_meta_scratch_set
shell_ping_recv_meta_scratch_set:
    ldr r1, =shell_ping_recv_meta_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_ping_recv_meta_scratch_get
shell_ping_recv_meta_scratch_get:
    ldr r0, =shell_ping_recv_meta_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_tcpecho_payload_scratch_set
shell_tcpecho_payload_scratch_set:
    ldr r1, =shell_tcpecho_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_tcpecho_payload_scratch_get
shell_tcpecho_payload_scratch_get:
    ldr r0, =shell_tcpecho_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_tcp_poll_scratch_set
shell_tcp_poll_scratch_set:
    ldr r1, =shell_tcp_poll_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_tcp_poll_scratch_get
shell_tcp_poll_scratch_get:
    ldr r0, =shell_tcp_poll_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_tcpecho_recv_payload_scratch_set
shell_tcpecho_recv_payload_scratch_set:
    ldr r1, =shell_tcpecho_recv_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_tcpecho_recv_payload_scratch_get
shell_tcpecho_recv_payload_scratch_get:
    ldr r0, =shell_tcpecho_recv_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_udpecho_payload_scratch_set
shell_udpecho_payload_scratch_set:
    ldr r1, =shell_udpecho_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_udpecho_payload_scratch_get
shell_udpecho_payload_scratch_get:
    ldr r0, =shell_udpecho_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_udpecho_recv_payload_scratch_set
shell_udpecho_recv_payload_scratch_set:
    ldr r1, =shell_udpecho_recv_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_udpecho_recv_payload_scratch_get
shell_udpecho_recv_payload_scratch_get:
    ldr r0, =shell_udpecho_recv_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_udpecho_recv_meta_scratch_set
shell_udpecho_recv_meta_scratch_set:
    ldr r1, =shell_udpecho_recv_meta_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_udpecho_recv_meta_scratch_get
shell_udpecho_recv_meta_scratch_get:
    ldr r0, =shell_udpecho_recv_meta_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_tcprtx_drop_buf_scratch_set
shell_tcprtx_drop_buf_scratch_set:
    ldr r1, =shell_tcprtx_drop_buf_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_tcprtx_drop_buf_scratch_get
shell_tcprtx_drop_buf_scratch_get:
    ldr r0, =shell_tcprtx_drop_buf_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sha256_padded_scratch_set
sha256_padded_scratch_set:
    ldr r1, =sha256_padded_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha256_padded_scratch_get
sha256_padded_scratch_get:
    ldr r0, =sha256_padded_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sha256_h_scratch_set
sha256_h_scratch_set:
    ldr r1, =sha256_h_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha256_h_scratch_get
sha256_h_scratch_get:
    ldr r0, =sha256_h_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sha256_k_scratch_set
sha256_k_scratch_set:
    ldr r1, =sha256_k_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha256_k_scratch_get
sha256_k_scratch_get:
    ldr r0, =sha256_k_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sha256_w_scratch_set
sha256_w_scratch_set:
    ldr r1, =sha256_w_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha256_w_scratch_get
sha256_w_scratch_get:
    ldr r0, =sha256_w_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global gatt_send_scratch_set
gatt_send_scratch_set:
    ldr r1, =gatt_send_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global gatt_send_scratch_get
gatt_send_scratch_get:
    ldr r0, =gatt_send_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global gatt_recv_scratch_set
gatt_recv_scratch_set:
    ldr r1, =gatt_recv_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global gatt_recv_scratch_get
gatt_recv_scratch_get:
    ldr r0, =gatt_recv_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fsqueue_path_scratch_set
fsqueue_path_scratch_set:
    ldr r1, =fsqueue_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global fsqueue_path_scratch_get
fsqueue_path_scratch_get:
    ldr r0, =fsqueue_path_scratch_addr
    ldr r0, [r0]
    bx lr

.global fsqueue_data_scratch_set
fsqueue_data_scratch_set:
    ldr r1, =fsqueue_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global fsqueue_data_scratch_get
fsqueue_data_scratch_get:
    ldr r0, =fsqueue_data_scratch_addr
    ldr r0, [r0]
    bx lr

.global poly1305_block_scratch_set
poly1305_block_scratch_set:
    ldr r1, =poly1305_block_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global poly1305_block_scratch_get
poly1305_block_scratch_get:
    ldr r0, =poly1305_block_scratch_addr
    ldr r0, [r0]
    bx lr

/* u32 ptr_to_u32(mut ref i64 p) -- a pointer and a raw address integer
 * are the identical bits in the same register at the AAPCS level;
 * vani's own type system just has no `as` cast between them (a
 * `mut ref i64 as u32` cast is rejected at compile time). Needed for
 * MMIO registers that take a literal DMA buffer address as a plain
 * value (DWC2's HCDMA(n)) rather than a typed pointer parameter some
 * extern "C" accessor stores on the vani side -- nothing to compute,
 * r0 already holds exactly what's wanted on entry. */
.global sha512_h_scratch_set
sha512_h_scratch_set:
    ldr r1, =sha512_h_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha512_h_scratch_get
sha512_h_scratch_get:
    ldr r0, =sha512_h_scratch_addr
    ldr r0, [r0]
    bx lr

.global sha512_k_scratch_set
sha512_k_scratch_set:
    ldr r1, =sha512_k_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha512_k_scratch_get
sha512_k_scratch_get:
    ldr r0, =sha512_k_scratch_addr
    ldr r0, [r0]
    bx lr

.global sha512_w_scratch_set
sha512_w_scratch_set:
    ldr r1, =sha512_w_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha512_w_scratch_get
sha512_w_scratch_get:
    ldr r0, =sha512_w_scratch_addr
    ldr r0, [r0]
    bx lr

.global sha512_padded_scratch_set
sha512_padded_scratch_set:
    ldr r1, =sha512_padded_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global sha512_padded_scratch_get
sha512_padded_scratch_get:
    ldr r0, =sha512_padded_scratch_addr
    ldr r0, [r0]
    bx lr

.global uart_dma_scratch_set
uart_dma_scratch_set:
    ldr r1, =uart_dma_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global uart_dma_scratch_get
uart_dma_scratch_get:
    ldr r0, =uart_dma_scratch_addr
    ldr r0, [r0]
    bx lr

.global rtl_rx_raw_scratch_set
rtl_rx_raw_scratch_set:
    ldr r1, =rtl_rx_raw_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_rx_raw_scratch_get
rtl_rx_raw_scratch_get:
    ldr r0, =rtl_rx_raw_scratch_addr
    ldr r0, [r0]
    bx lr

.global rtl_rx_bundle_remaining_set
rtl_rx_bundle_remaining_set:
    ldr r1, =rtl_rx_bundle_remaining
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_rx_bundle_remaining_get
rtl_rx_bundle_remaining_get:
    ldr r0, =rtl_rx_bundle_remaining
    ldr r0, [r0]
    bx lr

.global rtl_rx_bundle_offset_set
rtl_rx_bundle_offset_set:
    ldr r1, =rtl_rx_bundle_offset
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_rx_bundle_offset_get
rtl_rx_bundle_offset_get:
    ldr r0, =rtl_rx_bundle_offset
    ldr r0, [r0]
    bx lr

.global rtl_rx_bundle_total_len_set
rtl_rx_bundle_total_len_set:
    ldr r1, =rtl_rx_bundle_total_len
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_rx_bundle_total_len_get
rtl_rx_bundle_total_len_get:
    ldr r0, =rtl_rx_bundle_total_len
    ldr r0, [r0]
    bx lr

.global rtl_rx_chunk_scratch_set
rtl_rx_chunk_scratch_set:
    ldr r1, =rtl_rx_chunk_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_rx_chunk_scratch_get
rtl_rx_chunk_scratch_get:
    ldr r0, =rtl_rx_chunk_scratch_addr
    ldr r0, [r0]
    bx lr

.global rtl_tx_buf_scratch_set
rtl_tx_buf_scratch_set:
    ldr r1, =rtl_tx_buf_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl_tx_buf_scratch_get
rtl_tx_buf_scratch_get:
    ldr r0, =rtl_tx_buf_scratch_addr
    ldr r0, [r0]
    bx lr

.global icmp_poll_src_mac_scratch_set
icmp_poll_src_mac_scratch_set:
    ldr r1, =icmp_poll_src_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global icmp_poll_src_mac_scratch_get
icmp_poll_src_mac_scratch_get:
    ldr r0, =icmp_poll_src_mac_scratch_addr
    ldr r0, [r0]
    bx lr

.global icmp_poll_echo_payload_scratch_set
icmp_poll_echo_payload_scratch_set:
    ldr r1, =icmp_poll_echo_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global icmp_poll_echo_payload_scratch_get
icmp_poll_echo_payload_scratch_get:
    ldr r0, =icmp_poll_echo_payload_scratch_addr
    ldr r0, [r0]
    bx lr

.global wpa2_eapol_bssid_scratch_set
wpa2_eapol_bssid_scratch_set:
    ldr r1, =wpa2_eapol_bssid_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wpa2_eapol_bssid_scratch_get
wpa2_eapol_bssid_scratch_get:
    ldr r0, =wpa2_eapol_bssid_scratch_addr
    ldr r0, [r0]
    bx lr

.global wpa2_eapol_own_mac_scratch_set
wpa2_eapol_own_mac_scratch_set:
    ldr r1, =wpa2_eapol_own_mac_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wpa2_eapol_own_mac_scratch_get
wpa2_eapol_own_mac_scratch_get:
    ldr r0, =wpa2_eapol_own_mac_scratch_addr
    ldr r0, [r0]
    bx lr

.global wpa2_eapol_snonce_scratch_set
wpa2_eapol_snonce_scratch_set:
    ldr r1, =wpa2_eapol_snonce_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wpa2_eapol_snonce_scratch_get
wpa2_eapol_snonce_scratch_get:
    ldr r0, =wpa2_eapol_snonce_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_password_scratch_set
wifi_join_password_scratch_set:
    ldr r1, =wifi_join_password_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_password_scratch_get
wifi_join_password_scratch_get:
    ldr r0, =wifi_join_password_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_ssid_scratch_set
wifi_join_ssid_scratch_set:
    ldr r1, =wifi_join_ssid_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_ssid_scratch_get
wifi_join_ssid_scratch_get:
    ldr r0, =wifi_join_ssid_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_pmk_scratch_set
wifi_join_pmk_scratch_set:
    ldr r1, =wifi_join_pmk_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_pmk_scratch_get
wifi_join_pmk_scratch_get:
    ldr r0, =wifi_join_pmk_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_ctx_scratch_set
wifi_join_ctx_scratch_set:
    ldr r1, =wifi_join_ctx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_ctx_scratch_get
wifi_join_ctx_scratch_get:
    ldr r0, =wifi_join_ctx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_preq_scratch_set
wifi_join_preq_scratch_set:
    ldr r1, =wifi_join_preq_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_preq_scratch_get
wifi_join_preq_scratch_get:
    ldr r0, =wifi_join_preq_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_rx_scratch_set
wifi_join_rx_scratch_set:
    ldr r1, =wifi_join_rx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_rx_scratch_get
wifi_join_rx_scratch_get:
    ldr r0, =wifi_join_rx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_mgmt_scratch_set
wifi_join_mgmt_scratch_set:
    ldr r1, =wifi_join_mgmt_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_mgmt_scratch_get
wifi_join_mgmt_scratch_get:
    ldr r0, =wifi_join_mgmt_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_eapol_rx_scratch_set
wifi_join_eapol_rx_scratch_set:
    ldr r1, =wifi_join_eapol_rx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_eapol_rx_scratch_get
wifi_join_eapol_rx_scratch_get:
    ldr r0, =wifi_join_eapol_rx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_eapol_tx_scratch_set
wifi_join_eapol_tx_scratch_set:
    ldr r1, =wifi_join_eapol_tx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_eapol_tx_scratch_get
wifi_join_eapol_tx_scratch_get:
    ldr r0, =wifi_join_eapol_tx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_gtk_scratch_set
wifi_join_gtk_scratch_set:
    ldr r1, =wifi_join_gtk_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_gtk_scratch_get
wifi_join_gtk_scratch_get:
    ldr r0, =wifi_join_gtk_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_wrapped_scratch_set
wifi_join_wrapped_scratch_set:
    ldr r1, =wifi_join_wrapped_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_wrapped_scratch_get
wifi_join_wrapped_scratch_get:
    ldr r0, =wifi_join_wrapped_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_join_bssid_scratch_set
wifi_join_bssid_scratch_set:
    ldr r1, =wifi_join_bssid_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_join_bssid_scratch_get
wifi_join_bssid_scratch_get:
    ldr r0, =wifi_join_bssid_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_scan_tx_scratch_set
wifi_scan_tx_scratch_set:
    ldr r1, =wifi_scan_tx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_scan_tx_scratch_get
wifi_scan_tx_scratch_get:
    ldr r0, =wifi_scan_tx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_scan_rx_scratch_set
wifi_scan_rx_scratch_set:
    ldr r1, =wifi_scan_rx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_scan_rx_scratch_get
wifi_scan_rx_scratch_get:
    ldr r0, =wifi_scan_rx_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_listen_rx_scratch_set
wifi_listen_rx_scratch_set:
    ldr r1, =wifi_listen_rx_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_listen_rx_scratch_get
wifi_listen_rx_scratch_get:
    ldr r0, =wifi_listen_rx_scratch_addr
    ldr r0, [r0]
    bx lr

.global rtl8188cu_mac_buf_scratch_set
rtl8188cu_mac_buf_scratch_set:
    ldr r1, =rtl8188cu_mac_buf_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl8188cu_mac_buf_scratch_get
rtl8188cu_mac_buf_scratch_get:
    ldr r0, =rtl8188cu_mac_buf_scratch_addr
    ldr r0, [r0]
    bx lr

.global rtl8188cu_fw_load_scratch_set
rtl8188cu_fw_load_scratch_set:
    ldr r1, =rtl8188cu_fw_load_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global rtl8188cu_fw_load_scratch_get
rtl8188cu_fw_load_scratch_get:
    ldr r0, =rtl8188cu_fw_load_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_mgmtlog_scratch_set
wifi_mgmtlog_scratch_set:
    ldr r1, =wifi_mgmtlog_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_mgmtlog_scratch_get
wifi_mgmtlog_scratch_get:
    ldr r0, =wifi_mgmtlog_scratch_addr
    ldr r0, [r0]
    bx lr

.global wifi_mgmtlog_cursor_set
wifi_mgmtlog_cursor_set:
    ldr r1, =wifi_mgmtlog_cursor
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_mgmtlog_cursor_get
wifi_mgmtlog_cursor_get:
    ldr r0, =wifi_mgmtlog_cursor
    ldr r0, [r0]
    bx lr

.global wifi_mgmtlog_total_count_set
wifi_mgmtlog_total_count_set:
    ldr r1, =wifi_mgmtlog_total_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_mgmtlog_total_count_get
wifi_mgmtlog_total_count_get:
    ldr r0, =wifi_mgmtlog_total_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_beacon_count_set
wifi_stat_beacon_count_set:
    ldr r1, =wifi_stat_beacon_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_beacon_count_get
wifi_stat_beacon_count_get:
    ldr r0, =wifi_stat_beacon_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_probereq_count_set
wifi_stat_probereq_count_set:
    ldr r1, =wifi_stat_probereq_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_probereq_count_get
wifi_stat_probereq_count_get:
    ldr r0, =wifi_stat_probereq_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_proberesp_count_set
wifi_stat_proberesp_count_set:
    ldr r1, =wifi_stat_proberesp_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_proberesp_count_get
wifi_stat_proberesp_count_get:
    ldr r0, =wifi_stat_proberesp_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_auth_count_set
wifi_stat_auth_count_set:
    ldr r1, =wifi_stat_auth_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_auth_count_get
wifi_stat_auth_count_get:
    ldr r0, =wifi_stat_auth_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_assocresp_count_set
wifi_stat_assocresp_count_set:
    ldr r1, =wifi_stat_assocresp_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_assocresp_count_get
wifi_stat_assocresp_count_get:
    ldr r0, =wifi_stat_assocresp_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_deauth_count_set
wifi_stat_deauth_count_set:
    ldr r1, =wifi_stat_deauth_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_deauth_count_get
wifi_stat_deauth_count_get:
    ldr r0, =wifi_stat_deauth_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_disassoc_count_set
wifi_stat_disassoc_count_set:
    ldr r1, =wifi_stat_disassoc_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_disassoc_count_get
wifi_stat_disassoc_count_get:
    ldr r0, =wifi_stat_disassoc_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_other_mgmt_count_set
wifi_stat_other_mgmt_count_set:
    ldr r1, =wifi_stat_other_mgmt_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_other_mgmt_count_get
wifi_stat_other_mgmt_count_get:
    ldr r0, =wifi_stat_other_mgmt_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_fcs_bad_count_set
wifi_stat_fcs_bad_count_set:
    ldr r1, =wifi_stat_fcs_bad_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_fcs_bad_count_get
wifi_stat_fcs_bad_count_get:
    ldr r0, =wifi_stat_fcs_bad_count
    ldr r0, [r0]
    bx lr

.global usb_wifi_ctrl_fail_streak_set
usb_wifi_ctrl_fail_streak_set:
    ldr r1, =usb_wifi_ctrl_fail_streak
    str r0, [r1]
    mov r0, #0
    bx lr

.global usb_wifi_ctrl_fail_streak_get
usb_wifi_ctrl_fail_streak_get:
    ldr r0, =usb_wifi_ctrl_fail_streak
    ldr r0, [r0]
    bx lr

.global wifi_stat_short_frame_count_set
wifi_stat_short_frame_count_set:
    ldr r1, =wifi_stat_short_frame_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_short_frame_count_get
wifi_stat_short_frame_count_get:
    ldr r0, =wifi_stat_short_frame_count
    ldr r0, [r0]
    bx lr

.global wifi_stat_report_frame_count_set
wifi_stat_report_frame_count_set:
    ldr r1, =wifi_stat_report_frame_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global wifi_stat_report_frame_count_get
wifi_stat_report_frame_count_get:
    ldr r0, =wifi_stat_report_frame_count
    ldr r0, [r0]
    bx lr

.global ptr_to_u32
ptr_to_u32:
    bx lr
