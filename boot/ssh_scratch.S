/* Dhruva -- persistent scratch buffers for a scoped-down SSH-2.0
 * server (RFC 4251-4254): curve25519-sha256 KEX only, ssh-ed25519 host
 * key only, chacha20-poly1305@openssh.com cipher only (both
 * directions -- no separate MAC), publickey userauth only. Built
 * entirely on the shared vani-ssh kosh package (protocol/crypto math)
 * plus primitives already implemented elsewhere in this codebase
 * (SHA-256, X25519, Ed25519) -- this file only adds SSH-specific
 * session state (handshake buffers, derived keys, rx accumulators,
 * per-role sequence numbers/phase).
 *
 * Same allocate-once-at-boot, named-buffer discipline as
 * tls13_scratch.S. Both "client" and "server" fields exist because
 * the round-180 verification loop runs both SSH roles in one process
 * over a real loopback TCP connection, mirroring tls13_scratch.S's
 * own tls_client_.../tls_server_... split (see kernel_main.vani's
 * ssh_run_self_test and its phase helpers). */

.section ".bss"
.align 4
ssh_v_c_addr:                   .word 0
ssh_v_s_addr:                   .word 0
ssh_v_c_len_addr:               .word 0
ssh_v_s_len_addr:               .word 0
ssh_client_kexinit_addr:        .word 0
ssh_client_kexinit_len_addr:    .word 0
ssh_server_kexinit_addr:        .word 0
ssh_server_kexinit_len_addr:    .word 0
ssh_cookie16_addr:              .word 0
ssh_client_x25519_priv_addr:    .word 0
ssh_client_x25519_pub_addr:     .word 0
ssh_server_x25519_priv_addr:    .word 0
ssh_server_x25519_pub_addr:     .word 0
ssh_shared_secret_addr:         .word 0
ssh_host_priv_addr:             .word 0
ssh_host_pub_addr:              .word 0
ssh_client_id_priv_addr:        .word 0
ssh_client_id_pub_addr:         .word 0
ssh_exchange_hash_addr:         .word 0
ssh_session_id_addr:            .word 0
ssh_c2s_key64_addr:             .word 0
ssh_s2c_key64_addr:             .word 0
ssh_hostkey_blob_addr:          .word 0
ssh_sigblob_addr:               .word 0
ssh_client_keyblob_addr:        .word 0
ssh_client_sigblob_addr:        .word 0
ssh_userauth_signed_data_addr:  .word 0
ssh_payload_buf_addr:           .word 0
ssh_payload_buf2_addr:          .word 0
ssh_packet_buf_addr:            .word 0
ssh_packet_buf2_addr:           .word 0
ssh_decrypted_scratch_addr:     .word 0
ssh_client_rx_buf_addr:         .word 0
ssh_client_rx_len_addr:         .word 0
ssh_server_rx_buf_addr:         .word 0
ssh_server_rx_len_addr:         .word 0
ssh_frame_scratch_addr:         .word 0
ssh_chunk_scratch_addr:         .word 0
ssh_recv_chunk_scratch_addr:    .word 0
ssh_ack_scratch_addr:           .word 0
ssh_client_seq_out_addr:        .word 0
ssh_client_seq_in_addr:         .word 0
ssh_server_seq_out_addr:        .word 0
ssh_server_seq_in_addr:         .word 0
ssh_client_phase_addr:          .word 0
ssh_server_phase_addr:          .word 0
ssh_exec_cmd_addr:              .word 0
ssh_channel_data_buf_addr:      .word 0
ssh_dst_mac_addr:               .word 0

.section ".text"

.macro SSH_SCRATCH_PAIR name
.global \name\()_set
\name\()_set:
    ldr r1, =\name\()_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global \name\()_get
\name\()_get:
    ldr r0, =\name\()_addr
    ldr r0, [r0]
    bx lr
.endm

SSH_SCRATCH_PAIR ssh_v_c
SSH_SCRATCH_PAIR ssh_v_s
SSH_SCRATCH_PAIR ssh_v_c_len
SSH_SCRATCH_PAIR ssh_v_s_len
SSH_SCRATCH_PAIR ssh_client_kexinit
SSH_SCRATCH_PAIR ssh_client_kexinit_len
SSH_SCRATCH_PAIR ssh_server_kexinit
SSH_SCRATCH_PAIR ssh_server_kexinit_len
SSH_SCRATCH_PAIR ssh_cookie16
SSH_SCRATCH_PAIR ssh_client_x25519_priv
SSH_SCRATCH_PAIR ssh_client_x25519_pub
SSH_SCRATCH_PAIR ssh_server_x25519_priv
SSH_SCRATCH_PAIR ssh_server_x25519_pub
SSH_SCRATCH_PAIR ssh_shared_secret
SSH_SCRATCH_PAIR ssh_host_priv
SSH_SCRATCH_PAIR ssh_host_pub
SSH_SCRATCH_PAIR ssh_client_id_priv
SSH_SCRATCH_PAIR ssh_client_id_pub
SSH_SCRATCH_PAIR ssh_exchange_hash
SSH_SCRATCH_PAIR ssh_session_id
SSH_SCRATCH_PAIR ssh_c2s_key64
SSH_SCRATCH_PAIR ssh_s2c_key64
SSH_SCRATCH_PAIR ssh_hostkey_blob
SSH_SCRATCH_PAIR ssh_sigblob
SSH_SCRATCH_PAIR ssh_client_keyblob
SSH_SCRATCH_PAIR ssh_client_sigblob
SSH_SCRATCH_PAIR ssh_userauth_signed_data
SSH_SCRATCH_PAIR ssh_payload_buf
SSH_SCRATCH_PAIR ssh_payload_buf2
SSH_SCRATCH_PAIR ssh_packet_buf
SSH_SCRATCH_PAIR ssh_packet_buf2
SSH_SCRATCH_PAIR ssh_decrypted_scratch
SSH_SCRATCH_PAIR ssh_client_rx_buf
SSH_SCRATCH_PAIR ssh_client_rx_len
SSH_SCRATCH_PAIR ssh_server_rx_buf
SSH_SCRATCH_PAIR ssh_server_rx_len
SSH_SCRATCH_PAIR ssh_frame_scratch
SSH_SCRATCH_PAIR ssh_chunk_scratch
SSH_SCRATCH_PAIR ssh_recv_chunk_scratch
SSH_SCRATCH_PAIR ssh_ack_scratch
SSH_SCRATCH_PAIR ssh_client_seq_out
SSH_SCRATCH_PAIR ssh_client_seq_in
SSH_SCRATCH_PAIR ssh_server_seq_out
SSH_SCRATCH_PAIR ssh_server_seq_in
SSH_SCRATCH_PAIR ssh_client_phase
SSH_SCRATCH_PAIR ssh_server_phase
SSH_SCRATCH_PAIR ssh_exec_cmd
SSH_SCRATCH_PAIR ssh_channel_data_buf
SSH_SCRATCH_PAIR ssh_dst_mac
