/* Dhruva -- persistent state for real authentication (password-
 * protected `su`/`passwd`), plus scratch buffers for the new HMAC-
 * SHA256/PBKDF2-HMAC-SHA256 primitives this feature needs (this
 * project had SHA-256 alone before -- see kernel_main.vani's own
 * crypto-primitives-foundation comment).
 *
 * A small FIXED user table (8 slots), matching this project's own
 * "small fixed arrays, not dynamic allocation" convention elsewhere
 * (MAX_MUTEXES=4, MAX_TASKS=16, fw_state.S's 8 rules) -- plenty for a
 * single-board embedded demo, not meant to scale to a real multi-user
 * system. Each slot: uid (0xFFFFFFFF = empty), a 16-byte salt, a
 * 32-byte PBKDF2-HMAC-SHA256 output (never the password itself), a
 * failed-attempt counter, and a lockout-until tick (both per-slot
 * rate-limiting state, not global -- one user's lockout must not also
 * block a different user).
 *
 * HMAC/PBKDF2 scratch is small and reused sequentially (never
 * concurrently -- this project is single-core, single-threaded-per-
 * task, and password verification is never itself preempted mid-
 * computation by another password operation), same "persistent
 * scratch, not per-call dhruva_alloc_bytes" discipline sha256_hash's
 * own round-48 fix already established. Sized for THIS project's own
 * actual inputs (passwords/salts, not arbitrary file-sized messages
 * the way sha256_hash's own 4096-byte padded scratch has to be) --
 * hmac_msg_scratch's 128 bytes comfortably covers a 64-byte pad block
 * plus up to a 64-byte message, more than either PBKDF2's own internal
 * calls (a 16-byte salt + 4-byte counter, or a bare 32-byte U value)
 * or a reasonable real password ever need. */

.equ MAX_AUTH_USERS, 8
.equ AUTH_SALT_LEN, 16
.equ AUTH_HASH_LEN, 32

.section ".bss"
.align 4
auth_uid_table:
    .space (MAX_AUTH_USERS * 4)
auth_salt_table:
    .space (MAX_AUTH_USERS * AUTH_SALT_LEN)
auth_hash_table:
    .space (MAX_AUTH_USERS * AUTH_HASH_LEN)
auth_fail_count_table:
    .space (MAX_AUTH_USERS * 4)
auth_lockout_until_table:
    .space (MAX_AUTH_USERS * 4)
auth_salt_nonce:
    .word 0

hmac_key_block_scratch:
    .space 64
hmac_msg_scratch:
    .space 128
hmac_inner_hash_scratch:
    .space 32
pbkdf2_u_scratch:
    .space 32
pbkdf2_t_scratch:
    .space 32
pbkdf2_salt_ctr_scratch:
    .space 36
passwd_scratch:
    .space 64
su_hash_scratch:
    .space 32

.section ".text"

/* void auth_table_init() -- seeds every slot's uid to the 0xFFFFFFFF
 * "empty" sentinel. .bss's own zero-init would otherwise leave every
 * slot reading uid=0, which looks like a real, configured root
 * account with an all-zero salt/hash -- MUST run once at boot before
 * anything else touches this table, same "seed the sentinel first"
 * discipline task_table_init already established for eff_prio_table. */
.global auth_table_init
auth_table_init:
    ldr r0, =auth_uid_table
    mvn r1, #0
    mov r2, #0
atinit_loop:
    cmp r2, #MAX_AUTH_USERS
    bge atinit_done
    str r1, [r0, r2, lsl #2]
    add r2, r2, #1
    b atinit_loop
atinit_done:
    bx lr

.global auth_get_uid
auth_get_uid:
    ldr r1, =auth_uid_table
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global auth_set_uid
auth_set_uid:
    ldr r2, =auth_uid_table
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global auth_salt_ptr
auth_salt_ptr:
    ldr r1, =auth_salt_table
    mov r2, #AUTH_SALT_LEN
    mla r0, r0, r2, r1
    bx lr

.global auth_hash_ptr
auth_hash_ptr:
    ldr r1, =auth_hash_table
    mov r2, #AUTH_HASH_LEN
    mla r0, r0, r2, r1
    bx lr

.global auth_get_fail_count
auth_get_fail_count:
    ldr r1, =auth_fail_count_table
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global auth_set_fail_count
auth_set_fail_count:
    ldr r2, =auth_fail_count_table
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global auth_get_lockout_until
auth_get_lockout_until:
    ldr r1, =auth_lockout_until_table
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global auth_set_lockout_until
auth_set_lockout_until:
    ldr r2, =auth_lockout_until_table
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

/* u32 auth_salt_nonce_next() -- returns a fresh, monotonically
 * increasing value each call. Combined with tick_count by the vani
 * side to build a salt: NOT a cryptographically secure randomness
 * source (this project has none -- same honest limitation the DHCP
 * client's own xid already documents), but salts only need to be
 * UNIQUE, not secret, and this guarantees uniqueness even across two
 * passwd calls landing in the same tick, which tick_count alone would
 * not. */
.global auth_salt_nonce_next
auth_salt_nonce_next:
    ldr r0, =auth_salt_nonce
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, r1
    bx lr

.global hmac_key_block_ptr
hmac_key_block_ptr:
    ldr r0, =hmac_key_block_scratch
    bx lr

.global hmac_msg_scratch_ptr
hmac_msg_scratch_ptr:
    ldr r0, =hmac_msg_scratch
    bx lr

.global hmac_inner_hash_ptr
hmac_inner_hash_ptr:
    ldr r0, =hmac_inner_hash_scratch
    bx lr

.global pbkdf2_u_ptr
pbkdf2_u_ptr:
    ldr r0, =pbkdf2_u_scratch
    bx lr

.global pbkdf2_t_ptr
pbkdf2_t_ptr:
    ldr r0, =pbkdf2_t_scratch
    bx lr

.global pbkdf2_salt_ctr_ptr
pbkdf2_salt_ctr_ptr:
    ldr r0, =pbkdf2_salt_ctr_scratch
    bx lr

.global passwd_scratch_ptr
passwd_scratch_ptr:
    ldr r0, =passwd_scratch
    bx lr

.global su_hash_scratch_ptr
su_hash_scratch_ptr:
    ldr r0, =su_hash_scratch
    bx lr
