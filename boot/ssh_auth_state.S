/* Dhruva -- SSH authorized-keys table (task #193).
 *
 * SECURITY GAP this closes: the SSH server's own userauth verification
 * (ssh_real_phase3b_verify_signed, kernel_main.vani) used to check only
 * that the client's signature was valid for whatever Ed25519 public key
 * the CLIENT ITSELF presented -- proof-of-possession only, not real
 * access control. Any client that generates a keypair could SSH in.
 * This table gives the server something to check the presented key
 * AGAINST: a fixed uid -> authorized-pubkey mapping, mirroring
 * auth_state.S's own "small FIXED user table" convention exactly
 * (8 slots, uid=0xFFFFFFFF sentinel for empty, seeded once at boot).
 *
 * SSH has no username-string infrastructure anywhere else in this
 * project (every existing uid -- su, chmod, the local unauthenticated-
 * root-shell default -- is a plain decimal integer, never a name), so
 * the SSH username field is parsed the same way: as a decimal uid
 * string (kernel_main.vani's own shell_parse_decimal, reused directly
 * against the SSH packet buffer). "root"-style name-to-uid mapping is
 * explicitly out of scope -- would be a new subsystem this project has
 * never needed anywhere else, for a single-board embedded target where
 * "connect as uid 0" is already how every other privileged operation
 * works.
 *
 * Each slot: uid (4 bytes) + one raw 32-byte Ed25519 public key. One
 * key per uid (not a list) -- matches this project's own "plenty for a
 * single-board embedded demo" scoping already established by
 * auth_state.S's own header comment; a uid needing multiple authorized
 * keys can occupy multiple slots (a slot's own identity is the array
 * index, not the uid -- ssh_auth_find_uid_slot returns the FIRST match,
 * but nothing stops two slots sharing a uid with different keys). */

.equ MAX_SSH_AUTH_KEYS, 8
.equ SSH_AUTH_KEY_LEN, 32

.section ".bss"
.align 4
ssh_auth_uid_table:
    .space (MAX_SSH_AUTH_KEYS * 4)
ssh_auth_key_table:
    .space (MAX_SSH_AUTH_KEYS * SSH_AUTH_KEY_LEN)

.section ".text"

/* void ssh_auth_table_init() -- seeds every slot's uid to the
 * 0xFFFFFFFF "empty" sentinel, same reasoning as auth_table_init: .bss
 * zero-init would otherwise leave every slot reading uid=0, looking
 * like a real authorized root key with an all-zero pubkey. MUST run
 * once at boot before anything else touches this table. */
.global ssh_auth_table_init
ssh_auth_table_init:
    ldr r0, =ssh_auth_uid_table
    mvn r1, #0
    mov r2, #0
saitinit_loop:
    cmp r2, #MAX_SSH_AUTH_KEYS
    bge saitinit_done
    str r1, [r0, r2, lsl #2]
    add r2, r2, #1
    b saitinit_loop
saitinit_done:
    bx lr

.global ssh_auth_get_uid
ssh_auth_get_uid:
    ldr r1, =ssh_auth_uid_table
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global ssh_auth_set_uid
ssh_auth_set_uid:
    ldr r2, =ssh_auth_uid_table
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* mut ref i64 ssh_auth_key_ptr(i64 slot) -- pointer to that slot's own
 * 32-byte Ed25519 public key, same "pointer, not a copy" convention as
 * auth_salt_ptr/auth_hash_ptr above. */
.global ssh_auth_key_ptr
ssh_auth_key_ptr:
    ldr r1, =ssh_auth_key_table
    mov r2, #SSH_AUTH_KEY_LEN
    mla r0, r0, r2, r1
    bx lr
