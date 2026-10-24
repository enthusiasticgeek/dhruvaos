#!/usr/bin/env python3
"""Static safety audit for DhruvaOS's hand-written ARM assembly (boot/*.S)
and its own #[stack_cost(...)] declarations in kernel_main.vani.

Built 2026-09-27 after finding the SAME bug twice in one session in newly
written assembly (boot/dma_uart_state.S): a function loaded a register,
called mem_barrier (which unconditionally zeroes r0/r1 on return per its
own documented contract), then used the now-clobbered register -- and,
separately, four new extern fn declarations were given a copy-pasted
#[stack_cost(bytes=1)] that didn't match their real push {...} byte count.
Both bugs would have been invisible to a normal build+QEMU+phase4_milestone
pass (they don't crash, they just silently misbehave or under-report a
safety-relevant number) -- exactly the kind of thing worth a permanent,
re-runnable check rather than a one-time manual read, given this project's
own asm footprint (73 files, ~19k lines) is far past what a single manual
pass reliably catches.

This is a heuristic, line-oriented scanner, not a real disassembler or a
full register-liveness analysis -- it deliberately errs toward flagging
ambiguous cases for human review rather than silently missing them, and
callers should read the CONFIDENCE field on each finding before acting.
False positives are expected and fine; false silence is not.

Checks:
  1. CLOBBER-AFTER-CALL: a `bl <target>` whose target is a KNOWN clobberer
     of r0/r1 (currently just mem_barrier, which is fully understood --
     see boot/context_switch.S), followed by a read of the clobbered
     register before it's freshly reloaded/computed.
  2. STACK-IMBALANCE: within one function (from a .global label to the
     next label at the same or lower indent), every `push {reglist}` /
     `pop {reglist}` pair on a given code path should use the SAME
     register set. Flags any pop whose list doesn't match some preceding
     push in the same function, and any push with no matching pop at all
     reachable exit paths.
  3. STACK-COST-MISMATCH: cross-references every
     `#[stack_cost(bytes=N)] extern "C" fn NAME(...)` in kernel_main.vani
     against NAME's own first `push {reglist}` in whichever .S file
     defines it (via `.global NAME` / `NAME:`), flagging a mismatch.

Usage: python3 test/asm_safety_audit.py [--boot-dir DIR] [--vani FILE]
"""
import argparse
import glob
import os
import re
import sys

REG_RE = re.compile(r"\br(?:1[0-4]|[0-9])\b")


def regs_in(line: str):
    """Full 'rN' tokens present on a line -- NOT REG_RE.findall(), which
    (a real bug caught by this tool auditing itself, see docs/TODO.md's
    own commit history) returns only the captured digit when REG_RE has
    a capturing group, silently breaking every membership check against
    it. Kept as a free function so there is exactly one place this can
    go wrong again."""
    return [m.group(0) for m in REG_RE.finditer(line)]
PUSH_RE = re.compile(r"^\s*(?:push\s*\{([^}]*)\}|stmdb\s+sp!\s*,\s*\{([^}]*)\})")
POP_RE = re.compile(r"^\s*(?:pop\s*\{([^}]*)\}|ldmia\s+sp!\s*,\s*\{([^}]*)\})")
BL_RE = re.compile(r"^\s*bl\s+([A-Za-z_][A-Za-z0-9_]*)")
LABEL_RE = re.compile(r"^([A-Za-z_.][A-Za-z0-9_.]*):\s*$")
GLOBAL_RE = re.compile(r"^\s*\.global\s+([A-Za-z_][A-Za-z0-9_]*)")


def push_pop_reglist(m):
    """2026-10-23 audit fix: PUSH_RE/POP_RE now match TWO mnemonic
    forms each (push/stmdb-sp! and pop/ldmia-sp! respectively) --
    `stmdb sp!, {...}`/`ldmia sp!, {...}` is ARM's other, equally
    common full-descending-stack idiom for exactly the same save/
    restore role as the push/pop pseudo-instructions, used throughout
    this codebase's own mailbox-protocol functions and others, but
    NEVER recognized by either regex before this fix -- every one of
    those functions was silently invisible to scan_stack_balance AND
    (once added, same round) scan_unsaved_callee_saved_clobber, both
    of which only skip a function when there is NOTHING to check,
    which is exactly the wrong failure mode for a safety tool. Each
    regex now has two alternate capture groups (one per mnemonic
    form); exactly one is ever populated per match. This helper picks
    whichever one matched."""
    return m.group(1) if m.group(1) is not None else m.group(2)


