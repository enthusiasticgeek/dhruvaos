/* Dhruva round 73 -- Raspberry Pi 4 (BCM2711, AArch64/ARMv8-A) MMU
 * bring-up: TTBR0_EL1/TCR_EL1/MAIR_EL1, radically different register
 * set and descriptor format from ARMv6's short-descriptor 1MB sections
 * in boot/mmu_init.S (this file's Pi 1 twin), even though the actual
 * GOAL -- a pure identity map with code read+execute-never-writable and
 * everything else read+write-never-executable -- is identical. Same
 * "fault diagnostics before anything else" ordering round 38 and round
 * 43/70 already established for both targets: boot/rpi4/vectors.S's
 * exception table (including the "Current EL, SPx" sync-fault path
 * this kernel actually runs under) already existed before this file
 * was written, so a page-table bug here reports a real ESR_EL1/ELR_EL1/
 * FAR_EL1 diagnostic instead of silently corrupting execution.
 *
 * ARMv8-A uses a hierarchical, per-level page table (unlike ARMv6's
 * flat 4096-entry first-level table) -- this uses the standard 4KB-
 * granule, 39-bit input-address configuration (TCR_EL1.T0SZ=25),
 * which starts the walk at level 1 (level 0 is only consulted for
 * input addresses wider than 39 bits, irrelevant here since this
 * kernel only ever needs to identity-map the low 4GB). Three tables:
 *
 *   mmu_l1_table   -- 512 entries, each covering 1GB. Only indices
 *                     0/1/3 are populated (see below); every other
 *                     entry stays zeroed by boot.S's own bss-clear
 *                     loop (added this round -- see that file's own
 *                     comment), which is bits[1:0]=00, architecturally
 *                     "invalid, fault on any access" for a descriptor,
 *                     exactly like ARMv6's zeroed section descriptors.
 *   mmu_l2_table_0 -- covers PA 0x00000000-0x3FFFFFFF (L1 index 0):
 *                     the low 1GB of the Pi 4's RAM, where this
 *                     kernel's own code/data/stack actually live
 *                     (loaded at 0x80000, see link.ld). Entry 0 (PA
 *                     0x00000000-0x001FFFFF, the 2MB block containing
 *                     every byte of .text.boot/.vectors/.text/
 *                     .rodata, confirmed by this round's own build
 *                     measuring the whole image at under 3KB, wildly
 *                     inside this 2MB budget) is READ+EXECUTE, NEVER
 *                     WRITE. Every other entry (.data/.bss/stack and
 *                     all otherwise-unused RAM in this 1GB) is
 *                     READ+WRITE, NEVER EXECUTE. link.ld's own new
 *                     2MB ALIGN before .data is what guarantees code
 *                     and data land in different 2MB blocks at all --
 *                     the exact same technique boot/mmu_init.S's own
 *                     1MB ALIGN uses for the ARMv6 target, just at
 *                     this format's finer 2MB block granularity.
 *   mmu_l2_table_1 -- covers PA 0x40000000-0x7FFFFFFF (L1 index 1):
 *                     the rest of this machine's 2GB of RAM (confirmed
 *                     live via QMP's query-memory-size-summary this
 *                     round, not assumed -- base-memory reported
 *                     exactly 0x80000000). Entirely READ+WRITE,
 *                     NEVER EXECUTE -- unused by this v1 kernel today,
 *                     but a future round's heap/task allocator will
 *                     need real backing RAM here, and mapping it now
 *                     as ordinary data-type RAM costs nothing.
 *   mmu_l2_table_3 -- covers PA 0xC0000000-0xFFFFFFFF (L1 index 3):
 *                     Device-nGnRnE, READ+WRITE, NEVER EXECUTE, for
 *                     the entire top 1GB. Both peripherals this port
 *                     currently uses -- the PL011 UART (0xFE201000,
 *                     round 40) and the GICv2 distributor/CPU
 *                     interface (0xFF841000/0xFF842000, round 70,
 *                     both addresses read from QEMU's own
 *                     hw/arm/bcm2838.c source, not guessed) -- fall
 *                     inside this one block with wide margin, same
 *                     "cover the whole plausible region, confirmed by
 *                     checking every address this project actually
 *                     uses" strategy boot/mmu_init.S's own 16MB
 *                     peripheral block already uses for the Pi 1 side.
 *   (L1 index 2, PA 0x80000000-0xBFFFFFFF: deliberately left
 *   unmapped/invalid -- outside this machine's real 2GB of RAM and
 *   below the peripheral block, so any access there is a genuine bug,
 *   not a valid access this table should paper over.)
 *
 * Memory types (MAIR_EL1, two attribute encodings):
 *   Attr0 = 0x44 = Normal memory, Inner AND Outer Non-cacheable.
 *   Attr1 = 0x00 = Device-nGnRnE (no gathering, no reordering, no
 *                  early write acknowledgement -- the architecturally
 *                  correct type for MMIO).
 * Deliberately NOT enabling caching anywhere (SCTLR_EL1.C/I both left
 * clear below) -- carries forward, unchanged, the exact same
 * cache-off design choice boot/mmu_init.S's own header comment
 * documents for the Pi 1 side (round 16-18's memory-ordering work
 * assumed it, and the security roadmap's DMA/NEON note flags the
 * resulting zero cache-timing-side-channel surface as worth
 * preserving deliberately). This round only adds translation +
 * permission enforcement for the Pi 4 target, changing nothing about
 * this project's existing caching/ordering posture anywhere.
 *
 * Descriptor bit layout used throughout (AArch64 stage-1, 4KB granule,
 * block descriptors at level 1/2, table descriptors at level 0/1):
 *   [1:0]   descriptor type -- 0b01 block (leaf), 0b11 table (points
 *           to the next level), 0b00 invalid (fault).
 *   [4:2]   AttrIndx -- index into MAIR_EL1 (0=Normal NC, 1=Device).
 *   [7:6]   AP[2:1] -- AP[2] (bit7) =1 means EL1 read-only, =0 means
 *           EL1 read-write; AP[1] (bit6) left 0 throughout (no EL0
 *           access -- this kernel never runs anything at EL0).
 *   [9:8]   SH -- shareability; 0b11 (Inner Shareable) used
 *           uniformly, matching boot/mmu_init.S's own S=0 "single
 *           core, doesn't matter" reasoning for the ARMv6 side.
 *   [10]    AF (Access Flag) -- must be 1, or the very first access
 *           through this descriptor takes an Access Flag fault
 *           instead of succeeding (this kernel never walks the table
 *           to set AF lazily the way a full OS might).
 *   [53]    PXN (Privileged execute-never) -- 1 on every data/device
 *           block, 0 on the one code block.
 *   [54]    UXN (Unprivileged execute-never) -- 1 on every block,
 *           including code: this kernel has no EL0 code today, so
 *           nothing should EVER execute at EL0 out of this table.
 */

