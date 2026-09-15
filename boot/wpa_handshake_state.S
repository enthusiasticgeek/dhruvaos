/* Dhruva -- persistent scratch for the WPA2 4-way handshake's own
 * message-sequencing state machine (task #164 groundwork). Same
 * "persistent, never per-call dhruva_alloc_bytes" discipline as every
 * other frequently-called protocol primitive in this project -- a
 * real handshake attempt calls these functions exactly once each per
 * session, but the STATE (PTK, replay counter) has to persist across
 * those calls, which is exactly what per-call heap allocation cannot
 * do without the caller separately threading pointers through every
 * call -- this project's own established alternative.
 *
 * aa/sa (6 bytes each): the AP's and this station's own MAC addresses,
 * set once at handshake start via wpa_hs_init.
 * pmk (32 bytes): the pre-shared-key-derived PMK, also set once.
 * anonce_scratch (32 bytes): a temporary copy of Message 1's own
 * ANonce field -- wpa_ptk_derive takes raw buffer pointers assumed to
 * start AT the nonce, so this copies it out of the received frame
 * buffer (at whatever offset EAPOL_KEY_NONCE_OFF puts it) before
 * calling that function; doesn't need to persist past
 * wpa_hs_process_msg1's own call, but persistent scratch is this
 * project's own established default regardless.
 * kck/kek/tk (16 bytes each): the derived PTK's three components,
 * persisting from wpa_hs_process_msg1 through wpa_hs_process_msg3
 * (KCK for MIC verify/set on both Message 3 and Message 4; KEK and TK
 * are stored for the CALLER's own eventual use -- installing TK as the
 * real CCMP key, KEK for the still-unimplemented GTK key-unwrap -- not
 * consumed by this file's own logic yet).
 * replay_counter (8 bytes): the last-seen EAPOL-Key replay counter --
 * Message 1's own value initially (echoed unchanged in Message 2, per
 * spec), then Message 3's own (newer) value once that arrives (echoed
 * unchanged in Message 4).
 * gtk_scratch (32 bytes): the GTK bytes extracted from Message 3's own
 * (unencrypted) Key Data, sized generously beyond CCMP's real 16-byte
 * GTK for headroom.
 * decrypted_kd_scratch (64 bytes): Message 3's own Key Data field,
 * AES-key-unwrapped (RFC 3394, via the vani-aes kosh package) when
 * EAPOL_KEY_INFO_ENCR_KEY_DATA is set -- a real access point always
 * sets it in practice. wpa_gtk_kde_extract parses THIS buffer (not the
 * raw frame) once unwrap succeeds, since the unwrapped plaintext is
 * byte-for-byte the same unencrypted-Key-Data KDE format that function
 * already handles. Sized to match aes_key_unwrap_heap's own
 * AES_KW_MAX_BLOCKS=8 bound (64 bytes plaintext, i.e. ciphertext up to
 * 72 bytes wrapped) -- comfortably beyond any real GTK/IGTK KDE. */

.section ".bss"
.align 4
wpa_hs_aa:
    .space 6
wpa_hs_sa:
    .space 6
wpa_hs_pmk:
    .space 32
wpa_hs_anonce_scratch:
    .space 32
wpa_hs_kck:
    .space 16
wpa_hs_kek:
    .space 16
wpa_hs_tk:
    .space 16
wpa_hs_replay_counter:
    .space 8
wpa_hs_gtk_scratch:
    .space 32
wpa_hs_decrypted_kd_scratch:
    .space 64

.section ".text"

.global wpa_hs_aa_ptr
wpa_hs_aa_ptr:
    ldr r0, =wpa_hs_aa
    bx lr

.global wpa_hs_sa_ptr
wpa_hs_sa_ptr:
    ldr r0, =wpa_hs_sa
    bx lr

.global wpa_hs_pmk_ptr
wpa_hs_pmk_ptr:
    ldr r0, =wpa_hs_pmk
    bx lr

.global wpa_hs_anonce_scratch_ptr
wpa_hs_anonce_scratch_ptr:
    ldr r0, =wpa_hs_anonce_scratch
    bx lr

.global wpa_hs_kck_ptr
wpa_hs_kck_ptr:
    ldr r0, =wpa_hs_kck
    bx lr

.global wpa_hs_kek_ptr
wpa_hs_kek_ptr:
    ldr r0, =wpa_hs_kek
    bx lr

.global wpa_hs_tk_ptr
wpa_hs_tk_ptr:
    ldr r0, =wpa_hs_tk
    bx lr

.global wpa_hs_replay_counter_ptr
wpa_hs_replay_counter_ptr:
    ldr r0, =wpa_hs_replay_counter
    bx lr

.global wpa_hs_gtk_scratch_ptr
wpa_hs_gtk_scratch_ptr:
    ldr r0, =wpa_hs_gtk_scratch
    bx lr

.global wpa_hs_decrypted_kd_scratch_ptr
wpa_hs_decrypted_kd_scratch_ptr:
    ldr r0, =wpa_hs_decrypted_kd_scratch
    bx lr