def expand_reglist(raw: str):
    """Expand a push/pop/stmdb/ldmia register-list string into the
    individual register names it covers, including ARM's own range
    shorthand (`r4-r8` means r4,r5,r6,r7,r8) -- 2026-10-23 audit fix,
    added alongside the stmdb/ldmia recognition above: several real
    reglists in this codebase use range notation (e.g. `{r4-r8, lr}`),
    which a naive comma-split would treat as one opaque token instead
    of the 5 individual registers it actually covers, defeating any
    later per-register membership check (exactly what scan_unsaved_
    callee_saved_clobber needs to get right)."""
    regs = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        rng = re.match(r"^r(\d+)\s*-\s*r(\d+)$", tok)
        if rng:
            lo, hi = int(rng.group(1)), int(rng.group(2))
            regs.extend(f"r{n}" for n in range(lo, hi + 1))
        else:
            regs.append(tok)
    return frozenset(regs)

# Functions whose full register-clobber contract is directly known (read
# from their own source, not guessed) -- extend this table deliberately,
# one entry at a time, only for functions actually verified by reading
# their own definition. Value = set of registers clobbered (given fresh,
# unpredictable values) on return.
KNOWN_CLOBBERERS = {
    "mem_barrier": {"r0", "r1"},
    "mem_barrier_dmb": {"r0", "r1"},  # 2026-10-23, same r0/r1-only
    # contract as mem_barrier -- verified by reading its own
    # definition (boot/context_switch.S), not guessed.
}

# Per-mnemonic operand read/write roles. This replaced a first attempt
# that just checked "does the register name appear anywhere on the
# line" -- which this tool's own self-test (running it against the
# EXACT bug it was built to catch) caught as producing false positives
# on lines like `ldr r0, =symbol` (a pure write to r0 -- the OLD value
# of r0 is never read) and `and r0, r4, #1` (r0 here is the
# destination, not a source -- r4 is what's read). Ordinary ARM
# encodings: for a WRITE_FIRST_ONLY mnemonic, operand 0 is a pure
# write UNLESS it recurs among the later operands; a base register
# inside `[...]` is always a read regardless of mnemonic.
WRITE_FIRST_ONLY_MNEMONICS = {"mov", "movw", "movt", "mvn", "ldr", "ldrb", "ldrh", "ldrsb", "ldrsh"}
READ_ALL_MNEMONICS = {"str", "strb", "strh", "cmp", "cmn", "tst", "teq", "bx", "blx"}
WRITE_FIRST_THEN_READ_MNEMONICS = {
    "add", "sub", "and", "orr", "eor", "bic", "mul", "lsl", "lsr", "asr",
    "ror", "rsb", "adc", "sbc", "rsc", "orn",
}


