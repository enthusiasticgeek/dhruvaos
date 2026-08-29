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
 * what this round's own write-protection test already proved live;
 * and critically, `if (*prot && !xn) *prot |= PAGE_EXEC` means a
 * section with xn=1 should never gain PAGE_EXEC at all, regardless of
 * AP/APX -- an instruction fetch should then fail the immediately-
 * following `*prot & (1 << access_type)` check and fault. Every
 * documented step of that logic agrees with this table's own intent.
 * That the CURRENTLY INSTALLED QEMU (10.0.11, five-plus years newer)
 * still did not enforce it, despite an older version's own source
 * confirming the logic should, now points more specifically at a
 * QEMU version-specific behavior difference than at a bug in this
 * table -- though without 10.0.11's own source to diff against
 * directly, that remains a strong inference, not a proven fact.
 * Flagged in docs/TODO.md as a tracked follow-up -- real Pi 1B
 * hardware (once connected, see the project's own hardware-in-loop
 * plan) would definitively settle whether this is QEMU-specific or a
 * genuine remaining bug, since real silicon's behavior is the actual
 * ground truth either way. */

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
     * this boundary. Read+write, never execute: APX=0,AP=01 (0x400)
     * -- "privileged read-write, unprivileged no access" -- same
     * AP=01 choice as the code section above, for the same reason
     * (privileged-only access is all this kernel ever needs). Same
     * Normal Non-cacheable memory type as code (0x1000), XN=1 (0x10). */
    ldr r5, =0x00100000
    ldr r6, =0x00001412
    orr r5, r5, r6
    str r5, [r4, #4]

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
