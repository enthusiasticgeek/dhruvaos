/* Dhruva Phase 3 -- tiny persistent SD-card state (ARM32).
 *
 * vani has no top-level global/static variables by design (see
 * kernel_main.vani's own header) -- kernel_main.vani's sdhost_init()
 * runs exactly once, but the RCA it publishes and the card's
 * addressing mode (SDSC/byte-addressed vs SDHC/block-addressed, from
 * the OCR's CCS bit) need to reach every later block read/write call,
 * including from a future GC/compaction task's own function body
 * (task #5) -- a separate entry point kernel_main's local variables
 * can't reach. Exactly the same shape of problem context_switch.S's
 * sp_table/current_task already solve for scheduler state, so this
 * follows the same small-.bss-plus-extern-accessor pattern rather
 * than inventing a second way to persist state across a vani call
 * boundary.
 */

.section ".bss"
.align 4
sd_rca:
    .word 0        /* published by CMD3, needed by every addressed
                     * command (CMD9/CMD7/CMD17/CMD24) from here on */
sd_is_sdhc:
    .word 0        /* 0 = SDSC (byte-addressed), 1 = SDHC/SDXC
                     * (block-addressed) -- from the OCR's CCS bit,
                     * valid only once ACMD41 reports busy=0 (ready) */

.section ".text"

/* Every function below that uses r4 or r5 as scratch now saves and
 * restores it (push/pop) -- not defensive filler, a fix for a real
 * bug: r4-r11 are callee-saved under AAPCS, and vani's generated
 * caller code keeps genuinely live values in them across calls on the
 * strength of that guarantee (confirmed directly in kernel_main's own
 * disassembly, which holds buffer pointers and later start_
 * multitasking's own arguments in r4-r9 across this exact block of
 * calls). Clobbering r4/r5 here without saving them doesn't corrupt
 * anything the compiler can see -- it corrupts values the compiler
 * has every right to assume survive untouched, which is a fundamentally
 * different, much harder to see class of bug than a wrong local
 * computation: the visible failure lands wherever that clobbered
 * register's value next gets used, often far away in unrelated code.
 * Here specifically, that meant a second consecutive SD read/write
 * cycle would run and report success individually, exactly as
 * expected, and the actual damage -- corrupted task-stack-pointer
 * arguments reaching start_multitasking -- wouldn't surface as a
 * crash until real preemption began running task code against those
 * bad pointers, well after the SD code had already finished and moved
 * on. Confirmed via `qemu-system-arm -d int,cpu_reset`: zero real
 * reset events logged despite the visible reboot, meaning this was
 * PC jumping back to _start from corrupted state, the same signature
 * boot/irq_entry.S's unrelated Phase 2 bug had -- and via bisection
 * showing one SD read/write cycle was always safe while a second one,
 * regardless of which block number either touched, reliably wasn't.
 *
 * Every function below is declared in kernel_main.vani as returning
 * `i64` -- a genuine 64-bit AAPCS return value, back in r0:r1 (low:
 * high), not just r0. Explicitly zeroing r1 before every `bx lr` here
 * is not defensive-programming filler: leaving it unset (whatever a
 * function happened to last use r1 for) is a real, reproducible bug
 * class, not just a theoretical ABI nicety -- see test_compare_buffers
 * below for the instance that actually manifested, corrupting a
 * caller's own multi-term boolean logic despite the caller's own code
 * and vani's compiler both being entirely correct. */
.global sd_state_set
sd_state_set:
    ldr r2, =sd_rca
    str r0, [r2]
    ldr r2, =sd_is_sdhc
    str r1, [r2]
    mov r0, #0
    mov r1, #0
    bx lr