def instr_reads_register(line: str, reg: str) -> bool:
    """Does this instruction line read `reg` as an operand (i.e. use its
    value from BEFORE this instruction), as opposed to only writing a
    fresh value into it? Deliberately conservative on anything not
    explicitly classified below (defaults to "yes, treat as a read") --
    false positives get a human's attention; false negatives hide a
    real bug, which is the worse failure mode for a safety tool."""
    stripped = line.strip()
    if not stripped or stripped.startswith(("/*", "*", "//", ".")):
        return False

    bracket = re.search(r"\[([^\]]*)\]", stripped)
    if bracket and reg in regs_in(bracket.group(1)):
        return True  # base/offset register inside [...] is always read

    parts = stripped.split(None, 1)
    if not parts:
        return False
    mnemonic = parts[0]
    operand_text = parts[1] if len(parts) > 1 else ""
    # Strip a bracketed portion from the operand list for the
    # "does reg recur among the operands" checks below -- already
    # handled by the bracket check above.
    operand_text_no_brackets = re.sub(r"\[[^\]]*\]", "", operand_text)
    operands = [o.strip() for o in operand_text_no_brackets.split(",") if o.strip()]

    pushm = PUSH_RE.match(stripped)
    if pushm:
        return reg in expand_reglist(push_pop_reglist(pushm))
    if POP_RE.match(stripped):
        return False  # pop only WRITES registers

    base_mnemonic = mnemonic.rstrip("s")  # crude S-flag strip (adds/subs/movs)
    for table, mode in (
        (WRITE_FIRST_ONLY_MNEMONICS, "write_first_only"),
        (READ_ALL_MNEMONICS, "read_all"),
        (WRITE_FIRST_THEN_READ_MNEMONICS, "write_first_then_read"),
    ):
        if mnemonic in table or base_mnemonic in table:
            if mode == "read_all":
                return reg in regs_in(operand_text_no_brackets)
            if not operands:
                return False
            dest_is_reg = REG_RE.fullmatch(operands[0]) is not None
            if not dest_is_reg:
                return reg in regs_in(operand_text_no_brackets)
            rest_regs = regs_in(",".join(operands[1:]))
            if operands[0] == reg:
                # Rd == reg: for write_first_only, a pure write UNLESS
                # reg also recurs later (e.g. "mov r0, r0"); for
                # write_first_then_read, likewise a pure write unless
                # it recurs (e.g. "add r0, r0, #4" DOES read r0).
                return reg in rest_regs
            return reg in rest_regs
    # Unclassified mnemonic (conditional-suffix variants, anything not
    # listed above) -- conservative default: any occurrence is a read.
    return reg in regs_in(operand_text_no_brackets)


def scan_clobber_after_call(lines, fname):
    findings = []
    for i, raw in enumerate(lines):
        m = BL_RE.match(raw)
        if not m:
            continue
        target = m.group(1)
        clobbered = KNOWN_CLOBBERERS.get(target)
        if not clobbered:
            continue
        # Walk forward until the clobbered registers are all either
        # freshly redefined or the function returns / branches away.
        still_live = set(clobbered)
        for j in range(i + 1, min(i + 12, len(lines))):
            nxt = lines[j].strip()
            if not nxt or nxt.startswith("/*") or nxt.startswith("*") or nxt.startswith("//"):
                continue
            if nxt.startswith("bx ") or nxt.startswith("b ") or re.match(r"^\w+:$", nxt):
                break
            for reg in list(still_live):
                if reg in regs_in(nxt):
                    if instr_reads_register(nxt, reg):
                        findings.append({
                            "file": fname,
                            "line": j + 1,
                            "confidence": "DEFINITE" if reg in ("r0", "r1") else "REVIEW",
                            "summary": f"'{nxt}' reads {reg} shortly after `bl {target}` (line {i+1}), which unconditionally clobbers {reg}",
                        })
                        still_live.discard(reg)
                    elif nxt.split()[0] in ("mov", "ldr", "and", "orr", "add", "sub", "mvn") and nxt.split(",")[0].strip().endswith(reg):
                        # a fresh definition of reg -- no longer live-stale
                        still_live.discard(reg)
            if not still_live:
                break
    return findings


def get_function_blocks(lines):
    """Split a file's lines into (func_name, start_idx, end_idx) blocks,
    one per .global label, ending at the next .global label or EOF."""
    globals_at = []
    for i, raw in enumerate(lines):
        m = GLOBAL_RE.match(raw)
        if m:
            globals_at.append((m.group(1), i))
    blocks = []
    for idx, (name, start) in enumerate(globals_at):
        end = globals_at[idx + 1][1] if idx + 1 < len(globals_at) else len(lines)
        blocks.append((name, start, end))
    return blocks


