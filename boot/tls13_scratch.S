/* Dhruva -- persistent scratch buffers for a scoped-down TLS 1.3
 * (RFC 8446) handshake + record layer: TLS_CHACHA20_POLY1305_SHA256
 * cipher suite only, x25519 key exchange only, ed25519 signatures
 * only, RFC 7250 raw public keys (server-authenticated only, no
 * client cert, no session resumption/PSK/0-RTT). Built entirely on
 * primitives already implemented elsewhere in this codebase (SHA-256,
 * HMAC-SHA256, HKDF, X25519, Ed25519, ChaCha20-Poly1305 AEAD) -- this
 * file only adds TLS-specific state (handshake secrets, message
 * scratch, transcript buffer, record layer scratch). AEAD's own
 * internal scratch (aead_state/aead_working/... in
 * media_crypto_state.S) and HKDF's own (hkdf_t_scratch/
 * hkdf_hmac_input_scratch) are reused directly, not duplicated here.
 *
 * Same allocate-once-at-boot, named-buffer discipline as every other
 * scratch file in this project. */

.section ".bss"
.align 4
tls_client_random_addr:        .word 0
tls_server_random_addr:        .word 0
tls_client_x25519_priv_addr:   .word 0
tls_client_x25519_pub_addr:    .word 0
tls_server_x25519_priv_addr:   .word 0
tls_server_x25519_pub_addr:    .word 0
tls_shared_secret_addr:        .word 0
tls_server_id_priv_addr:       .word 0
tls_server_id_pub_addr:        .word 0
tls_early_secret_addr:         .word 0
tls_derived_es_addr:           .word 0
tls_handshake_secret_addr:     .word 0
tls_c_hs_traffic_addr:         .word 0
tls_s_hs_traffic_addr:         .word 0
tls_c_hs_key_addr:             .word 0
tls_c_hs_iv_addr:              .word 0
tls_s_hs_key_addr:             .word 0
tls_s_hs_iv_addr:              .word 0
tls_derived_hs_addr:           .word 0
tls_master_secret_addr:        .word 0
tls_c_ap_traffic_addr:         .word 0
tls_s_ap_traffic_addr:         .word 0
tls_c_ap_key_addr:             .word 0
tls_c_ap_iv_addr:              .word 0
tls_s_ap_key_addr:             .word 0
tls_s_ap_iv_addr:              .word 0
tls_transcript_addr:           .word 0
tls_ch_addr:                   .word 0
tls_sh_addr:                   .word 0
tls_ee_addr:                   .word 0
tls_cert_addr:                 .word 0
tls_cv_addr:                   .word 0
tls_s_fin_addr:                .word 0
tls_c_fin_addr:                .word 0
tls_hash_scratch_addr:         .word 0
tls_hkdf_label_scratch_addr:   .word 0
tls_cv_signed_content_addr:    .word 0
tls_finished_key_scratch_addr: .word 0
tls_record_scratch_addr:       .word 0
tls_record_aad_addr:           .word 0
tls_record_nonce_addr:         .word 0
tls_content_scratch_addr:      .word 0
tls_tag_in_addr:               .word 0
tls_rec_buf_addr:              .word 0
tls_client_msg_addr:           .word 0
tls_server_reply_addr:         .word 0
tls_decrypted_scratch_addr:    .word 0
tls_client_rx_buf_addr:        .word 0
tls_client_rx_len_addr:        .word 0
tls_server_rx_buf_addr:        .word 0
tls_server_rx_len_addr:        .word 0
tls_frame_scratch_addr:        .word 0
tls_chunk_scratch_addr:        .word 0
tls_recv_chunk_scratch_addr:   .word 0
tls_ack_scratch_addr:          .word 0
tls_ch_record_addr:            .word 0
tls_sh_record_addr:            .word 0
tls_parsed_client_random_addr: .word 0
tls_parsed_client_pub_addr:    .word 0
tls_parsed_server_random_addr: .word 0
tls_parsed_server_pub_addr:    .word 0
tls_flight_combined_addr:      .word 0
tls_parsed_server_id_pub_addr: .word 0