.equ ATTR_NORMAL_NC,   0x44
.equ ATTR_DEVICE_NGNRNE, 0x00

.equ DESC_AF,     (1 << 10)
.equ DESC_SH_INNER, (3 << 8)
.equ DESC_AP_RO,  (1 << 7)
.equ DESC_ATTR_NORMAL, (0 << 2)
.equ DESC_ATTR_DEVICE, (1 << 2)
.equ DESC_PXN,    (1 << 53)
.equ DESC_UXN,    (1 << 54)
.equ DESC_BLOCK,  0x1
.equ DESC_TABLE,  0x3

/* Flags-only (no base address) for the three block-descriptor kinds
 * this table ever uses -- ORed with a 2MB-aligned physical base in
 * the fill loops below. */
.equ FLAGS_CODE_RX,   (DESC_UXN | DESC_AF | DESC_SH_INNER | DESC_AP_RO | DESC_ATTR_NORMAL | DESC_BLOCK)
.equ FLAGS_DATA_RW,   (DESC_PXN | DESC_UXN | DESC_AF | DESC_SH_INNER | DESC_ATTR_NORMAL | DESC_BLOCK)
.equ FLAGS_DEVICE_RW, (DESC_PXN | DESC_UXN | DESC_AF | DESC_SH_INNER | DESC_ATTR_DEVICE | DESC_BLOCK)

.section ".bss"
.align 12   /* 4KB alignment -- each table is exactly one page (512
             * entries x 8 bytes), and TTBR0_EL1/table-descriptor base
             * fields both require this. Zero-initialized by boot.S's
             * own bss-clear loop (added this round specifically so
             * this holds -- see that file's own comment), giving
             * "invalid, fault on any access" for every entry this
             * file doesn't explicitly fill below. */
.global mmu_l1_table
mmu_l1_table:
    .space 4096
.align 12
mmu_l2_table_0:
    .space 4096
.align 12
mmu_l2_table_1:
    .space 4096
.align 12
mmu_l2_table_3:
    .space 4096

.section ".text"

