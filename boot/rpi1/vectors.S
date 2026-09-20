/* Dhruva Phase 2 -- ARM exception vector table (Pi 1 / ARM1176, ARMv6).
 *
 * ARMv6 has no VBAR (that's an ARMv7+ addition) -- the vector table
 * location is fixed at either 0x00000000 (low vectors, the reset
 * default) or 0xFFFF0000 (high vectors). This uses low vectors, but
 * TASK #163 FIX (first real-hardware boot, 2026-09-12): this table is
 * no longer LINKED at address 0 directly. It used to be, and that
 * worked fine under QEMU's own `-kernel` ELF loader (which places
 * each of an ELF's segments at its own independent address) -- but
 * real Pi firmware loads `kernel.img` as ONE flat raw binary at a
 * single fixed address (0x8000), with no way to also place a second,
 * disjoint region at address 0. This table is now linked AT 0x8000
 * instead -- the real entry point, where firmware both loads AND
 * jumps on real hardware -- immediately followed by the real boot
 * code (boot.S's own `boot_entry`, not `_start` anymore: `_start` is
 * THIS table now, matching the real firmware's own idea of where
 * the kernel begins). `boot_entry`'s own first action explicitly
 * copies this table down to address 0 at runtime, since that's where
 * the CPU's own hardware actually reads exception vectors from, but
 * is NOT an address real firmware can be told to load a plain raw-
 * binary kernel.img at. See link.ld's own comment (`.vectors` output
 * section) for the full reasoning, confirmed directly against
 * dwelch67/raspberrypi's own well-known, proven blinker05 example.
 *
 * This is genuinely board/architecture-specific, not just BCM2835-
 * specific -- PandaBoard's Cortex-A9 is ARMv7-A and *does* have VBAR,
 * so it gets to relocate its vector table wherever convenient instead
 * of fighting over address 0. A PandaBoard port needs its own version
 * of this file, not a shared one.
 *
 * Classic ARM vector-table trick: every entry is `ldr pc, [pc, #24]`,
 * which -- because of ARM's pipeline, PC reads as (this instruction's
 * address + 8) -- loads from a literal pool placed immediately after
 * the 8 vector instructions (8*4 = 32 = 0x20 bytes further on; #24
 * plus the implicit +8 = 0x20). Every vector uses the identical
 * encoding; only the corresponding literal-pool word differs.
 */