.section ".text"

.macro TLS_SCRATCH_PAIR name
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

TLS_SCRATCH_PAIR tls_client_random
TLS_SCRATCH_PAIR tls_server_random
TLS_SCRATCH_PAIR tls_client_x25519_priv
TLS_SCRATCH_PAIR tls_client_x25519_pub
TLS_SCRATCH_PAIR tls_server_x25519_priv
TLS_SCRATCH_PAIR tls_server_x25519_pub
TLS_SCRATCH_PAIR tls_shared_secret
TLS_SCRATCH_PAIR tls_server_id_priv
TLS_SCRATCH_PAIR tls_server_id_pub
TLS_SCRATCH_PAIR tls_early_secret
TLS_SCRATCH_PAIR tls_derived_es
TLS_SCRATCH_PAIR tls_handshake_secret
TLS_SCRATCH_PAIR tls_c_hs_traffic
TLS_SCRATCH_PAIR tls_s_hs_traffic
TLS_SCRATCH_PAIR tls_c_hs_key
TLS_SCRATCH_PAIR tls_c_hs_iv
TLS_SCRATCH_PAIR tls_s_hs_key
TLS_SCRATCH_PAIR tls_s_hs_iv
TLS_SCRATCH_PAIR tls_derived_hs
TLS_SCRATCH_PAIR tls_master_secret
TLS_SCRATCH_PAIR tls_c_ap_traffic
TLS_SCRATCH_PAIR tls_s_ap_traffic
TLS_SCRATCH_PAIR tls_c_ap_key
TLS_SCRATCH_PAIR tls_c_ap_iv
TLS_SCRATCH_PAIR tls_s_ap_key
TLS_SCRATCH_PAIR tls_s_ap_iv
TLS_SCRATCH_PAIR tls_transcript
TLS_SCRATCH_PAIR tls_ch
TLS_SCRATCH_PAIR tls_sh
TLS_SCRATCH_PAIR tls_ee
TLS_SCRATCH_PAIR tls_cert
TLS_SCRATCH_PAIR tls_cv
TLS_SCRATCH_PAIR tls_s_fin
TLS_SCRATCH_PAIR tls_c_fin
TLS_SCRATCH_PAIR tls_hash_scratch
TLS_SCRATCH_PAIR tls_hkdf_label_scratch
TLS_SCRATCH_PAIR tls_cv_signed_content
TLS_SCRATCH_PAIR tls_finished_key_scratch
TLS_SCRATCH_PAIR tls_record_scratch
TLS_SCRATCH_PAIR tls_record_aad
TLS_SCRATCH_PAIR tls_record_nonce
TLS_SCRATCH_PAIR tls_content_scratch
TLS_SCRATCH_PAIR tls_tag_in
TLS_SCRATCH_PAIR tls_rec_buf
TLS_SCRATCH_PAIR tls_client_msg
TLS_SCRATCH_PAIR tls_server_reply
TLS_SCRATCH_PAIR tls_decrypted_scratch
TLS_SCRATCH_PAIR tls_client_rx_buf
TLS_SCRATCH_PAIR tls_client_rx_len
TLS_SCRATCH_PAIR tls_server_rx_buf
TLS_SCRATCH_PAIR tls_server_rx_len
TLS_SCRATCH_PAIR tls_frame_scratch
TLS_SCRATCH_PAIR tls_chunk_scratch
TLS_SCRATCH_PAIR tls_recv_chunk_scratch
TLS_SCRATCH_PAIR tls_ack_scratch
TLS_SCRATCH_PAIR tls_ch_record
TLS_SCRATCH_PAIR tls_sh_record
TLS_SCRATCH_PAIR tls_parsed_client_random
TLS_SCRATCH_PAIR tls_parsed_client_pub
TLS_SCRATCH_PAIR tls_parsed_server_random
TLS_SCRATCH_PAIR tls_parsed_server_pub
TLS_SCRATCH_PAIR tls_flight_combined
TLS_SCRATCH_PAIR tls_parsed_server_id_pub
