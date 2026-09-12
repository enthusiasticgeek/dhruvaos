/* Dhruva Phase 0/2 linker script -- BCM2835 / Pi 1 Model B.
 * 0x8000 is the conventional Raspberry Pi kernel load address (matches
 * real hardware's GPU-firmware loader too, not just QEMU's -kernel path)
 * -- kept the same on purpose so this script doesn't need to change when
 * this eventually runs on the real board.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x8000;

    /* TASK #163 FIX (first real-hardware boot, 2026-09-12): ARMv6 has
     * no VBAR -- the vector table must live at address 0 (low vectors,
     * the reset default) or not work at all. This USED to be a
     * genuinely separate output section linked at VMA 0x0 -- valid for
     * QEMU's own `-kernel` ELF loader, which places each of an ELF's
     * segments at its own independent address, but WRONG for real Pi
     * firmware, which loads `kernel.img` as ONE flat, contiguous raw
     * binary at a single fixed address (0x8000) with no concept of a
     * second, disjoint load address. `objcopy -O binary` faithfully
     * reproduces the ELF's own VMA layout as one contiguous file
     * spanning from the LOWEST to HIGHEST address across every
     * section -- confirmed by direct measurement: kernel.img's own
     * first 32 bytes are genuinely the vector table's own encoding
     * (`ldr pc, [pc, #24]`, repeated 8 times), not `_start`'s real
     * code. Real firmware loading that file at its own fixed 0x8000
     * would put the vector table AT the entry point instead of
     * `_start`'s real boot code -- the CPU would execute the reset
     * vector's own `ldr pc,[pc,#24]`, load its literal-pool value
     * (`_start`'s own address, a link-time constant, 0x8000), and jump
     * right back to the SAME physical address it's already executing
     * from: a silent, tight infinite loop, never reaching ANY of this
     * kernel's own code -- not uart_init(), not even this file's own
     * earlier cache-invalidation fix. Invisible under QEMU by
     * construction (QEMU's own multi-segment ELF loading sidesteps
     * this raw-binary-specific constraint entirely), so this survived
     * completely undetected across every prior fix this same
     * investigation already made.
     *
     * Fixed the same way every well-known bare-metal Pi 1 reference
     * handles this (confirmed directly against dwelch67/raspberrypi's
     * own blinker05 example, and its own README's explicit reasoning:
     * "our program is loaded at address 0x8000... I have made [an
     * exception table] there anyway"): the vector table now lives
     * AT the real entry point (0x8000, where firmware both loads AND
     * jumps), immediately followed by the real boot code (renamed
     * `boot_entry`, see boot.S) -- and `boot_entry`'s own first action
     * is to explicitly copy this table down to address 0x0 at
     * runtime, matching that same reference's own proven technique,
     * since address 0 is where the CPU's own hardware actually reads
     * exception vectors from, but is NOT where real firmware can be
     * told to load anything for a plain raw-binary kernel.img. */
    .vectors : { KEEP(*(.vectors)) }

    .text.boot : { *(.text.boot) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }

    /* Round 38: push everything writable (.data/.bss -- including the
     * 256KB heap -- /stacks) to the next 1MB boundary, so the MMU's
     * page table (mmu_init.S) can mark 0x00000000-0x000FFFFF read+
     * execute-only (vectors+.text.boot+.text+.rodata, ~113KB today,
     * comfortably inside this 1MB with wide margin) and everything
     * from 0x00100000 on read+write-but-never-execute, at ARMv6's own
     * 1MB section granularity -- with no per-file boundary tracking
     * needed beyond this one ALIGN. Real W^X enforcement needs this
     * gap; ARMv6 sections can't express a finer boundary than 1MB
     * without a second-level (4KB page) table, out of this round's
     * scope. Costs unused ADDRESS SPACE only (~896KB here), not
     * physical RAM commitment -- a trivial trade on a 512MB board. */
    . = ALIGN(0x100000);

    .data : { *(.data*) }

    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;

    /* 16KB boot stack, growing down from _stack_top. */
    . = ALIGN(16);
    . = . + 0x4000;
    _stack_top = .;

    /* 4KB IRQ-mode stack, growing down from _irq_stack_top -- small on
     * purpose: irq_entry.S does minimal work on this stack before
     * calling into vani, which needs headroom of its own but nothing
     * like the 16KB a full task stack gets. (Briefly bumped to 32KB
     * while chasing what turned out to be BUG-229, a vani-compiler bug
     * unrelated to stack size at all -- reverted once the real cause
     * was found and fixed upstream.) */
    . = ALIGN(16);
    . = . + 0x1000;
    _irq_stack_top = .;

    /* Round 38: 4KB Abort-mode stack, same size class as IRQ's own --
     * boot.S never gave Abort mode a banked sp before now (nothing
     * could trigger a Data/Prefetch Abort worth handling until this
     * round's MMU work made permission faults a real, expected event
     * rather than an unrecoverable bug). fault_data_abort/
     * fault_prefetch_abort (vectors.S) switch to SVC mode before
     * calling into vani, the exact same proven pattern irq_entry.S
     * already uses -- so this stack only needs to hold the handful of
     * raw MRC reads staged before that switch, not a full vani call
     * frame. */
    . = ALIGN(16);
    . = . + 0x1000;
    _abort_stack_top = .;

    /* No exception unwinding on bare metal, and no real .ARM.exidx
     * content to keep either -- but libgcc.a's unwind-arm.o (pulled in
     * for __aeabi_ldivmod, needed once Phase 4 task #10's expression
     * evaluator started doing i64 division on a CPU with no hardware
     * divide instruction) references __exidx_start/__exidx_end
     * unconditionally, and ld only auto-defines those at the boundaries
     * of a REAL .ARM.exidx output section -- discarding the section
     * outright (the previous approach here) leaves them undefined.
     * Defining an empty section instead of discarding it satisfies the
     * reference without keeping any actual unwind-table content: this
     * program never throws/unwinds, so the boundary being a zero-length
     * range is exactly correct, not a workaround with a hidden cost. */
    /* .ARM.extab must be kept alongside .ARM.exidx, not discarded:
     * kernel_main.o's own per-function exidx entries (LLVM's default
     * ARM EABI codegen emits these regardless of whether the function
     * ever throws) reference matching extab entries by name, and a
     * dangling reference into a discarded section is a hard link
     * error, not just wasted space. */
    .ARM.exidx : { __exidx_start = .; *(.ARM.exidx*) __exidx_end = .; }
    .ARM.extab : { *(.ARM.extab*) }
}