def get_function_body_lines(lines, name, start, end):
    """Shared function-extent walker, factored out of scan_stack_balance
    (2026-10-23, same audit round that found this tool's own
    KNOWN_CLOBBERERS/stack-balance coverage gap for brand-new hand-
    written functions) so scan_unsaved_callee_saved_clobber below can
    reuse the exact same, carefully-reasoned scope instead of a cruder
    .global-to-next-.global span. See scan_stack_balance's own
    (unchanged) header comment for the full "why" of this exact
    scoping rule."""
    idx = start
    included = []
    while idx < end:
        included.append(idx)
        stripped = lines[idx].strip()
        if stripped == "bx lr" or re.match(r"^mov\s+pc\s*,\s*lr$", stripped):
            idx += 1
            j = idx
            while j < end and not lines[j].strip():
                j += 1
            if j < end:
                lm = LABEL_RE.match(lines[j].strip())
                if lm and lm.group(1).startswith(name + "_"):
                    idx = j
                    continue
            break
        idx += 1
    return included


def scan_stack_balance(lines, fname):
    """Push/pop balance, scoped to a function's OWN extent -- caught by
    this tool's own self-test: the naive .global-to-next-.global span
    can be far larger than the real function (an unrelated LATER
    function with no .global marker of its own can sit inside that
    span), and for THIS check that bias is dangerous in the SILENT
    direction -- a stray pop from that unrelated function can
    spuriously 'match' a real push here and mask a genuine imbalance,
    exactly the failure mode a safety tool must not have. Scope:
    the entry block up to this function's own first `bx lr`, PLUS any
    secondary exit-label blocks that follow this project's own
    established naming convention (e.g. `dma_uart_tx_start_noop:`,
    `dma_uart_tx_start_busy:` -- a label prefixed with the function's
    own name) up to THEIR own first `bx lr`. Stops at the first label
    that does NOT match this convention, treating it as a genuinely
    different function even without its own .global -- a known,
    documented narrowing (a function whose secondary exit labels don't
    follow this naming convention only gets its entry block checked),
    preferred over silently trusting an oversized span."""
    findings = []
    for name, start, end in get_function_blocks(lines):
        pushes = []
        pops = []
        included = get_function_body_lines(lines, name, start, end)
        for i in included:
            pm = PUSH_RE.match(lines[i])
            if pm:
                pushes.append((i + 1, expand_reglist(push_pop_reglist(pm))))
            pom = POP_RE.match(lines[i])
            if pom:
                pops.append((i + 1, expand_reglist(push_pop_reglist(pom))))
        if not pushes and not pops:
            continue
        push_regsets = {r for _, r in pushes}
        for line_no, regs in pops:
            if regs not in push_regsets:
                findings.append({
                    "file": fname,
                    "line": line_no,
                    "confidence": "REVIEW",
                    "summary": f"function '{name}': pop {{{', '.join(sorted(regs))}}} doesn't match any push {{...}} seen earlier in this function ({[sorted(r) for _, r in pushes]})",
                })
        if pushes and not pops:
            findings.append({
                "file": fname,
                "line": pushes[0][0],
                "confidence": "REVIEW",
                "summary": f"function '{name}': push {{{', '.join(sorted(pushes[0][1]))}}} at line {pushes[0][0]} has no matching pop anywhere in this function",
            })
    return findings


CALLEE_SAVED_REGS = ("r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11")


def instr_writes_register(line: str, reg: str) -> bool:
    """Does this instruction WRITE a fresh value into `reg` (as its
    destination)? Built for scan_unsaved_callee_saved_clobber below --
    deliberately the OPPOSITE conservative bias from instr_reads_
    register: that function defaults unclassified mnemonics to "yes,
    treat as a read" (a false negative there hides a real bug);
    defaulting unclassified mnemonics to "yes, this writes it" HERE
    would instead flood the REVIEW list with noise on every harmless
    `cmp`/`tst`/`bl`/`b` line that never touches r4-r11 as a
    destination at all, drowning out the real findings -- so this one
    defaults to NO for anything not an explicitly recognized
    destination-writing mnemonic."""
    stripped = line.strip()
    if not stripped or stripped.startswith(("/*", "*", "//", ".")):
        return False
    pom = POP_RE.match(stripped)
    if pom:
        return reg in expand_reglist(push_pop_reglist(pom))
    parts = stripped.split(None, 1)
    if not parts:
        return False
    mnemonic = parts[0]
    base_mnemonic = mnemonic.rstrip("s")
    operand_text = parts[1] if len(parts) > 1 else ""
    operand_text_no_brackets = re.sub(r"\[[^\]]*\]", "", operand_text)
    operands = [o.strip() for o in operand_text_no_brackets.split(",") if o.strip()]
    if not operands:
        return False
    if (mnemonic in WRITE_FIRST_ONLY_MNEMONICS or base_mnemonic in WRITE_FIRST_ONLY_MNEMONICS
            or mnemonic in WRITE_FIRST_THEN_READ_MNEMONICS or base_mnemonic in WRITE_FIRST_THEN_READ_MNEMONICS):
        return operands[0] == reg
    if mnemonic in ("ldmia", "ldmdb", "ldm", "ldmfd"):
        m = re.search(r"\{([^}]*)\}", stripped)
        if m:
            return reg in [r.strip() for r in m.group(1).split(",")]
    return False


