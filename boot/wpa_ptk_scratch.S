/* Dhruva -- persistent scratch for WPA2 PTK derivation (task #164
 * WPA2-PSK groundwork: IEEE 802.11i 8.5.1.1's PRF-X, and 8.5.1.2's
 * PMK->PTK derivation built on it). Same "persistent, never per-call
 * dhruva_alloc_bytes" discipline as every other frequently-called
 * crypto primitive in this project.
 *
 * prf_msg (128 bytes): PRF-X's own per-iteration HMAC-SHA1 input --
 * label (<=32 bytes) + a 1-byte NUL terminator + data (76 bytes for
 * PTK derivation's own A1||A2||N1||N2 shape) + a 1-byte counter, worst
 * case 110 bytes, sized with real margin for a same-shaped GTK
 * derivation later (a shorter "Group key expansion" label, same data
 * shape) without needing a second buffer.
 * prf_hash (20 bytes): one PRF-X iteration's own raw HMAC-SHA1 output,
 * before being copied (whole or truncated, for the final short block)
 * into the caller's real output buffer.
 * ptk_data (76 bytes): PTK derivation's own canonicalized
 * Min(A1,A2)||Max(A1,A2)||Min(N1,N2)||Max(N1,N2) (6+6+32+32).
 * ptk_label (32 bytes): the PRF-X label string, written fresh by each
 * caller (wpa_ptk_derive writes "Pairwise key expansion" here) rather
 * than living in read-only Str storage -- this project's own strings
 * live as ASCII literals copied through `buf_write_byte`, not a
 * separate string-table mechanism.
 * ptk_tmp (48 bytes): PRF-X's own raw 48-byte output for CCMP (16-byte
 * KCK + 16-byte KEK + 16-byte TK), before being split into the
 * caller's three separate output buffers. */

.section ".bss"
.align 4
wpa_prf_msg_scratch:
    .space 128
wpa_prf_hash_scratch:
    .space 20
wpa_ptk_data_scratch:
    .space 76
wpa_ptk_label_scratch:
    .space 32
wpa_ptk_tmp_scratch:
    .space 48

.section ".text"

.global wpa_prf_msg_ptr
wpa_prf_msg_ptr:
    ldr r0, =wpa_prf_msg_scratch
    bx lr

.global wpa_prf_hash_ptr
wpa_prf_hash_ptr:
    ldr r0, =wpa_prf_hash_scratch
    bx lr

.global wpa_ptk_data_ptr
wpa_ptk_data_ptr:
    ldr r0, =wpa_ptk_data_scratch
    bx lr

.global wpa_ptk_label_ptr
wpa_ptk_label_ptr:
    ldr r0, =wpa_ptk_label_scratch
    bx lr

.global wpa_ptk_tmp_ptr
wpa_ptk_tmp_ptr:
    ldr r0, =wpa_ptk_tmp_scratch
    bx lr
