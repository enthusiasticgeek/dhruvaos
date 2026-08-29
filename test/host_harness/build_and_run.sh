#!/bin/bash
# Host-side ASAN/UBSAN test harness for DharaFS + crypto/bignum logic
# in kernel_main.vani. Regenerates kernel_gen.c from the CURRENT
# source every run -- this tests whatever kernel_main.vani says today,
# never a stale snapshot. See host_main.c's own header comment for
# what this can and can't reach (no MMIO-touching code paths -- those
# can't be intercepted host-side at all, see unstatic.py and
# kernel_main.vani's own comment on the dev==2 test-only backend).
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
VANIC="$REPO_ROOT/../vani-compiler/target/release/vanic"
if [ ! -x "$VANIC" ]; then
    VANIC="vanic"
fi

echo "[host_harness] emitting C from kernel/kernel_main.vani..."
"$VANIC" emit "$REPO_ROOT/kernel/kernel_main.vani" --backend=c -o kernel_gen.c

echo "[host_harness] patching generated C (un-static whitelisted functions)..."
python3 unstatic.py kernel_gen.c kernel_gen_patched.c

CC=gcc
if ! command -v gcc >/dev/null 2>&1; then
    CC=clang
fi

echo "[host_harness] compiling with $CC -fsanitize=address,undefined ..."
"$CC" -fsanitize=address,undefined -g -O1 -w \
    kernel_gen_patched.c host_stubs.c host_main.c -o harness

echo "[host_harness] running..."
ASAN_OPTIONS=detect_leaks=0 exec ./harness