def scan_unsaved_callee_saved_clobber(lines, fname):
    """2026-10-23 audit fix: the exact gap scan_stack_balance's own
    `if not pushes and not pops: continue` line leaves open -- a
    function with ZERO push/pop ANYWHERE gets no stack-balance finding
    at all, regardless of what it does to r4-r11, because there is
    nothing for that check to compare against. This project has hit
    exactly this shape of AAPCS violation (hand-written asm clobbers a
    callee-saved register a vani/LLVM-compiled caller keeps a live
    value in, with no save/restore) at least three times (round 53:
    dhruva_prio_lock; round 72: fw_add_rule; round 75: scheduler_pick_
    next) -- all three were functions that DID push/pop something,
    just not the SPECIFIC register that turned out to be live; this
    check targets the narrower but equally real sibling: a brand-new
    function with NO save/restore convention at all. mem_barrier/
    mem_barrier_dmb are the deliberate, correct, already-verified
    exception -- they use ONLY r0/r1 (caller-saved under AAPCS, safe
    to clobber with no save) -- so only r4-r11 are checked here."""
    findings = []
    for name, start, end in get_function_blocks(lines):
        included = get_function_body_lines(lines, name, start, end)
        if any(PUSH_RE.match(lines[i]) or POP_RE.match(lines[i]) for i in included):
            continue  # scan_stack_balance already covers this function
        reported = set()
        for i in included:
            for reg in CALLEE_SAVED_REGS:
                if reg in reported:
                    continue
                if instr_writes_register(lines[i], reg):
                    reported.add(reg)
                    findings.append({
                        "file": fname,
                        "line": i + 1,
                        "confidence": "REVIEW",
                        "summary": (
                            f"function '{name}' writes callee-saved {reg} with NO "
                            f"push/pop anywhere in the function -- verify this is an "
                            f"intentional, documented scratch-register convention "
                            f"(like mem_barrier's own r0/r1-only contract) or add the "
                            f"missing save/restore (AAPCS requires r4-r11 to survive "
                            f"a call unless the caller is proven not to rely on it)"
                        ),
                    })
    return findings


def compute_stack_cost_bytes(lines, fname_hint=None):
    """Real byte cost of the FIRST push{...} seen (matching this
    project's own established convention: declared cost = the pushed
    register count * 4, for the function's own frame). Deliberately
    stops at this function's OWN first return instruction (`bx lr` or
    `mov pc, lr`) -- caught by this tool's own self-test: `.global`-to-
    next-`.global` blocks can be much larger than the actual function
    (a long stretch of code with no .global marker of its own sits
    between two real, unrelated functions), so scanning the WHOLE block
    can pick up a LATER, unrelated function's own push. A function's
    own entry-level push (if any) always occurs before its own first
    return, regardless of how generously the block was bounded."""
    for raw in lines:
        stripped = raw.strip()
        pm = PUSH_RE.match(raw)
        if pm:
            # 2026-10-23 audit fix: expand_reglist (not a bare comma
            # split) so a range-notation push like `{r4-r8, lr}`
            # correctly counts as 6 registers (24 bytes), not 2 (the
            # literal "r4-r8"/"lr" token count) -- the bare split was
            # silently undercounting every such push's real stack
            # cost before this fix.
            return len(expand_reglist(push_pop_reglist(pm))) * 4
        if stripped == "bx lr" or re.match(r"^mov\s+pc\s*,\s*lr$", stripped):
            return 0
    return 0