.global mmu_init_rpi4
mmu_init_rpi4:
    /* L2 table 0, entry 0: the one 2MB code block (PA
     * 0x00000000-0x001FFFFF), read+execute, never write. */
    ldr x9, =mmu_l2_table_0
    ldr x12, =FLAGS_CODE_RX
    mov x13, x12            /* base address is 0 for entry 0 */
    str x13, [x9, #0]

    /* L2 table 0, entries 1-511: rest of the low 1GB (where .data/
     * .bss/stack actually land, per link.ld's 2MB ALIGN before
     * .data), read+write, never execute. */
    mov x10, #1
    ldr x12, =FLAGS_DATA_RW
mmu_l2_0_data_loop:
    lsl x11, x10, #21       /* base = index * 2MB */
    orr x13, x11, x12
    str x13, [x9, x10, lsl #3]
    add x10, x10, #1
    cmp x10, #512
    b.lt mmu_l2_0_data_loop

    /* L2 table 1: PA 0x40000000-0x7FFFFFFF, all 512 entries,
     * read+write, never execute -- the rest of this machine's 2GB
     * (base-memory=0x80000000, confirmed live via QMP this round). */
    ldr x9, =mmu_l2_table_1
    mov x10, #0
    ldr x12, =FLAGS_DATA_RW
    ldr x14, =0x40000000
mmu_l2_1_loop:
    lsl x11, x10, #21
    add x11, x11, x14
    orr x13, x11, x12
    str x13, [x9, x10, lsl #3]
    add x10, x10, #1
    cmp x10, #512
    b.lt mmu_l2_1_loop

    /* L2 table 3: PA 0xC0000000-0xFFFFFFFF, all 512 entries,
     * Device-nGnRnE, read+write, never execute -- covers the PL011
     * UART (0xFE201000) and the GICv2 distributor/CPU interface
     * (0xFF841000/0xFF842000) with wide margin. */
    ldr x9, =mmu_l2_table_3
    mov x10, #0
    ldr x12, =FLAGS_DEVICE_RW
    ldr x14, =0xC0000000
mmu_l2_3_loop:
    lsl x11, x10, #21
    add x11, x11, x14
    orr x13, x11, x12
    str x13, [x9, x10, lsl #3]
    add x10, x10, #1
    cmp x10, #512
    b.lt mmu_l2_3_loop

    /* L1 table: index 0 -> L2 table 0, index 1 -> L2 table 1,
     * index 2 left invalid (zeroed by bss-clear -- PA 0x80000000-
     * 0xBFFFFFFF is neither real RAM nor a peripheral this port
     * uses), index 3 -> L2 table 3. */
    ldr x9, =mmu_l1_table
    ldr x10, =mmu_l2_table_0
    orr x10, x10, #DESC_TABLE
    str x10, [x9, #0]
    ldr x10, =mmu_l2_table_1
    orr x10, x10, #DESC_TABLE
    str x10, [x9, #8]
    ldr x10, =mmu_l2_table_3
    orr x10, x10, #DESC_TABLE
    str x10, [x9, #24]

    /* Invalidate the entire TLB (stage 1, EL1, this ASID/all ASIDs)
     * before this table is ever consulted -- same "don't assume a
     * cold boot's TLB is already empty, say so explicitly" discipline
     * boot/mmu_init.S's own comment establishes for the ARMv6 side. */
    dsb ish
    tlbi vmalle1
    dsb ish
    isb

    /* MAIR_EL1: attribute index 0 = Normal Non-cacheable, index 1 =
     * Device-nGnRnE (see this file's own header comment). */
    ldr x9, =((ATTR_DEVICE_NGNRNE << 8) | ATTR_NORMAL_NC)
    msr mair_el1, x9

    /* TCR_EL1: T0SZ=25 (39-bit input address via TTBR0, the standard
     * "3-level walk starting at L1" configuration this table's own
     * layout assumes), TG0=0b00 (4KB granule), IRGN0/ORGN0=0b00
     * (table-walk cacheability: Non-cacheable, matching this file's
     * across-the-board cache-off choice), SH0=0b11 (Inner Shareable,
     * same "single core, doesn't matter" reasoning as every
     * descriptor above), EPD1=1 (bit 23: never walk via TTBR1_EL1 --
     * this kernel has no upper-half/kernel-vs-user split, TTBR0 alone
     * covers everything it needs). IPS left at its reset value (0b000,
     * 32-bit/4GB physical address size) -- this table never maps
     * anything above 0xFFFFFFFF, so the default already covers every
     * output address it produces. */
    ldr x9, =((25) | (0 << 14) | (0 << 8) | (0 << 10) | (3 << 12) | (1 << 23))
    msr tcr_el1, x9

    /* TTBR0_EL1 = L1 table base -- identity map, so this is
     * simultaneously the physical AND virtual base this kernel
     * already runs at. */
    ldr x9, =mmu_l1_table
    msr ttbr0_el1, x9
    isb

    /* SCTLR_EL1: read-modify-write, only ever setting bit 0 (M, MMU
     * enable) -- exactly boot/mmu_init.S's own technique of preserving
     * whatever RES1/reset-defined bits already exist rather than
     * blindly overwriting the whole register. C (bit 2) and I (bit
     * 12) stay clear throughout, per this file's own cache-off
     * design note above. Because every mapping above is a pure
     * identity map, the very next instruction fetched after this
     * write resolves to the exact same physical address it would
     * have without the MMU at all -- no jump discontinuity, seamless
     * enable, same guarantee boot/mmu_init.S's own comment makes for
     * the ARMv6 side. */
    mrs x9, sctlr_el1
    orr x9, x9, #1
    msr sctlr_el1, x9
    isb

    ret
