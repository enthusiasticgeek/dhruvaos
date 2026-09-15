/* Dhruva -- persistent scratch for the WPA2/CSPRNG generator (task
 * #164 groundwork). Same "persistent, never per-call dhruva_alloc_bytes"
 * discipline as every other frequently-called protocol primitive in
 * this project: the generator's own state and per-block counter must
 * persist across every nonce-generation call for the kernel's whole
 * lifetime (a fresh state per call would defeat the whole point --
 * every "random" nonce would be independently reseeded from the same
 * kind of entropy draw rather than advancing one real random stream).
 *
 * state (32 bytes): the running SHA-256-based generator state (see
 * vendor/csprng/src/core.vani's own csprng_generate/csprng_reseed),
 * seeded once at boot from BCM2835's own hardware RNG peripheral
 * (csprng_init, kernel_main.vani) and ratcheted forward after every
 * csprng_generate call.
 * counter (8 bytes): the generator's own big-endian per-block counter,
 * persisting across calls so the keystream never restarts from block 0. */

.section ".bss"
.align 4
csprng_state:
    .space 32
csprng_counter:
    .space 8

.section ".text"

.global csprng_state_ptr
csprng_state_ptr:
    ldr r0, =csprng_state
    bx lr

.global csprng_counter_ptr
csprng_counter_ptr:
    ldr r0, =csprng_counter
    bx lr