def find_function_definition(name, boot_files_cache):
    for fname, lines in boot_files_cache.items():
        for i, raw in enumerate(lines):
            if raw.strip() == f"{name}:":
                # function body runs until the next top-level label
                blocks = get_function_blocks(lines)
                for bname, start, end in blocks:
                    if bname == name:
                        return fname, lines[start:end]
                # not a .global function (local label) -- just take from
                # here to the next blank-preceded label as a rough body
                return fname, lines[i:i + 60]
    return None, None


def scan_stack_cost_mismatches(vani_path, boot_files_cache):
    findings = []
    with open(vani_path, "r", errors="replace") as f:
        vani_lines = f.readlines()
    pending_cost = None
    for i, raw in enumerate(vani_lines):
        sc = re.match(r'\s*#\[stack_cost\(bytes=(\d+)\)\]', raw)
        if sc:
            pending_cost = int(sc.group(1))
            continue
        fn = re.match(r'\s*extern\s+"C"\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', raw)
        if fn and pending_cost is not None:
            name = fn.group(1)
            src_file, body = find_function_definition(name, boot_files_cache)
            if body is not None:
                real_cost = compute_stack_cost_bytes(body)
                # Only an UNDERESTIMATE (real > declared) is a safety
                # issue -- it means this project's own static worst-case
                # stack-depth analysis trusts a number smaller than what
                # this function actually pushes. A declared cost that is
                # equal to or larger than the real push count is safe
                # (conservative or exact), including the common
                # "bytes=1" placeholder on a real zero-push accessor --
                # not a finding, not even noise.
                if real_cost > pending_cost:
                    findings.append({
                        "file": f"kernel_main.vani (fn {name}, defined in {os.path.basename(src_file)})",
                        "line": i + 1,
                        "confidence": "DEFINITE",
                        "summary": f"UNDERESTIMATE: #[stack_cost(bytes={pending_cost})] declared for '{name}', but its own first push{{...}} in {os.path.basename(src_file)} pushes {real_cost} bytes -- static stack-depth analysis trusts a number smaller than reality",
                    })
            pending_cost = None
        elif fn:
            pending_cost = None
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot-dir", default=os.path.join(os.path.dirname(__file__), "..", "boot"))
    ap.add_argument("--vani", default=os.path.join(os.path.dirname(__file__), "..", "kernel", "kernel_main.vani"))
    args = ap.parse_args()

    boot_files = sorted(glob.glob(os.path.join(args.boot_dir, "**", "*.S"), recursive=True))
    boot_files_cache = {}
    for fp in boot_files:
        with open(fp, "r", errors="replace") as f:
            boot_files_cache[fp] = f.readlines()

    all_findings = []
    for fp, lines in boot_files_cache.items():
        rel = os.path.relpath(fp, os.path.dirname(args.boot_dir))
        all_findings.extend(scan_clobber_after_call(lines, rel))
        all_findings.extend(scan_stack_balance(lines, rel))
        all_findings.extend(scan_unsaved_callee_saved_clobber(lines, rel))

    if os.path.exists(args.vani):
        all_findings.extend(scan_stack_cost_mismatches(args.vani, boot_files_cache))
    else:
        print(f"WARNING: {args.vani} not found, skipping stack-cost cross-reference", file=sys.stderr)

    definite = [f for f in all_findings if f["confidence"] == "DEFINITE"]
    review = [f for f in all_findings if f["confidence"] == "REVIEW"]

    print(f"Scanned {len(boot_files)} .S files.")
    print(f"\n=== DEFINITE ({len(definite)}) ===")
    for f in definite:
        print(f"  [{f['file']}:{f['line']}] {f['summary']}")
    print(f"\n=== REVIEW ({len(review)}) ===")
    for f in review:
        print(f"  [{f['file']}:{f['line']}] {f['summary']}")

    return 1 if definite else 0


if __name__ == "__main__":
    sys.exit(main())