.section ".vectors", "ax"
.global _start
.global _vectors
_start:
_vectors:
    ldr pc, [pc, #24]   /* 0x00: reset */
    ldr pc, [pc, #24]   /* 0x04: undefined instruction */
    ldr pc, [pc, #24]   /* 0x08: software interrupt (SWI/SVC) */
    ldr pc, [pc, #24]   /* 0x0C: prefetch abort */
    ldr pc, [pc, #24]   /* 0x10: data abort */
    ldr pc, [pc, #24]   /* 0x14: reserved */
    ldr pc, [pc, #24]   /* 0x18: IRQ */
    ldr pc, [pc, #24]   /* 0x1C: FIQ */
.word boot_entry
.word fault_undef
.word swi_entry           /* Task #253 Phase 3 (2026-09-18): real
                            * handler now, boot/swi_entry.S -- was
                            * fault_swi (crash stub) up to this round;
                            * the syscall trap for USR-mode task code
                            * to reach genuinely privileged scheduler
                            * primitives, see that file's own header
                            * comment. */
.word fault_prefetch_abort
.word fault_data_abort
.word fault_reserved
.word irq_entry
.word fiq_entry           /* Task #246 (2026-09-18): real handler now,
                            * boot/fiq_entry.S -- was fault_fiq (crash
                            * stub) up to this round; the timer tick is
                            * routed here instead of ordinary IRQ, see
                            * that file's own header comment. */

/* Phase 2 doesn't recover from most of these -- just halts, so a real
 * bug shows up as "the board stopped," not as running on into
 * corrupted state. undef/reserved still have no UART diagnostic; not
 * required for anything built so far. fiq (task #246, 2026-09-18) and
 * swi (task #253 Phase 3, 2026-09-18) are no longer in this group --
 * see boot/fiq_entry.S/boot/swi_entry.S, real handlers now that the
 * timer tick is FIQ-routed and USR-mode task code has a real syscall
 * trap.
 *
 * Round 38: fault_data_abort/fault_prefetch_abort get a real
 * diagnostic instead -- MMU permission faults (this round's own W^X
 * enforcement) are now a genuinely expected event, not an
 * unrecoverable bug, and a silent `b .` would make debugging any real
 * page-table mistake here effectively impossible (no JTAG on this
 * project's QEMU target). Neither handler ever returns -- both halt
 * forever after printing, same as every other fault here -- so
 * there's no need to preserve/restore any register state, only to
 * read the fault info before it's gone and report it.
 *
 * DFAR/DFSR (data) and IFAR/IFSR (prefetch) are read here, in Abort
 * mode, BEFORE switching to SVC mode with `cps` -- the exact same
 * proven pattern irq_entry.S already uses to reach vani code safely
 * (Abort mode's own banked sp only needs to survive these few MRC
 * reads, never a real push, so _abort_stack_top's 4KB is generous
 * headroom, not a tight fit). IFAR is an ARMv6 addition (ARM1176JZF-S
 * implements it) -- confirmed empirically as part of this round's own
 * live verification, not just assumed from architecture docs alone,
 * since QEMU's own source wasn't available to cross-check against
 * this time (unlike every other peripheral in this project). */
.global fault_undef
.global fault_reserved
fault_undef:
fault_reserved:
    b .

.global fault_data_abort
fault_data_abort:
    /* ARCHITECTURAL FIX (2026-09-19/20, task #253 scheduler-freeze
     * investigation): this handler used to `cps #0x13` (switch to SVC
     * mode) and build its own report frame there, on the theory that
     * "never returning, safe to reuse whatever's on that stack." That
     * reasoning has a real hole: it assumes sp_svc is merely "some
     * task's stack we're about to clobber harmlessly" -- but sp_svc can
     * ALSO simply be INVALID (corrupted, or exactly 0/NULL) at the
     * moment of a genuine fault, especially for the exact class of bug
     * this investigation is chasing (a scheduler-state stack pointer
     * reaching NULL). If sp_svc itself is bad, `sub sp,sp,#16` and the
     * `str`s right after it ALSO fault -- a genuine double-fault that
     * silently swallows the ENTIRE report, which is EXACTLY what live
     * GDB caught happening (docs/TODO.md's own task #253 writeup):
     * fault_data_abort's own entry hit, but no "FATAL:" line ever
     * reached the UART, because building ITS OWN report frame on the
     * (corrupted) sp_svc faulted a second time.
     *
     * Fixed at the architectural level: ABT mode already has its own
     * dedicated, guaranteed-valid stack (sp_abt, set up once at boot --
     * see boot.S's own round-38 comment, `_abort_stack_top`, a fixed
     * 4KB region never touched by any task or any other exception
     * mode). Building the ENTIRE report frame here, in ABT mode, on
     * sp_abt, and calling `abort_report_data` WITHOUT ever switching to
     * SVC at all, means this handler can report a real fault regardless
     * of what corrupted sp_svc -- exactly the guarantee a fault handler
     * is supposed to provide (the same reason ARM gives every exception
     * mode its own banked sp/lr in the first place, and the same
     * principle real OSes rely on for fault/panic handlers that must
     * work even when the interrupted context is thoroughly broken).
     *
     * Also masks FIQ on entry (`cpsid f`) -- ABT mode's own exception
     * entry auto-masks I but NOT F, the exact same "third privileged
     * mode fiq_entry.S's own true-lr check was never built to
     * recognize" gap already found and fixed once in swi_entry.S (see
     * that file's own header comment) -- without this, a real timer
     * tick landing mid-report here would hit fiq_entry.S's own mode
     * check (USR vs "assume SVC"), misread THIS abort-mode context as
     * SVC, and corrupt scheduler state exactly the way that earlier fix
     * already had to prevent for the syscall path.
     *
     * Trade-off, accepted deliberately: `orig_lr` in the report below
     * used to be lr_SVC (the ORIGINAL calling function's own return
     * address, only reachable by physically switching to SVC mode --
     * ARMv6 has no banked-register-read instruction across modes, that
     * is an ARMv7+ virtualization-extension addition). Staying in ABT
     * mode throughout means this field is now lr_ABT instead (the
     * abort's own return-address convention, closely related to but
     * not identical to fault_pc/r2 below) -- a real loss of one
     * diagnostic nicety, worth it for a fault handler that can no
     * longer be silently defeated by the exact class of corruption it
     * exists to report. */
    cpsid f
    /* SECOND real bug found live via GDB right after the ABT-mode fix
     * above: `abort_report_data` itself (or something it calls) can
     * ALSO fault -- observed directly, a real recursive re-entry into
     * this exact handler, over and over, each time from the SAME
     * instruction (identical lr/r2 on every hit after the first).
     * Before this fix, sp_abt was NEVER reset on entry -- each
     * recursive re-entry did its own `sub sp,sp,#16` starting from
     * WHEREVER the previous (failed) attempt left off, silently eating
     * 16 bytes of sp_abt per recursion with no bound, walking off the
     * bottom of `_abort_stack_top` (4KB) and corrupting whatever memory
     * sits below it -- caught only because a live GDB breakpoint here
     * happened to be watching; on real hardware this would have been a
     * second, silent, undiagnosable corruption on top of the first.
     * Resetting sp to `_abort_stack_top` on EVERY entry means a
     * recursive fault during report-building can happen at most once
     * more before hitting this same reset point again -- it can no
     * longer run away or corrupt adjacent memory, even though the
     * underlying "something the report path touches is ALSO corrupted"
     * finding (docs/TODO.md's own task #253 writeup) is not yet fixed. */
    ldr sp, =_abort_stack_top
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
    mrc p15, 0, r0, c6, c0, 0   /* DFAR: data fault address */
    mrc p15, 0, r1, c5, c0, 0   /* DFSR: data fault status */
    sub r2, lr, #8              /* fault_pc = lr_abt - 8 */
    mov r3, r4                  /* orig_r0 -> arg4 */
    mov r8, lr                  /* orig_lr (now lr_abt -- see header
                                  * comment above for why this changed) */
    sub sp, sp, #16             /* on sp_abt now, always valid -- see
                                  * header comment above */
    str r5, [sp, #0]            /* orig_r1 -> arg5 (stack) */
    str r6, [sp, #4]            /* orig_r2 -> arg6 (stack) */
    str r7, [sp, #8]            /* orig_r3 -> arg7 (stack) */
    str r8, [sp, #12]           /* orig_lr -> arg8 (stack) */
    bl abort_report_data
    b .

.global fault_prefetch_abort
fault_prefetch_abort:
    /* Same architectural fix as fault_data_abort above -- stays in ABT
     * mode throughout (sp_abt, guaranteed valid, never sp_svc) and
     * masks FIQ on entry. See that function's own header comment for
     * the full "why". */
    cpsid f
    ldr sp, =_abort_stack_top   /* see fault_data_abort's own header
                                 * comment for why every entry resets sp
                                 * rather than trusting it's still valid */
    mrc p15, 0, r0, c6, c0, 2   /* IFAR: instruction fault address */
    mrc p15, 0, r1, c5, c0, 1   /* IFSR: instruction fault status */
    bl abort_report_prefetch
    b .
