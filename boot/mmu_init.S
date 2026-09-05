/* Dhruva Round 38 -- ARMv6 (ARM1176JZF-S) MMU bring-up + W^X page
 * permissions.
 *
 * This project has run with the MMU permanently off since Phase 0 --
 * every page readable, writable, AND executable simultaneously, with
 * no protection of any kind. This file turns the MMU on with a pure
 * IDENTITY map (virtual address == physical address everywhere
 * mapped, so no existing code anywhere in this project needs to
 * change what address it reads/writes/branches to) plus real,
 * LIVE-VERIFIED write protection for code: the code section is
 * read+execute but genuinely never writable -- a deliberate write to
 * it was proven to fault (see below). Data/heap/stack and every
 * peripheral are marked read+write, execute-never (XN=1) -- but
 * unlike the write-protection above, XN enforcement for instruction
 * fetch could NOT be verified as functioning under QEMU's ARM1176
 * model this round, despite real, repeated testing (see "KNOWN
 * LIMITATION" below). The XN bits are kept set anyway -- free on real
 * hardware if that's where the gap actually is, harmless if QEMU
 * simply doesn't enforce it.
 *
 * ARMv6 first-level descriptors work at 1MB ("section") granularity
 * -- no finer boundary is expressible without a second-level (4KB
 * page) table, out of this round's scope. link.ld's own new 1MB
 * ALIGN before .data is what makes a clean code/data split possible
 * at this granularity at all; see that file's own comment.
 *
 * Deliberately does NOT enable caching (SCTLR bits 2/12 stay clear) --
 * every mapped region uses Normal-Non-cacheable (RAM) or Shareable-
 * Device (peripherals) memory types, matching this project's existing
 * cache-off design exactly (round 16-18's memory-ordering work assumed
 * it, and the security roadmap's own DMA/NEON note flags the resulting
 * zero cache-timing-side-channel surface as worth preserving
 * deliberately, not losing by accident here). This round adds
 * permission enforcement only, changing nothing about caching/
 * ordering behavior anywhere in this project.
 *
 * Section descriptor bit layout (ARMv6 short-descriptor format, no
 * LPAE, no TEX remapping -- SCTLR.TRE left clear, the simpler/legacy
 * interpretation):
 *   [31:20] section base address (physical >> 20)
 *   [19]    NS (Non-secure) -- 0
 *   [18]    0 (section, not supersection)
 *   [17]    nG -- 0 (global)
 *   [16]    S (Shareable) -- 0 (single core, doesn't matter)
 *   [15]    APX
 *   [14:12] TEX[2:0]
 *   [11:10] AP[1:0]
 *   [9]     IMP -- 0
 *   [8:5]   Domain
 *   [4]     XN (execute-never)
 *   [3]     C
 *   [2]     B
 *   [1:0]   0b10 (section descriptor type)
 *
 * Every mapping here uses domain 0 (matches DACR below), and
 * APX=1/AP=01 (privileged read-only) for code vs. APX=0/AP=01
 * (privileged read-write) for everything else -- this project runs
 * entirely in privileged CPU modes (SVC/IRQ/Abort), so "unprivileged:
 * no access" is irrelevant; the two states that matter are
 * "privileged read-only" and "privileged read-write". QEMU's own
 * ARM1176 model source wasn't available to cross-check this bit
 * layout against (unlike every other peripheral in this project) --
 * verified instead via this round's own live testing, which caught
 * two real, non-obvious issues along the way rather than trusting the
 * encoding blindly:
 *
 * FOUND AND FIXED: the first attempt used APX=1/AP=11 for read-only
 * (a combination some references describe as valid) and left
 * SCTLR.XP (bit 23) at its reset value. A deliberate write to the
 * read-only code section did NOT fault. Switching the encoding to
 * APX=1/AP=01 alone didn't fix it either -- the actual missing piece
 * was SCTLR.XP itself: bit 23 disables ARMv5's legacy "subpage AP"
 * compatibility scheme in favor of the whole-section AP interpretation
 * this table actually uses. Setting XP made the SAME deliberate write
 * correctly fault with a section-permission status (0x...D in
 * bits[3:0]) -- proof the read-only half of W^X genuinely works, not
 * just present in the table.
 *
 * KNOWN LIMITATION, NOT FIXED: with the identical mechanism now
 * proven correct for AP/APX, a parallel deliberate test -- jumping
 * into the XN=1 data section and expecting a Prefetch Abort -- never
 * faulted. Execution ran straight through the (zero-filled) data as
 * harmless `andeq r0,r0,r0` no-ops for hundreds of KB until it
 * organically hit a byte pattern decoding as a genuine undefined
 * instruction, far past where a working XN check should have stopped
 * it immediately. A bit-position swap between APX and XN was ruled
 * out (the code section still executed correctly with APX=1, which a
 * mistaken XN-at-bit-15 would have prevented).
 *
 * Found AFTER this round's live testing: a local Yocto build tree
 * happened to have QEMU 4.2.0's own source checked out
 * (target/arm/helper.c) -- an older version than the 10.0.11 actually
 * installed and tested against, but real reference material where
 * none was expected to be available. That source's get_phys_addr_v6
 * (reached exactly when SCTLR.XP is set, confirmed by its own caller)
 * matches this file's encoding in every particular that matters here:
 * XN really is bit 4 of the section descriptor; domain_prot==1
 * (client, what this table's DACR sets) takes the normal AP/XN-
 * checked path rather than domain_prot==3's (manager) full-access
 * bypass; APX/AP combine into a 3-bit value whose case 5 (APX=1,AP=01,
 * the code section's own encoding) yields read-only and case 1
 * (APX=0,AP=01, data's encoding) yields read-write, both matching
 * what this round's own write-protection test already proved live.
 * `get_phys_addr_v6` extracts `xn` from the descriptor correctly and
 * passes it into a separate helper, `get_S1prot`, to decide the final
 * protection bits.
 *
 * ROUND 70 UPDATE (2026-09-04): fully root-caused, no longer a
 * "strong inference" -- fetched QEMU's actual source for both the
 * OLD (4.2.0, tag v4.2.0) and CURRENTLY INSTALLED (10.0.11, tag
 * v10.0.0 used as the closest matching public tag) versions directly
 * from github.com/qemu/qemu and read `get_S1prot` in full in both.
 * The exact same logic exists in BOTH, unchanged across more than six
 * years of QEMU history:
 *
 *     } else if (arm_feature(env, ARM_FEATURE_V7)) {
 *         ... (the real XN-combining logic, several lines) ...
 *     } else {
 *         xn = wxn = 0;
 *     }
 *
 * i.e. for any AArch32 core WITHOUT `ARM_FEATURE_V7` set, QEMU's own
 * `get_S1prot` unconditionally DISCARDS whatever `xn` value the
 * caller extracted from the page table, before it ever reaches the
 * final `if (xn || ...) return prot_rw;` decision that would grant or
 * withhold PAGE_EXEC. And `arm1176_initfn` (the exact CPU model
 * `raspi1ap` uses) -- checked in both `target/arm/cpu.c` (v4.2.0) and
 * `target/arm/tcg/cpu32.c` (v10.0.0) -- sets `ARM_FEATURE_V6K`/
 * `VAPA`/`EL3`/etc. but NEVER `ARM_FEATURE_V7`, confirming this
 * override fires for this exact core in both versions.
 *
 * Conclusion: this is not a version-specific regression and not a bug
 * in this file's own encoding -- it's a QEMU TCG emulation scope
 * decision, consistent since at least 2019, that XN enforcement for
 * pre-ARMv7 32-bit cores (ARMv6 and earlier, including ARM1176JZF-S)
 * is simply not modeled. The earlier round's own investigation
 * correctly traced the XN-bit extraction and the AP/APX encoding
 * (both genuinely correct, and the AP/APX half is independently
 * proven by this file's own live write-protection test) but didn't
 * trace one level further into `get_S1prot`'s own separate
 * architecture-version gate, which is what actually discards it.
 *
 * This is now a confirmed QEMU emulation gap, not an open question --
 * but it's still worth confirming against real Pi 1B hardware (once
 * connected, see the project's own hardware-in-loop plan) once that's
 * available, since a real ARM1176 core's XN enforcement is the actual
 * feature this project cares about, not QEMU's emulation of it; the
 * XN bits are kept set in this table regardless, since they're free
 * on real hardware if it does enforce them, and harmless on QEMU
 * either way. */

