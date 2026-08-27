#!/usr/bin/env bash
# Phase 4 task #9: drive Dhruva's interactive shell over QEMU's stdio
# UART using the bash-coprocess input method.
#
# STATUS (2026-08-26): this script is believed CORRECT but could not be
# confirmed to actually exercise the shell in this sandbox. A raw
# hardware-level poll of both BCM2835 UART peripherals' RX status
# registers (added directly to kernel_main.vani as a temporary probe,
# since removed) showed zero bytes EVER arriving at either UART's FIFO
# under this sandbox's QEMU, across every input method tried (a bash
# coprocess pipe, a raw-mode PTY, sustained slow character streams,
# multiple -serial/-nographic flag combinations) -- while TX has
# worked flawlessly all session. That is a QEMU/environment-level
# input-delivery gap, not a bug in Dhruva's UART RX code (irq_dispatch,
# shell_rx_push_char, task_f) or in this script: see
# project_dhruva_os_architecture_2026_08_24.md's task #9 writeup for
# the full chain of evidence. Every substring check below is applied
# to ONLY the portion of the log strictly after the PASS line -- the
# boot-time self-test prints "/config/mode", "not found", etc. on its
# own before the shell ever runs a single command, and task_e's own
# periodic "GC: compaction pass, /config/mode = ..." message is an
# equally real false-positive risk for an unanchored "/config/mode"
# check, which is why that one specifically requires the shell's own
# two-space list-item indent ("  /config/mode") rather than the bare
# substring.
set -u

ELF="/home/virgo/source/dhruvaos/build/dhruva.elf"
IMG="/tmp/dhruva_shell_check.img"
LOG="/tmp/shell_interactive_check_sh.log"

dd if=/dev/zero of="$IMG" bs=1M count=64 status=none

send() {
  printf '%s\r' "$1"
}

(
  sleep 15
  send "ls"
  sleep 6
  send "cat /config/mode"
  sleep 6
  send "write /shell/test hello-shell"
  sleep 6
  send "cat /shell/test"
  sleep 6
  send "ls"
  sleep 6
  send "rm /shell/test"
  sleep 6
  send "cat /shell/test"
  sleep 6
  send "bogus"
  sleep 6
) | timeout --kill-after=10 75 qemu-system-arm -M raspi1ap -nographic \
      -kernel "$ELF" \
      -drive "file=$IMG,if=sd,format=raw,cache=writethrough" \
      > "$LOG" 2>&1

after_pass() {
  awk '/^PASS$/{f=1; next} f' "$LOG"
}

check() {
  local name="$1" expect="$2"
  if after_pass | grep -qF "$expect"; then
    echo "[PASS] $name"
  else
    echo "[FAIL] $name"
    all_ok=0
  fi
}

all_ok=1
if grep -qx "PASS" "$LOG"; then
  echo "[PASS] boot reaches PASS"
else
  echo "[FAIL] boot reaches PASS"
  all_ok=0
fi
check "ls shows /config/mode" "  /config/mode"
check "cat /config/mode == post-compact-2" "post-compact-2"
check "write /shell/test ok" "ok"
check "cat /shell/test == hello-shell" "hello-shell"
check "ls shows /shell/test" "  /shell/test"
check "rm /shell/test ok" "ok"
check "cat /shell/test after rm == not found" "not found"
check "bogus == unknown command" "unknown command"

boot_banners=$(grep -c "Dhruva Phase 2" "$LOG")
echo "boot banners (expect 1, i.e. no crash/reboot): $boot_banners"
if [ "$boot_banners" != "1" ]; then
  all_ok=0
fi

echo "Full log: $LOG"
exit $((1 - all_ok))