.global sd_state_get_rca
sd_state_get_rca:
    ldr r0, =sd_rca
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sd_state_get_is_sdhc
sd_state_get_is_sdhc:
    ldr r0, =sd_is_sdhc
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* void sdhost_drain_fifo_to_buffer(mut ref i64 buf, i64 word_count)
 * void sdhost_fill_fifo_from_buffer(mut ref i64 buf, i64 word_count)
 *
 * The one piece of Phase 3's SD driver vani genuinely can't express:
 * transferring raw 32-bit words between the SDDATA FIFO register and
 * an arbitrary caller-supplied buffer address. vani's mmio_read_u32/
 * mmio_write_u32 builtins take a literal i64 address, not a `mut ref
 * i64` handle -- there is no vani-level operation that turns a
 * reference into a plain integer address to feed them (by design,
 * same reasoning as every other raw-pointer gap this project has hit:
 * a first-class reference degrading to a bare address would break the
 * ownership model). So, same as context_switch.S's stack-frame
 * plumbing, this one small raw-memory loop lives in hand-written
 * assembly; the actual SD command/protocol logic (which only ever
 * needs plain scalar values) stays in kernel_main.vani, calling these
 * only for the FIFO-to-RAM leg of a transfer.
 *
 * word_count arrives in r2, NOT r1: this project's own established
 * AAPCS gotcha (see context_switch.S/task_sleep_ticks) is that a
 * 64-bit i64 argument needs an even-aligned register pair, and a
 * preceding `mut ref i64` (1 register, r0) leaves the next slot at
 * the ODD position r1 -- so the real ABI pads r1 and places word_count
 * at r2:r3 instead. Confirmed directly from the compiled callsite
 * disassembly (`mov r2, #128; mov r3, #0; bl ...`) after this exact
 * bug produced a genuinely erratic symptom: reading stale, unrelated
 * garbage out of r1 as the loop count -- sometimes small enough to
 * merely transfer the wrong number of words (silently, since QEMU's
 * SD emulation doesn't fail loudly on a short transfer), sometimes
 * large enough to spin for what looks exactly like an infinite hang.
 * Both symptoms, and their apparent sensitivity to unrelated code
 * changes elsewhere (different register allocation nearby just
 * happened to leave different garbage in r1), pointed at a genuine
 * calling-convention bug here rather than an SD-protocol one, once
 * actually checked against the disassembly instead of guessed at from
 * symptoms alone. */
/* TASK #163 FOLLOW-UP (2026-09-14): both loops below used to blast
 * word_count words straight at SDDATA with NO polling of any FIFO-
 * readiness status at all -- correct only if the controller can always
 * accept/produce a word the instant the CPU asks for one. Found after
 * the second real Pi 1B boot showed reproducible SD/DharaFS write
 * corruption (kernel_main.vani's own "SD: 8-block round-trip sweep"
 * self-test, and downstream DharaFS persistence, both real -- see
 * project memory) that QEMU's own SD FIFO model never exhibited across
 * this whole project's testing history, because it has no real
 * backpressure to violate. Confirmed against Linux's own real
 * driver for this exact controller (drivers/mmc/host/bcm2835.c,
 * bcm2835_transfer_block_pio): it polls SDEDM's own FIFO-word-count
 * field, bits[8:4] ((edm >> 4) & 0x1F), before transferring, using a
 * documented 16-word FIFO depth (SDDATA_FIFO_WORDS). That driver polls
 * once per up-to-8-word burst for throughput; this file polls once per
 * WORD instead -- simpler to get unconditionally correct in raw asm,
 * and this project's own established "correctness first" convention
 * (boot/rpi1/boot.S's own header comment) makes that the right
 * trade-off here over matching Linux's burst optimization exactly.
 * Bounded retry count per word (100000), not `while true`, matching
 * sdhost_cmd's own "a wedged card can never hang the caller forever"
 * convention just above in kernel_main.vani -- if the FIFO genuinely
 * never becomes ready, the caller's own post-transfer SDHSTS error-bit
 * check (sdhost_read_block/write_block) is what actually surfaces the
 * failure; this bound only prevents an infinite spin. */
.global sdhost_drain_fifo_to_buffer
sdhost_drain_fifo_to_buffer:
    push {r4, r5, r6}         /* r4/r5/r6 callee-saved (AAPCS) -- see the
                               * file-level note below on why this
                               * isn't optional here */
    mov r4, r2               /* r4 = word_count (r2:r3 pair, low half) */
    ldr r6, =0x20202034      /* SDEDM */
sdhost_drain_loop:
    cmp r4, #0
    beq sdhost_drain_done
    ldr r5, =100000          /* bounded per-word poll-for-data retry cap --
                               * ldr, not mov: 100000 (0x186A0) isn't a
                               * valid ARM rotated-immediate */
sdhost_drain_poll:
    ldr r2, [r6]
    mov r2, r2, lsr #4
    and r2, r2, #0x1F        /* r2 = current FIFO word count */
    cmp r2, #0
    bne sdhost_drain_ready    /* at least 1 word available -- go read it */
    subs r5, r5, #1
    bne sdhost_drain_poll
sdhost_drain_ready:
    ldr r2, =0x20202040      /* SDDATA */
    ldr r3, [r2]
    str r3, [r0], #4
    sub r4, r4, #1
    b sdhost_drain_loop
sdhost_drain_done:
    pop {r4, r5, r6}
    mov r0, #0
    mov r1, #0
    bx lr

/* 20th/21st SD round (2026-09-24): renamed from the bare
 * sdhost_fill_fifo_from_buffer to _impl and given the exact dhruva_
 * prio_lock_impl treatment (boot/context_switch.S) -- `mrs r12,cpsr;
 * cpsid if` at entry, `msr cpsr_c,r12` before return -- for the real
 * structural gap found comparing this loop against Linux's own
 * bcm2835_sdhost_write_block_pio: Linux wraps its entire PIO write-
 * block loop in local_irq_save/restore, this loop never masked
 * anything. A first attempt called `cpsid if`/`cpsie if` directly from
 * this function while it was still reachable straight from USR-mode
 * task code -- exactly the same UNPREDICTABLE-instruction mistake
 * dhruva_prio_lock/_unlock's own history already made once (see that
 * function's header comment, "FIRST FIX ATTEMPT (reverted)") -- caught
 * by a live QEMU regression (eval/ping/ifconfig/tcpecho/etc. all newly
 * broken), reverted, and fixed the same way that one was: routed
 * through a real SWI trap (syscall #5, boot/swi_entry.S) so the mask/
 * restore genuinely happens in SVC mode. The trampoline below keeps
 * the plain sdhost_fill_fifo_from_buffer name and signature unchanged
 * -- every existing vani-side call site (kernel_main.vani) needed ZERO
 * changes, exactly like dhruva_prio_lock's own migration. r12 is
 * caller-saved scratch under AAPCS -- no push/pop needed for it, same
 * as dhruva_prio_lock_impl. */
.global sdhost_fill_fifo_from_buffer_impl
sdhost_fill_fifo_from_buffer_impl:
    push {r4, r5, r6}
    mrs r12, cpsr
    cpsid if
    mov r4, r2               /* r4 = word_count (r2:r3 pair, low half) */
    ldr r6, =0x20202034      /* SDEDM */
sdhost_fill_loop:
    cmp r4, #0
    beq sdhost_fill_done
    ldr r5, =100000          /* bounded per-word poll-for-space retry cap --
                               * ldr, not mov: 100000 (0x186A0) isn't a
                               * valid ARM rotated-immediate */
sdhost_fill_poll:
    ldr r2, [r6]
    mov r2, r2, lsr #4
    and r2, r2, #0x1F        /* r2 = current FIFO word count */
    cmp r2, #16              /* SDDATA_FIFO_WORDS (confirmed against
                               * Linux's own bcm2835.c) -- full when the
                               * count reaches this */
    blt sdhost_fill_ready     /* room for at least 1 more word */
    subs r5, r5, #1
    bne sdhost_fill_poll
sdhost_fill_ready:
    ldr r2, =0x20202040      /* SDDATA */
    ldr r3, [r0], #4
    str r3, [r2]
    sub r4, r4, #1
    b sdhost_fill_loop
sdhost_fill_done:
    msr cpsr_c, r12
    pop {r4, r5, r6}
    mov r0, #0
    mov r1, #0
    bx lr

/* TEMPORARY DIAGNOSTIC (2026-09-19, real-hardware SD write-wedge
 * investigation, per the user's own structured follow-up debugging
 * prompt, item 2/11: instrument the FIRST few SDDATA writes with SDEDM
 * captures, since every prior diagnostic only ever captured state at
 * the very END of the fixed 128-word loop or at the eventual timeout --
 * never during the loop itself, so there's no evidence yet on whether
 * the FIRST write actually changes FIFO fill/FSM at all, or whether
 * the FSM already looks wrong from the very first word.
 *
 * EXTENDED (2026-09-20, 19th SD round): user's own explicit follow-up
 * after the 18th round's timer-based timeout fix confirmed the wedge
 * persists -- "stop modifying timeout/retry behavior, instrument the
 * CMD24 transaction at instruction/register level." Every checkpoint
 * below now dumps SDCMD/SDARG/SDHBCT/SDHBLC/SDHSTS/SDEDM together
 * (sdhost_diag_dump_regs_body, shared with the new pre/post-CMD24
 * dump points in kernel_main.vani's own sdhost_write_block_once), not
 * just SDEDM alone -- and checkpoints now cover every 16-word FIFO
 * batch boundary (16/32/48/64/80/96/112/128), not just the first
 * FIFO's worth (previously 1/4/8/16 only, nothing beyond word 16 in a
 * 128-word/512-byte transfer).
 *
 * i64 sdhost_fill_fifo_from_buffer_diag(mut ref i64 buf, i64 word_count)
 * -- byte-for-byte the same fill loop as sdhost_fill_fifo_from_buffer
 * above, PLUS a blocking raw UART register dump immediately before the
 * very first write (word index 0, i.e. right after CMD24's own NEW_FLAG
 * cleared, before this function has touched SDDATA at all), immediately
 * after the first write, and after every subsequent 16-word batch.
 * Deliberately NOT the vani-level uart_puts (unsafe to call mid-
 * critical-section from hand-written asm with no established calling
 * convention for it here) or the async ring-buffer path (non-blocking,
 * could drop exactly the bytes this diagnostic exists to capture) --
 * same reasoning and same technique as this project's own earlier
 * task #253 diagnostic (context_switch.S, since removed). Write-path
 * ONLY: the read path already works (task #217's own READDATA fix,
 * confirmed on real hardware) and is deliberately left untouched to
 * avoid any risk of regressing it. To be removed once the write wedge
 * is root-caused. */
.global sdhost_fill_fifo_from_buffer_diag
sdhost_fill_fifo_from_buffer_diag:
    push {r4, r5, r6, r7, r8, lr}
    mov r8, r0                /* r8 = buffer pointer, kept persistent
                               * here (NOT auto-incremented via r0 the
                               * way the non-diag version does) since
                               * r0 is needed as scratch by every
                               * diagnostic call below -- none of
                               * sdhost_diag_putc/_puts/_put_hex1/
                               * _put_hex32/_dump_regs_body ever touch
                               * r4-r11, so r8 survives all of them
                               * untouched */
    mov r4, r2               /* r4 = word_count */
    mov r7, #0                /* r7 = words written so far */
    ldr r6, =0x20202034      /* SDEDM -- still used for the FIFO-room
                               * poll below; dump_regs_body re-reads it
                               * (and every other register) fresh each
                               * time it's called, independent of r6 */

    /* word index 0: before any write at all -- full register dump */
    ldr r0, =sdhost_diag_w0
    bl sdhost_diag_puts
    bl sdhost_diag_dump_regs_body

sdhost_fill_diag_loop:
    cmp r4, #0
    beq sdhost_fill_diag_done
    ldr r5, =100000
sdhost_fill_diag_poll:
    ldr r0, [r6]
    mov r0, r0, lsr #4
    and r0, r0, #0x1F
    cmp r0, #16
    blt sdhost_fill_diag_ready
    subs r5, r5, #1
    bne sdhost_fill_diag_poll
sdhost_fill_diag_ready:
    ldr r0, [r8], #4          /* r0 = next word from the buffer, buffer
                               * pointer advances */
    ldr r1, =0x20202040       /* SDDATA */
    str r0, [r1]
    sub r4, r4, #1
    add r7, r7, #1

    /* Full register dump right after word 1 (immediately after the
     * FIRST SDDATA write, the user's own explicit request), then after
     * every 16-word FIFO batch boundary through the full 128-word
     * transfer -- r4/r6/r7/r8 must survive these calls (confirmed:
     * every diag helper below only touches r0-r3, never r4-r11). */
    cmp r7, #1
    beq sdhost_fill_diag_snap
    cmp r7, #16
    beq sdhost_fill_diag_snap
    cmp r7, #32
    beq sdhost_fill_diag_snap
    cmp r7, #48
    beq sdhost_fill_diag_snap
    cmp r7, #64
    beq sdhost_fill_diag_snap
    cmp r7, #80
    beq sdhost_fill_diag_snap
    cmp r7, #96
    beq sdhost_fill_diag_snap
    cmp r7, #112
    beq sdhost_fill_diag_snap
    cmp r7, #128
    beq sdhost_fill_diag_snap
    b sdhost_fill_diag_loop
sdhost_fill_diag_snap:
    /* BUG caught before shipping (QEMU verification, 2026-09-19): r7
     * (words written so far) can be 16 at this point, but sdhost_diag_
     * put_hex1 only ever prints a single nibble (`and r0,r0,#0xF`) --
     * 16 truncates to 0, mislabeling this checkpoint "w0" (same text
     * as the pre-write snapshot) instead of "w16", even though the
     * register VALUES captured are correct either way. Two hex digits
     * (00/01/10/20/30/40/50/60/70/80) removes the ambiguity. */
    ldr r0, =sdhost_diag_wn
    bl sdhost_diag_puts
    mov r0, r7, lsr #4
    bl sdhost_diag_put_hex1
    mov r0, r7
    bl sdhost_diag_put_hex1
    ldr r0, =sdhost_diag_close_paren
    bl sdhost_diag_puts
    bl sdhost_diag_dump_regs_body
    b sdhost_fill_diag_loop
sdhost_fill_diag_done:
    pop {r4, r5, r6, r7, r8, lr}
    mov r0, #0
    mov r1, #0
    bx lr

/* ROUND 2026-09-20 (19th SD round): pre/post-CMD24 register-level
 * instrumentation, per the user's own explicit request -- "show SDCMD,
 * SDARG, SDHBCT, SDHBLC, SDHSTS and SDEDM immediately before CMD24,
 * after command completion... also capture CMD13/R1 immediately
 * before CMD24." The CMD13-before-CMD24 half lives in kernel_main.vani
 * itself (sdhost_write_block_once) since it's plain scalar SD-protocol
 * logic (sdhost_cmd, a real function vani can already call) -- these
 * two entry points are only for the raw MMIO register dump, the one
 * piece that (like the FIFO fill loop above) needs a blocking, no-
 * established-calling-convention print from a context vani's own
 * uart_puts isn't safely reachable from... except these two ARE called
 * from plain vani code (not mid-critical-section assembly), so unlike
 * the FIFO loop's own internal checkpoints, a vani-level uart_puts
 * call actually WOULD be safe here. Kept as raw asm regardless, for
 * ONE concrete, load-bearing reason: vani has no way to pass a string
 * literal to an extern "C" function as a raw pointer (Str is a real,
 * distinct vani type, not a bare address -- see this file's own header
 * comment on the raw-pointer gap this project has hit before), so a
 * single parameterized "dump with this label" entry point callable
 * from vani isn't expressible; two small, purpose-named, zero-argument
 * entry points are the direct fix, matching this project's own
 * established pattern of a hardcoded, purpose-specific function over a
 * parameterized one when the parameter can't actually cross the
 * vani/asm boundary (sdhost_fill_fifo_from_buffer_diag itself is the
 * same shape of workaround, one call up). To be removed once the write
 * wedge is root-caused. */
.global sdhost_diag_dump_regs_pre_cmd24
sdhost_diag_dump_regs_pre_cmd24:
    push {lr}
    ldr r0, =sdhost_diag_lbl_pre_cmd24
    bl sdhost_diag_puts
    bl sdhost_diag_dump_regs_body
    pop {lr}
    mov r0, #0
    mov r1, #0
    bx lr

.global sdhost_diag_dump_regs_post_cmd24
sdhost_diag_dump_regs_post_cmd24:
    push {lr}
    ldr r0, =sdhost_diag_lbl_post_cmd24
    bl sdhost_diag_puts
    bl sdhost_diag_dump_regs_body
    pop {lr}
    mov r0, #0
    mov r1, #0
    bx lr

/* void sdhost_diag_dump_regs_body(void) -- internal helper (no
 * .global -- only ever called from within this file), prints
 * " SDCMD=0x.. SDARG=0x.. SDHBCT=0x.. SDHBLC=0x.. SDHSTS=0x..
 * SDEDM=0x..\n". Caller is expected to have already printed its own
 * label with no trailing newline. Never touches r4-r11 -- every call
 * site above relies on this to keep its own loop-persistent registers
 * alive across the call. */
sdhost_diag_dump_regs_body:
    push {lr}

    ldr r0, =sdhost_diag_lbl_sdcmd
    bl sdhost_diag_puts
    ldr r1, =0x20202000       /* SDCMD */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    ldr r0, =sdhost_diag_lbl_sdarg
    bl sdhost_diag_puts
    ldr r1, =0x20202004       /* SDARG */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    ldr r0, =sdhost_diag_lbl_sdhbct
    bl sdhost_diag_puts
    ldr r1, =0x2020203C       /* SDHBCT */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    ldr r0, =sdhost_diag_lbl_sdhblc
    bl sdhost_diag_puts
    ldr r1, =0x20202050       /* SDHBLC */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    ldr r0, =sdhost_diag_lbl_sdhsts
    bl sdhost_diag_puts
    ldr r1, =0x20202020       /* SDHSTS */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    ldr r0, =sdhost_diag_lbl_sdedm
    bl sdhost_diag_puts
    ldr r1, =0x20202034       /* SDEDM */
    ldr r0, [r1]
    bl sdhost_diag_put_hex32

    mov r0, #10
    bl sdhost_diag_putc
    pop {lr}
    bx lr

.section ".rodata"
sdhost_diag_w0:
    .asciz "SD DIAG: pre-write(w00)"
sdhost_diag_wn:
    .asciz "SD DIAG: post-write(w"
sdhost_diag_close_paren:
    .asciz ")"
sdhost_diag_lbl_pre_cmd24:
    .asciz "SD DIAG: pre-CMD24"
sdhost_diag_lbl_post_cmd24:
    .asciz "SD DIAG: post-CMD24-cmd-complete"
sdhost_diag_lbl_sdcmd:
    .asciz " SDCMD=0x"
sdhost_diag_lbl_sdarg:
    .asciz " SDARG=0x"
sdhost_diag_lbl_sdhbct:
    .asciz " SDHBCT=0x"
sdhost_diag_lbl_sdhblc:
    .asciz " SDHBLC=0x"
sdhost_diag_lbl_sdhsts:
    .asciz " SDHSTS=0x"
sdhost_diag_lbl_sdedm:
    .asciz " SDEDM=0x"
.section ".text"

/* void sdhost_diag_putc(r0=char) -- blocking single-byte UART write. */
sdhost_diag_putc:
    push {r1, r3}
sdhost_diag_putc_wait:
    ldr r1, =0x20201018      /* UART_FR */
    ldr r3, [r1]
    tst r3, #0x20             /* TXFF */
    bne sdhost_diag_putc_wait
    ldr r1, =0x20201000      /* UART_DR */
    strb r0, [r1]
    pop {r1, r3}
    bx lr

/* void sdhost_diag_puts(r0=&nul-terminated string) -- blocking. */
sdhost_diag_puts:
    push {r0, lr}
    mov r3, r0
sdhost_diag_puts_loop:
    ldrb r0, [r3], #1
    cmp r0, #0
    beq sdhost_diag_puts_done
    push {r3}
    bl sdhost_diag_putc
    pop {r3}
    b sdhost_diag_puts_loop
sdhost_diag_puts_done:
    pop {r0, lr}
    bx lr

/* void sdhost_diag_put_hex1(r0=value 0-15) -- one hex digit, blocking. */
sdhost_diag_put_hex1:
    push {r0, lr}
    and r0, r0, #0xF
    cmp r0, #9
    addgt r0, r0, #('A' - 10 - '0')
    add r0, r0, #'0'
    bl sdhost_diag_putc
    pop {r0, lr}
    bx lr

/* void sdhost_diag_put_hex32(r0=value) -- 8 hex digits, blocking. */
sdhost_diag_put_hex32:
    push {r0-r3, lr}
    mov r3, #8
    mov r2, r0
sdhost_diag_put_hex32_loop:
    mov r0, r2, lsr #28
    bl sdhost_diag_put_hex1
    mov r2, r2, lsl #4
    subs r3, r3, #1
    bne sdhost_diag_put_hex32_loop
    pop {r0-r3, lr}
    bx lr

/* TEST-ONLY (round-trip verification for task #3, not part of the
 * driver proper): fill a buffer with a byte pattern (index & 0xFF),
 * and compare two buffers byte-for-byte.
 * void test_fill_pattern(mut ref i64 buf, i64 byte_count)
 * i64 test_compare_buffers(mut ref i64 a, mut ref i64 b, i64 byte_count)
 *   -- returns 0 if identical, else the 1-based index of the first
 *      mismatch. byte_count arrives in r2 here too (same one-ref-then-
 *      one-i64 shape as the FIFO helpers above) -- test_compare_buffers
 *      below doesn't need this note since ITS byte_count follows TWO
 *      single-register refs, landing at the already-even r2 with no
 *      padding. */
.global test_fill_pattern
test_fill_pattern:
    push {r4}
    mov r4, #0
test_fill_loop:
    cmp r4, r2
    beq test_fill_done
    and r3, r4, #0xFF
    strb r3, [r0, r4]
    add r4, r4, #1
    b test_fill_loop
test_fill_done:
    pop {r4}
    mov r0, #0
    mov r1, #0
    bx lr

/* This is the function whose missing `mov r1, #0` actually broke a
 * caller once, not just a latent risk like the others in this file:
 * with `b` (this fn's own second argument) still sitting in r1 at
 * either return point below, a caller's OWN correct 3-term `(x!=0) ||
 * (y!=0) || (z!=0)` -- where z is this function's return value --
 * saw z's high word as a live heap pointer instead of 0, made the
 * full 64-bit z nonzero even though the intended (truncated, 32-bit)
 * "0 or a 1-based mismatch index" value was genuinely 0, and forced
 * the whole OR chain true. Every symptom this produced (an aggregate
 * pass/fail flag reading true despite every individual check printing
 * 0, and the failure disappearing the instant the term selecting THIS
 * function's return value was dropped from the boolean expression
 * during bisection) pointed at the boolean-chain codegen itself before
 * the actual cause -- an ABI violation one call away -- was checked
 * directly against the disassembly. Two real bugs stacked in the same
 * investigation: the AAPCS argument-register-pairing note on
 * sdhost_drain_fifo_to_buffer above, found first, then this AAPCS
 * return-register one, found only because fixing the first wasn't
 * enough to make the round-trip test's aggregate result trustworthy. */
.global test_compare_buffers
test_compare_buffers:
    push {r4, r5}
    mov r3, #0
test_cmp_loop:
    cmp r3, r2
    beq test_cmp_equal
    ldrb r4, [r0, r3]
    ldrb r5, [r1, r3]
    cmp r4, r5
    bne test_cmp_mismatch
    add r3, r3, #1
    b test_cmp_loop
test_cmp_mismatch:
    add r0, r3, #1
    pop {r4, r5}
    mov r1, #0
    bx lr
test_cmp_equal:
    pop {r4, r5}
    mov r0, #0
    mov r1, #0
    bx lr

/* ROUND 2026-09-17 (real-hardware investigation): task #215. Real
 * Linux's bcm2835_set_clock (drivers/mmc/host/bcm2835.c) computes
 * SDCDIV from host->max_clk, which it gets via clk_get_rate() on the
 * SD core clock -- NOT a hardcoded constant. U-Boot's own
 * bcm2835_sdhost driver confirms the same shape from a bare-metal
 * context specifically: host->max_clk = bcm2835_get_mmc_clock(
 * BCM2835_MBOX_CLOCK_ID_CORE), i.e. the exact same VideoCore mailbox
 * GET_CLOCK_RATE property tag this file's sibling governor_state.S
 * already uses for SET_CLOCK_RATE (ARM clock, id 3) -- this is CORE
 * clock, id 4, read instead of written. Confirmed the property-tag ID
 * values (GET_CLOCK_RATE = 0x00030002, clock id 4 = CORE) against the
 * same class of reference governor_state.S's own header comment
 * already cites (the mailbox protocol itself, verified there against
 * QEMU's hw/misc/bcm2835_property.c) -- GET_CLOCK_RATE, unlike
 * SET_CLOCK_RATE, is NOT marked NYI in QEMU's property handler, so
 * this call gets a real (QEMU-modeled) answer under emulation too,
 * not just on real hardware.
 *
 * i64 sdhost_get_core_clock_hz() -- returns the CORE clock rate in Hz
 * on success, 0 if the mailbox call timed out or reported failure (the
 * 0 return is deliberately indistinguishable from "a real 0 Hz clock,"
 * which cannot happen for CORE on this SoC -- callers should treat 0
 * as "mailbox query failed, fall back to a conservative assumption,"
 * not as a literal clock rate). Same bounded-poll, no-hang-forever
 * discipline as governor_apply_freq_mhz below it in the sibling file. */
.section ".bss"
.align 4
sdhost_clock_mbox_buf:
    .space 32    /* 8 words -- GET_CLOCK_RATE's value buffer is only
                   * 8 bytes (clock id + rate, no third "skip turbo"
                   * word like SET_CLOCK_RATE uses), so this whole
                   * request is one word shorter than governor_
                   * apply_freq_mhz's own SET_CLOCK_RATE buffer. */

.section ".text"
.global sdhost_get_core_clock_hz
sdhost_get_core_clock_hz:
    stmdb sp!, {r4-r8, lr}

    ldr r4, =sdhost_clock_mbox_buf

    mov r7, #32
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00030002
    str r7, [r4, #8]                 /* buf[2]: tag = get clock rate */
    mov r7, #8
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    mov r7, #4
    str r7, [r4, #20]                /* buf[5]: clock id (4 = CORE) */
    mov r7, #0
    str r7, [r4, #24]                /* buf[6]: rate in Hz (response) */
    str r7, [r4, #28]                /* buf[7]: end tag */

    /* Same real DMB-before-mailbox-write requirement governor_apply_
     * freq_mhz's own comment explains in full -- a genuinely separate
     * bus master reads this buffer via its own path. */
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5

    mov r8, r4
    bic r8, r8, #0xF
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r6, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
sgcc_wait_write:
    ldr r1, [r6]
    tst r1, #0x80000000              /* FULL */
    beq sgcc_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt sgcc_wait_write
    mov r0, #0                       /* timed out -- 0 = "query failed" */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

sgcc_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
sgcc_wait_read:
    ldr r1, [r6]
    tst r1, #0x40000000              /* EMPTY */
    bne sgcc_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8                       /* is this response ours? */
    beq sgcc_got_response
sgcc_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt sgcc_wait_read
    mov r0, #0                       /* timed out */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr

sgcc_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    bne sgcc_failed                  /* VideoCore reported failure */
    ldr r0, [r4, #24]                /* buf[6]: rate in Hz */
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
sgcc_failed:
    mov r0, #0
    mov r1, #0
    ldmia sp!, {r4-r8, lr}
    bx lr
