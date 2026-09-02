/* Dhruva -- persistent scratch/constant buffers for Keccak-f[1600] /
 * SHA-3 / SHAKE (FIPS 202), round 67's PQC prerequisite (ML-KEM needs
 * SHA3-256, SHA3-512, SHAKE128, SHAKE256 throughout -- a completely
 * different hash family from the SHA-2 family every other primitive
 * in this codebase uses). Same allocate-once-at-boot discipline as
 * every other scratch buffer in this project.
 *
 * keccak_state: the 1600-bit (200-byte) working state, 25 64-bit
 * lanes stored little-endian (matching Keccak's own byte<->lane
 * mapping AND this project's own native buf_read_u32/buf_write_u32
 * convention -- unlike SHA-512's big-endian wire format, no byte-
 * swapping is needed here at all).
 * keccak_temp: rho+pi's own output (that step reorders lanes, so it
 * can't be done in place).
 * keccak_c/keccak_d: theta's own 5-lane column-parity intermediates.
 * keccak_rc: the 24 round constants (8 bytes each).
 * keccak_rho/keccak_pi_dest: the 25 fixed per-lane rotation amounts
 * and pi-step destination indices (4 bytes each, small values --
 * computed once via keccak_init from a from-scratch-Python-verified
 * derivation, not hand-transcribed from a table this project has no
 * independent way to check).
 * keccak_pad_scratch: one call's own padded-input buffer, sized to
 * the largest real ML-KEM caller (J's own z||ciphertext input, 800
 * bytes for ML-KEM-512, rounded up with headroom). */

.section ".bss"
.align 4
keccak_state_addr:
    .word 0
keccak_temp_addr:
    .word 0
keccak_c_addr:
    .word 0
keccak_d_addr:
    .word 0
keccak_rc_addr:
    .word 0
keccak_rho_addr:
    .word 0
keccak_pi_dest_addr:
    .word 0
keccak_pad_scratch_addr:
    .word 0

.section ".text"

.macro KECCAK_SCRATCH_PAIR name
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

KECCAK_SCRATCH_PAIR keccak_state
KECCAK_SCRATCH_PAIR keccak_temp
KECCAK_SCRATCH_PAIR keccak_c
KECCAK_SCRATCH_PAIR keccak_d
KECCAK_SCRATCH_PAIR keccak_rc
KECCAK_SCRATCH_PAIR keccak_rho
KECCAK_SCRATCH_PAIR keccak_pi_dest
KECCAK_SCRATCH_PAIR keccak_pad_scratch