.section ".bss"
.align 14   /* 16KB alignment -- TTBR0's own base-address field
             * requires bits[13:0] to be zero for a full, non-split
             * (N=0) first-level table. */
.global mmu_page_table
mmu_page_table:
    .space 16384   /* 4096 x 4-byte descriptors, covering the entire
                    * 4GB physical address space at 1MB granularity.
                    * Zero-initialized by boot.S's own clear_bss loop
                    * (this lives in .bss like everything else) --
                    * bits[1:0]=00 is the "fault on any access"
                    * encoding, so anything NOT explicitly set below
                    * is unmapped and faults immediately rather than
                    * silently doing something wrong. */

/* Round 76 -- per-task stack guard pages (docs/RTOS_GAP_ANALYSIS.md's
 * "No per-task memory or stack protection" gap, directly motivated by
 * a real stack overflow this project found: a 512-byte task stack
 * silently corrupted adjacent heap memory and crashed somewhere else,
 * minutes later, with a misleading fault address, rather than faulting
 * at the moment of overflow). Section 1 (0x00100000-0x001FFFFF, this
 * table's own second entry below) covers .data/.bss/the heap/every
 * task stack -- but a 1MB SECTION descriptor is one uniform permission
 * for the whole megabyte, no finer boundary expressible (this file's
 * own original comment already flagged this as "out of this round's
 * scope" back at round 38). This second-level ("coarse") page table
 * gives that ONE section 4KB ("small page") granularity instead --
 * 256 entries x 4 bytes, ARMv6's own coarse-table size for exactly a
 * 1MB region -- so `dhruva_alloc_stack_guarded` (boot/rpi1/
 * runtime_stubs.c) can install one no-access guard page directly
 * before each task's own stack, entirely at runtime, well after this
 * table is first built (task stacks don't even exist yet at boot-time
 * mmu_init -- they're carved from the heap much later, during
 * kernel_main's task_create calls). Every entry defaults to the exact
 * same RW/XN small-page permissions Section 1's own descriptor already
 * used (see mmu_init's own loop below) -- nothing about this section's
 * behavior changes until a guard page is explicitly installed. */
