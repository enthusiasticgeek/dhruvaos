/* Dhruva -- PKI raw public-key trust (round 67).
 *
 * "Pin a known key, verify a signature against it directly" -- the
 * smallest real PKI increment per docs/TODO.md's own scoping note,
 * deliberately no X.509/ASN.1/CA-chain machinery at all (a separate,
 * much larger future step if ever started). The pinned key is a
 * COMPILE-TIME CONSTANT (pki_init, kernel_main.vani), never runtime-
 * settable through the shell or any other API -- a "trust anchor"
 * that could be repinned by whoever happens to have shell access
 * would defeat the entire point (an attacker could just pin their
 * own key and every signature check would trivially pass). Real
 * provisioning of a different key means rebuilding the image, the
 * same posture this project's own "smaller substitute for secure
 * boot" framing already calls for.
 *
 * Same one-allocation-at-boot scratch discipline as every other
 * primitive in this file. pki_verify_file_raw reuses the EXISTING
 * dharafs_path_scratch/dharafs_data_scratch (already safe to share --
 * see scratch_state.S's own header comment -- and exactly what
 * `cat`/`catv`'s own shell handlers already do) for the target file's
 * own path/content; only the SIGNATURE's own path and content need
 * dedicated buffers here, since both the file and its companion
 * <path>.sig are read in the same call. */

.section ".bss"
.align 4
pki_pinned_key_addr:
    .word 0             /* 32 bytes: the pinned Ed25519 public key. */
pki_sig_path_scratch_addr:
    .word 0             /* 40 bytes: <path>.sig, up to 32+4 bytes plus
                         * margin. */
pki_sig_data_scratch_addr:
    .word 0             /* 64 bytes: the companion signature file's
                         * own content (always exactly 64 bytes for a
                         * well-formed signature; a differently-sized
                         * file at that path is rejected as invalid). */

.section ".text"

.global pki_pinned_key_set
pki_pinned_key_set:
    ldr r1, =pki_pinned_key_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global pki_pinned_key_get
pki_pinned_key_get:
    ldr r0, =pki_pinned_key_addr
    ldr r0, [r0]
    bx lr

.global pki_sig_path_scratch_set
pki_sig_path_scratch_set:
    ldr r1, =pki_sig_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global pki_sig_path_scratch_get
pki_sig_path_scratch_get:
    ldr r0, =pki_sig_path_scratch_addr
    ldr r0, [r0]
    bx lr

.global pki_sig_data_scratch_set
pki_sig_data_scratch_set:
    ldr r1, =pki_sig_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global pki_sig_data_scratch_get
pki_sig_data_scratch_get:
    ldr r0, =pki_sig_data_scratch_addr
    ldr r0, [r0]
    bx lr
