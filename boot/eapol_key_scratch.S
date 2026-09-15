/* Dhruva -- persistent scratch for EAPOL-Key frame handling (task #164
 * WPA2-PSK groundwork: the 4-way handshake's own wire format). Same
 * "persistent, never per-call dhruva_alloc_bytes" discipline as every
 * other frequently-called crypto/protocol primitive in this project.
 *
 * saved_mic (16 bytes): eapol_key_verify_mic's own scratch for the
 * received MIC bytes while they're temporarily zeroed out of the
 * frame buffer for recomputation (the EAPOL-Key MIC field must read as
 * all-zero during its own computation, then the real received value
 * is restored so the caller's buffer isn't left corrupted).
 * full_mic (20 bytes): hmac_sha1's own full-width digest, before
 * truncating to the 16-byte EAPOL-Key MIC width (HMAC-SHA1-128, per
 * IEEE 802.11i for CCMP/WPA2-PSK -- not the 24-byte HMAC-SHA384
 * variant Suite-B/WPA3-Enterprise uses, out of scope here). */

.section ".bss"
.align 4
eapol_key_saved_mic:
    .space 16
eapol_key_full_mic:
    .space 20

.section ".text"

.global eapol_key_saved_mic_ptr
eapol_key_saved_mic_ptr:
    ldr r0, =eapol_key_saved_mic
    bx lr

.global eapol_key_full_mic_ptr
eapol_key_full_mic_ptr:
    ldr r0, =eapol_key_full_mic
    bx lr