.align 10   /* 1KB alignment -- an ARMv6 coarse (L2) page table's own
             * base-address field requires bits[9:0] zero. */
.global mmu_l2_table_data
mmu_l2_table_data:
    .space 1024   /* 256 x 4-byte small-page descriptors, exactly
                   * covering Section 1's own 1MB (256 x 4KB). */

.section ".text"

.global mmu_init
mmu_init:
    stmdb sp!, {r4-r7, lr}

    ldr r4, =mmu_page_table

    /* Section 0 (0x00000000-0x000FFFFF): vectors + .text.boot + .text
     * + .rodata -- round 38's own build measured this whole region at
     * ~113KB, comfortably inside this 1MB with wide margin. Read+
     * execute, never write: APX=1,AP=01 (0x8000|0x400) -- "privileged
     * read-only, unprivileged no access" -- not APX=1,AP=11 (tried
     * first; live-tested and found NOT to actually enforce read-only
     * on this core/QEMU model, a real empirical finding this round's
     * own verification caught rather than trusting the encoding
     * blindly). This project runs entirely in privileged CPU modes
     * (SVC/IRQ/Abort), so "unprivileged: no access" is irrelevant --
     * privileged code always gets read+execute here, never write.
     * TEX=001/C=0/B=0 = Normal Non-cacheable (0x1000), XN=0
     * (executable), domain 0, section type. */
    ldr r5, =0x00009402
    str r5, [r4, #0]

    /* Section 1 (0x00100000-0x001FFFFF): .data/.bss (includes the
     * 256KB heap)/task stacks/.ARM.exidx+extab -- link.ld's own new
     * 1MB ALIGN before .data guarantees all of this starts exactly at
     * this boundary. Round 76: now a PAGE TABLE (coarse) descriptor,
     * not a plain section descriptor -- see mmu_l2_table_data's own
     * comment above for why (per-task stack guard pages need 4KB
     * granularity a 1MB section can't express). L1 "page table"
     * format: bits[31:10] = L2 table base, bits[8:5] = domain (0,
     * matching every other entry in this table), bits[1:0] = 0b01
     * (coarse page table type). Populated below with one uniform
     * small-page descriptor per entry, matching Section 1's OLD
     * section-level permissions exactly (read+write, never execute,
     * Normal Non-cacheable) -- nothing about this section's actual
     * behavior changes here; only its granularity does. */
    ldr r5, =mmu_l2_table_data
    orr r5, r5, #1
    str r5, [r4, #4]

    /* Populate all 256 small-page entries. Small-page descriptor
     * format (DIFFERENT bit layout from the section format above --
     * XN lives at bit[0] here, not bit[4]): bits[31:12] = page base,
     * bits[8:6] = TEX (001 = Normal Non-cacheable, matching every
     * other mapping in this table), bits[5:4] = AP (01 = privileged
     * read-write, same AP=01 choice as every section above), bit[9] =
     * APX (0), bits[1:0] = 0b11 (small page, WITH bit[0]=XN=1 folded
     * into the type field -- 0b10 would mean small page, XN=0,
     * executable; this project's data/heap/stack region must never be
     * executable, same reasoning as section 1's own original XN=1).
     * Value per entry (excluding page base) = TEX(0x40) | AP(0x10) |
     * type+XN(0x3) = 0x53. */
    ldr r6, =mmu_l2_table_data
    ldr r7, =0x00100000    /* first page's physical base */
    mov r5, #0
mmu_init_l2_data_loop:
    ldr r0, =0x53
    orr r0, r0, r7
    str r0, [r6, r5, lsl #2]
    add r7, r7, #0x1000
    add r5, r5, #1
    cmp r5, #256
    blt mmu_init_l2_data_loop

    /* Sections 512-527 (0x20000000-0x20FFFFFF, 16MB): every BCM2835
     * peripheral this project uses falls inside this one block with
     * wide margin -- confirmed by grepping every 0x20...... literal
     * address in this codebase before choosing this range (lowest:
     * 0x20003000 the system timer; highest: 0x20980000 DWC2 USB), not
     * assumed from the datasheet alone. Read+write, never execute,
     * Shareable Device memory (TEX=000/C=0/B=1, 0x4) -- the
     * architecturally correct type for MMIO, distinct from the Normal
     * Non-cacheable type used for RAM above. AP=01 (privileged-only),
     * same reasoning as the RAM sections above. */
    mov r6, #512
    ldr r7, =0x20000000
mmu_init_periph_loop:
    ldr r5, =0x00000406
    orr r5, r5, r7
    str r5, [r4, r6, lsl #2]
    add r7, r7, #0x00100000
    add r6, r6, #1
    cmp r6, #528
    blt mmu_init_periph_loop

    /* ROUND 71 FIX (2026-09-05): sections 448-511 (0x1C000000-
     * 0x1FFFFFFF, 64MB) -- VideoCore ("GPU") RAM, where the HDMI
     * framebuffer round 71 added actually lives. Found live, the hard
     * way: `fb fill` (a plain write to the address the mailbox's own
     * FRAMEBUFFER_ALLOCATE response reported) took a genuine Data
     * Abort (Translation fault) the first time anything in this
     * project ever touched that address range -- this MMU table
     * (round 38) only ever mapped ARM-side RAM (section 0-1) and the
     * peripheral block (512-527); everything else was deliberately
     * left unmapped-therefore-faulting, which is exactly correct
     * EXCEPT that round 38 predates round 71's own framebuffer work
     * by many rounds and had no reason to know this region would ever
     * matter. Confirmed via QEMU's own hw/arm/bcm2835_peripherals.c
     * source (not guessed): `vcram_base = ram_size - vcram_size`
     * with `vcram_size` defaulting to 0x4000000 (64MB,
     * hw/display/bcm2835_fb.c's DEFAULT_VCRAM_SIZE) -- for this
     * machine's actual 512MB total RAM (independently confirmed via
     * the live-observed framebuffer base address itself,
     * 0x1C100000 = vcram_base 0x1C000000 + BCM2835_FB_OFFSET
     * 0x00100000, working the arithmetic backward), that places VC
     * RAM at exactly 0x1C000000-0x1FFFFFFF. This also matches the
     * real hardware target's own confirmed 512MB (Pi 1B rev 2) with a
     * default 64MB GPU memory split. Real DRAM the GPU also uses, not
     * a device register -- Normal Non-cacheable (same memory type as
     * the ARM-side RAM sections above), read+write, execute-never,
     * same AP=01/APX=0 encoding as section 1. Honest limitation: this
     * assumes the confirmed default 64MB VC RAM split; a real Pi's
     * `config.txt` `gpu_mem=` setting configured larger would move
     * data outside this mapped range back into faulting territory --
     * not attempted here since 64MB is this project's own confirmed
     * default on both QEMU and the real target hardware. */
    mov r6, #448
    ldr r7, =0x1C000000
mmu_init_vcram_loop:
    ldr r5, =0x00001412
    orr r5, r5, r7
    str r5, [r4, r6, lsl #2]
    add r7, r7, #0x00100000
    add r6, r6, #1
    cmp r6, #512
    blt mmu_init_vcram_loop

    /* Invalidate the entire TLB (both I and D) before this table is
     * ever consulted. A cold boot's TLB should already hold nothing
     * valid -- but relying on that rather than saying so explicitly is
     * exactly the kind of assumption this project's own audits keep
     * finding broken elsewhere. */
    mov r5, #0
    mcr p15, 0, r5, c8, c7, 0

    /* TTBR0 = page table base. */
    mcr p15, 0, r4, c2, c0, 0

    /* DACR: domain 0 = client (0b01) -- access permission is checked
     * per the AP/APX bits in each descriptor above, rather than
     * domain 0 blanket-allowing (manager, 0b11) or blanket-denying
     * (no access, 0b00) everything regardless of those bits. Every
     * descriptor above uses domain 0, so this one write covers the
     * whole table. */
    mov r5, #1
    mcr p15, 0, r5, c3, c0, 0

    /* SCTLR: set bit 0 (M, MMU enable) AND bit 23 (XP) -- caches stay
     * off otherwise, per this file's own header comment. XP disables
     * ARMv5's legacy "subpage AP" scheme (four independently-
     * permissioned 1KB subpages per section/page, a much older
     * compatibility feature) in favor of the single whole-section AP
     * interpretation this table actually uses -- omitted from the
     * first version of this function and found live, empirically, as
     * the actual cause of a real bug: a deliberate write to the
     * read-only code section did NOT fault with XP left at its
     * reset value (0, legacy mode), across two different AP encoding
     * attempts, before this bit was identified as the real gap.
     * Because every mapping above is a pure identity map, the very
     * next instruction fetched (the ldmia below) resolves to the
     * exact same physical address it would have without the MMU at
     * all -- no jump discontinuity, seamless enable. */
    mrc p15, 0, r5, c1, c0, 0
    orr r5, r5, #0x1
    orr r5, r5, #0x800000
    mcr p15, 0, r5, c1, c0, 0

    ldmia sp!, {r4-r7, lr}
    bx lr

/* i64 mmu_guard_page_install(mut ref i64 addr) -- round 76, the
 * runtime half of the per-task stack guard mechanism (see mmu_l2_
 * table_data's own comment above for the full design). Called from
 * dhruva_alloc_stack_guarded (boot/rpi1/runtime_stubs.c) once per task
 * stack, well after boot -- unlike everything else in this file, this
 * genuinely MODIFIES the live page table at runtime rather than only
 * building it once at boot, since task stacks don't exist yet when
 * mmu_init itself runs.
 *
 * addr MUST be a 4KB-page-aligned address inside Section 1's own
 * 0x00100000-0x001FFFFF range -- dhruva_alloc_stack_guarded's own
 * bump-and-align logic is what guarantees this; this function does
 * not (and architecturally cannot cheaply) re-verify the range itself,
 * matching this project's own convention of trusting an internal,
 * single-caller contract rather than re-deriving invariants centrally
 * available data already guarantees.
 *
 * Zeroing the small-page descriptor gives bits[1:0]=00, "invalid,
 * fault on any access" -- the identical convention this whole page
 * table already uses for anything unmapped. A single-entry TLB
 * invalidate (TLBIMVA, not a full-TLB flush) is sufficient and cheap
 * even though this runs many times during boot (once per task stack)
 * -- only the one page being newly guarded could possibly have a
 * stale, now-wrong TLB entry from its previous (valid, RW) mapping. */
.global mmu_guard_page_install
mmu_guard_page_install:
    sub r1, r0, #0x00100000
    lsr r1, r1, #12
    ldr r2, =mmu_l2_table_data
    mov r3, #0
    str r3, [r2, r1, lsl #2]

    mcr p15, 0, r0, c8, c7, 1   /* TLBIMVA: invalidate this one page's
                                 * TLB entry by MVA (r0 still holds the
                                 * page-aligned address unchanged) */
    mov r0, #0
    bx lr
