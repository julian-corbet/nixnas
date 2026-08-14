#!/usr/bin/env bash
# test/upgrade-soak-test.sh — generation soak: N=5 upgrade cycles, UKI pruning proof,
#                              per-cycle store-growth table.
#
# THE CLAIM UNDER TEST: switch-to-configuration boot + lanzaboote correctly manage N=5
# successive generation upgrades while obeying keepGenerations=3. Per-cycle assertions:
#   (a) "boots newest" — /etc/nixnas-soak-gen == expected generation number.
#   (b) ESP UKI count == min(cycle + 1, keepGenerations=3) — lzbt's configurationLimit
#       GC evicts old UKIs once the window is full (the interesting half: cycles 3-5).
#   (c) bootctl list entry count matches the expected UKI count.
#   (d) Per-cycle /nix/store growth is bounded (trivially-varied toplevels share the
#       entire base closure; unique paths per generation are near-zero).
#
# MECHANISM — why specialisations, not nixos-rebuild:
#   Generations 2-6 are specialisations of nixosConfigurations.demo-upgrade-soak
#   (hosts/demo-upgrade-soak.nix), each differing in one text file (/etc/nixnas-soak-gen).
#   They are pre-built on the test runner as part of the soak toplevel's closure, then
#   nix-copied into the VM over SSH.  The VM needs no network access and does no Nix
#   evaluation — the specialisation toplevels arrive from the local flake closure.
#   Specialisations are valid NixOS toplevels; switch-to-configuration handles them
#   natively.  This is cheaper and sounder than in-VM nixos-rebuild (which would need
#   nixpkgs in the store and/or network) and sounder than patching the toplevel tree
#   (which could invalidate switch-to-configuration's assumptions).
#
# BOOT SEQUENCE (7 boots total):
#   Bootstrap — boot Secure-Boot-capable OVMF in Setup Mode, prove that the only
#               expected red unit is the pre-enrollment Secure Boot verifier, enroll the
#               appliance keys, discard the identity sealed against the old PCR 7, power off.
#   Baseline  — boot with Secure Boot enforced, seal the SSH identity at the final PCR 7,
#               wait for the write-isolation verifier, nix copy, record baseline, stage cycle 1.
#   Boots 1-5 — one per cycle: initrd-SSH (sealed host key) → deliver passphrase over SSH,
#               wait for running system, assert, record du, stage next cycle.
#
# Needs no root on the host: the VM runs as the current user (KVM group access is enough).
# Usage: [FLAKE=.] [PASS=nixnas-demo] test/upgrade-soak-test.sh <image.raw> [--port 2224]
set -uo pipefail

FLAKE="${FLAKE:-.}"
PASS="${PASS:-nixnas-demo}"
IMG="${1:?usage: upgrade-soak-test.sh <image.raw> [--port PORT]}"; shift || true
PORT=2224     # SSH forward; default avoids clash with seal-3boot-test.sh (2222)
while [ $# -gt 0 ]; do case "$1" in
  --port) PORT="$2"; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
for c in nix qemu-system-x86_64 swtpm; do
  command -v "$c" >/dev/null || { echo "!! missing tool: $c" >&2; exit 1; }
done

N=5          # upgrade cycles
KEEP=3       # must match nixnas.boot.keepGenerations in hosts/demo-upgrade-soak.nix
STORE_GROWTH_LIMIT_MIB=200   # per-cycle /nix/store delta bound (trivial toplevel delta)

# ── OVMF firmware detection — portable across distros (same contract as seal-3boot-test.sh) ──
find_fw() { # find_fw "name1 name2 …" → prints first existing path under the known dirs
  local d n
  for d in /usr/share/edk2-ovmf/x64 /usr/share/edk2/x64 /usr/share/OVMF /usr/share/ovmf/x64 /usr/share/qemu; do
    for n in $1; do [ -e "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }; done
  done
  return 1
}
OVMF_CODE="${OVMF_CODE:-$(find_fw 'OVMF_CODE.secboot.4m.fd OVMF_CODE_4M.secboot.fd OVMF_CODE.secboot.fd OVMF_CODE.4m.fd OVMF_CODE_4M.fd OVMF_CODE.fd')}" \
  || { echo "OVMF_CODE firmware not found (install edk2-ovmf / ovmf, or set \$OVMF_CODE)" >&2; exit 1; }
OVMF_VARS_TMPL="${OVMF_VARS:-$(find_fw 'OVMF_VARS.4m.fd OVMF_VARS_4M.fd OVMF_VARS.fd')}" \
  || { echo "OVMF_VARS template not found (set \$OVMF_VARS)" >&2; exit 1; }

# Fail fast if the SSH-forward port is already taken.
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "!! port ${PORT} is already in use. Free it or pass --port. Aborting." >&2; exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# Failed-units gate (assert_no_failed_units*): systemctl --failed must be EMPTY on every
# booted system we reach over SSH. Allowlist: NIXNAS_FAILED_UNITS_ALLOWLIST (default empty).
. "$HERE/assert-no-failed-units.sh"
WORK="$(mktemp -d /tmp/nixnas-soak.XXXXXX)"
KEY="$WORK/demo_key"
install -m600 "$HERE/ssh/demo_key" "$KEY"
SCRATCH="$WORK/disk.raw"
SWTPM_PID=""
VM_PIDS=()

# shellcheck disable=SC2329  # invoked by trap EXIT
cleanup() {
  local pid
  for pid in "${VM_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ":${PORT} " || break; sleep 0.3; done
  rm -rf "$WORK"
}
trap cleanup EXIT

echo ">> preparing writable scratch (original image untouched) ..."
cp --sparse=always "$IMG" "$SCRATCH"
chmod u+rw "$SCRATCH"
cp "$OVMF_VARS_TMPL" "$WORK/OVMF_VARS.fd"   # persistent UEFI vars across all boots
chmod u+w "$WORK/OVMF_VARS.fd"
mkdir -p "$WORK/tpm"

start_swtpm() { # start_swtpm [statedir]  — fresh process, same persistent tpmstate
  local dir="${1:-$WORK/tpm}"
  mkdir -p "$dir"
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  rm -f "$dir/sock" "$dir/pid"
  swtpm socket --tpm2 --tpmstate dir="$dir" \
    --ctrl type=unixio,path="$dir/sock" --pid file="$dir/pid" --daemon
  for _ in $(seq 1 25); do [ -S "$dir/sock" ] && break; sleep 0.2; done
  SWTPM_PID="$(cat "$dir/pid")"
}

SSH=(ssh -i "$KEY" -p "$PORT"
     -o IdentitiesOnly=yes
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=4 root@127.0.0.1)

run_qemu() { # (reads stdin; caller attaches a FIFO or /dev/null; redirects stdout to the log)
  # The caller backgrounds this function; exec makes $! QEMU itself for exact cleanup.
  exec qemu-system-x86_64 \
    -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 \
    -global ICH9-LPC.disable_s3=1 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd" \
    -chardev socket,id=chrtpm,path="$WORK/tpm/sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -drive if=virtio,format=raw,file="$SCRATCH" \
    -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device virtio-net,netdev=n0 \
    -no-reboot -nographic -serial "mon:stdio"
}

# wait_running — blocks until the running-system sshd is up (not just initrd-SSH).
# /boot/EFI/Linux is mounted from the ESP only after stage-2 activation; this check
# therefore passes only once the system has fully booted past switch-root.
wait_running() { # wait_running <vm-pid> <label>
  local vpid="$1" label="$2" ok=0
  for _ in $(seq 1 90); do
    kill -0 "$vpid" 2>/dev/null || { echo "!! ${label}: VM exited early" >&2; return 1; }
    "${SSH[@]}" -o BatchMode=yes "test -d /boot/EFI/Linux" 2>/dev/null && { ok=1; break; }
    sleep 4
  done
  [ "$ok" = 1 ] || { echo "!! ${label}: running-system SSH never came up" >&2; return 1; }
}

# Running-system SSH becomes reachable before the DEV oneshots necessarily finish. Starting
# `nix copy` while nixnas-verify-writes samples /sys/block/vda/stat makes a correct verifier
# fail. Wait for its success marker and for nixboot-verify to have exited before the harness
# performs any guest writes or checks failed-unit state.
wait_verifiers() { # wait_verifiers <label>
  local label="$1"
  if "${SSH[@]}" -o BatchMode=yes '
    for _ in $(seq 1 90); do
      write_done=0
      boot_done=0
      journalctl -b -u nixnas-verify-writes.service -o cat --no-pager 2>/dev/null \
        | grep -Fq "=== NIXNAS-WRITES-END ===" && write_done=1
      [ "$(systemctl show --value -p ExecMainCode nixboot-verify.service 2>/dev/null)" != 0 ] \
        && boot_done=1
      [ "$write_done" = 1 ] && [ "$boot_done" = 1 ] && exit 0
      systemctl is-failed --quiet nixnas-verify-writes.service && exit 1
      sleep 2
    done
    exit 1
  '; then
    return 0
  fi
  echo "!! ${label}: stage-2 verifiers did not finish successfully" >&2
  "${SSH[@]}" -o BatchMode=yes '
    systemctl status --no-pager -l nixnas-verify-writes.service nixboot-verify.service || true
    journalctl -b --no-pager -u nixnas-verify-writes.service -u nixboot-verify.service || true
  ' 2>&1 | sed 's/^/   /' || true
  return 1
}

# The soak specialisations deliberately contain only the production appliance modules, not
# demo-only verify-writes.nix. Their readiness contract is therefore the real boot verifier,
# whose completed ExecMain state must be observed before the cycle assertions run.
wait_boot_verifier() { # wait_boot_verifier <label>
  local label="$1"
  if "${SSH[@]}" -o BatchMode=yes '
    for _ in $(seq 1 90); do
      [ "$(systemctl show --value -p ExecMainCode nixboot-verify.service 2>/dev/null)" != 0 ] \
        && exit 0
      systemctl is-failed --quiet nixboot-verify.service && exit 1
      sleep 2
    done
    exit 1
  '; then
    return 0
  fi
  echo "!! ${label}: nixboot verifier did not finish" >&2
  "${SSH[@]}" -o BatchMode=yes '
    systemctl status --no-pager -l nixboot-verify.service || true
    journalctl -b --no-pager -u nixboot-verify.service || true
  ' 2>&1 | sed 's/^/   /' || true
  return 1
}

# ── 1. Build the soak specialisation toplevels on the test runner ─────────────────────
echo ">> building demo-upgrade-soak toplevel (carries soak-gen-2..6 specialisations) ..."
SOAK_TOP=$(nix build --no-link --print-out-paths \
  "$FLAKE#nixosConfigurations.demo-upgrade-soak.config.system.build.toplevel") \
  || { echo "!! soak toplevel build failed" >&2; exit 1; }
echo "   soak toplevel: $SOAK_TOP"

GEN_TOPS=()
for g in $(seq 2 $((N + 1))); do
  sp="$SOAK_TOP/specialisation/soak-gen-${g}"
  [ -L "$sp" ] || { echo "!! specialisation soak-gen-${g} missing from $SOAK_TOP/specialisation/" >&2; exit 1; }
  GEN_TOPS+=("$(readlink -f "$sp")")
  echo "   soak-gen-${g}: ${GEN_TOPS[$((g - 2))]}"
done

# ── 2. Enrollment bootstrap ─────────────────────────────────────────────────────────────────────────
# The image deliberately ships with no firmware variables enrolled. Bootstrap in Setup Mode,
# prove the one expected red verifier, enroll the keys, then reboot into enforcement.
LOGE="$WORK/enroll.log"; FIFOE="$WORK/enroll.in"; mkfifo "$FIFOE"
echo ">> ENROLLMENT: Setup Mode; serial unlock, verifier completion, key enrollment ..."
start_swtpm
run_qemu < "$FIFOE" > "$LOGE" 2>&1 &
VME=$!
VM_PIDS+=("$VME")
exec 5> "$FIFOE"
( sleep 32; printf '%s\n' "$PASS" >&5 ) &
FEEDE=$!
wait_running "$VME" "enrollment bootstrap" || { tail -30 "$LOGE"; exit 1; }
kill "$FEEDE" 2>/dev/null || true
wait_verifiers "enrollment bootstrap" || { tail -50 "$LOGE"; exit 1; }

sbctl_json="$("${SSH[@]}" -o BatchMode=yes 'sbctl --disable-landlock status --json' 2>&1)"
if ! grep -Eq '"setup_mode"[[:space:]]*:[[:space:]]*true' <<< "$sbctl_json" \
  || ! grep -Eq '"secure_boot"[[:space:]]*:[[:space:]]*false' <<< "$sbctl_json"; then
  echo "!! enrollment bootstrap is not Secure-Boot-capable firmware in Setup Mode. sbctl said:"
  printf '%s\n' "$sbctl_json"
  exit 1
fi

saved_allowlist="${NIXNAS_FAILED_UNITS_ALLOWLIST:-}"
NIXNAS_FAILED_UNITS_ALLOWLIST="${saved_allowlist:+$saved_allowlist }nixboot-verify.service"
assert_no_failed_units "enrollment bootstrap (pre-enrollment transition)" || exit 1
NIXNAS_FAILED_UNITS_ALLOWLIST="$saved_allowlist"
verify_log="$("${SSH[@]}" -o BatchMode=yes \
  'journalctl -b -u nixboot-verify.service -o cat --no-pager' 2>/dev/null)"
verify_fails="$(sed -n '/^FAIL  /p' <<< "$verify_log")"
if [ -z "$verify_fails" ] \
  || grep -Ev '^FAIL  secureBoot\.enable:' <<< "$verify_fails" >/dev/null; then
  echo "!! enrollment bootstrap verifier did not fail solely for pre-enrollment Secure Boot:"
  printf '%s\n' "$verify_fails"
  exit 1
fi

echo ">> enrolling the generated appliance keys into OVMF ..."
"${SSH[@]}" -o BatchMode=yes nixnas-enroll-sb \
  || { echo "!! Secure Boot enrollment failed" >&2; exit 1; }
# Enrollment changes PCR 7. Force the next boot to seal its identity under enforcement.
"${SSH[@]}" -o BatchMode=yes \
  'rm -f /boot/loader/credentials/nixboot-initrd-hostkey.cred /boot/loader/credentials/nixboot-initrd-hostkey.pub'
"${SSH[@]}" -o BatchMode=yes 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VME" 2>/dev/null || break; sleep 2; done
exec 5>&-
kill "$VME" 2>/dev/null || true; wait "$VME" 2>/dev/null || true; rm -f "$FIFOE"
VM_PIDS=()

# ── 3. Post-enrollment baseline boot ─────────────────────────────────────────────────────────────
# This baseline boot must enforce Secure Boot and seal the initrd-SSH identity against
# final PCR 7, so boots 1-5 can deliver the passphrase through an authenticated channel.
LOG0="$WORK/boot0.log"; FIFO0="$WORK/in0"; mkfifo "$FIFO0"
echo ">> BASELINE: Secure Boot enforced; serial unlock and final host-key seal ..."
start_swtpm
run_qemu < "$FIFO0" > "$LOG0" 2>&1 &
VM0=$!
VM_PIDS+=("$VM0")
exec 3> "$FIFO0"
( sleep 32; printf '%s\n' "$PASS" >&3 ) &   # feed once the LUKS prompt appears
FEED0=$!
wait_running "$VM0" "baseline" || { tail -30 "$LOG0"; exit 1; }
kill "$FEED0" 2>/dev/null || true
wait_verifiers "baseline" || { tail -50 "$LOG0"; exit 1; }
exec 3>&-

sbctl_json="$("${SSH[@]}" -o BatchMode=yes 'sbctl --disable-landlock status --json' 2>&1)"
if ! grep -Eq '"setup_mode"[[:space:]]*:[[:space:]]*false' <<< "$sbctl_json" \
  || ! grep -Eq '"secure_boot"[[:space:]]*:[[:space:]]*true' <<< "$sbctl_json"; then
  echo "!! baseline did not boot with Secure Boot enforced. sbctl said:"
  printf '%s\n' "$sbctl_json"
  exit 1
fi

# Confirm the sealed host-key credential is present (needed for initrd-SSH on boots 1-5).
sealed=0
for _ in $(seq 1 15); do
  "${SSH[@]}" -o BatchMode=yes \
    'test -f /boot/loader/credentials/nixboot-initrd-hostkey.cred' 2>/dev/null \
    && { sealed=1; break; }
  sleep 4
done
[ "$sealed" = 1 ] || { echo "!! baseline: sealed host-key credential not found" >&2; exit 1; }

# nix copy the soak toplevel (and therefore all 5 specialisation closures) into the VM.
echo ">> nix copy soak specialisations into VM ..."
NIX_SSHOPTS="-i ${KEY} -p ${PORT} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
export NIX_SSHOPTS
nix copy --no-check-sigs --to "ssh://root@127.0.0.1" "$SOAK_TOP" \
  || { echo "!! nix copy failed" >&2; exit 1; }

# Baseline measurements (generation 1 = the demo image's initial generation).
echo ">> recording baseline state (generation 1) ..."
store_mib_base=$("${SSH[@]}" "du -s /nix/store | awk '{print int(\$1/1024)}'")
uki_count_base=$("${SSH[@]}" "find /boot/EFI/Linux -name 'nixos-generation-*.efi' | wc -l")
bootctl_count_base=$("${SSH[@]}" "bootctl list 2>/dev/null | grep -c 'type:' || true")

# CI quality gate: the fully-booted, post-enrollment baseline must have ZERO failed units
# before we start cycling (a broken oneshot would otherwise taint all five cycles).
assert_no_failed_units "baseline (post-enrollment running system)" || exit 1

# Stage cycle 1: install soak-gen-2 as the next boot.
echo ">> staging soak-gen-2 (generation 2) for first cycle reboot ..."
"${SSH[@]}" "nix-env -p /nix/var/nix/profiles/system --set '${GEN_TOPS[0]}'"
"${SSH[@]}" "/nix/var/nix/profiles/system/bin/switch-to-configuration boot"
"${SSH[@]}" "systemctl poweroff" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM0" 2>/dev/null || break; sleep 2; done
kill "$VM0" 2>/dev/null || true; wait "$VM0" 2>/dev/null || true
VM_PIDS=()

echo "   baseline: store=${store_mib_base} MiB, UKIs=${uki_count_base}, bootctl_entries=${bootctl_count_base}"

# ── 4. Cycle boots ────────────────────────────────────────────────────────────────────
# Growth table state (parallel arrays).
CYCLE_STORE_MIB=("$store_mib_base")
CYCLE_UKIS=("$uki_count_base")
CYCLE_DELTA_MIB=("-")
CYCLE_PASS=()
PREV_STORE_MIB="$store_mib_base"
FAIL_COUNT=0

for cycle in $(seq 1 "$N"); do
  gen=$((cycle + 1))                          # NixOS profile generation number
  expected_ukis=$(( cycle + 1 < KEEP ? cycle + 1 : KEEP ))
  LOG_C="$WORK/boot${cycle}.log"
  FIFO_C="$WORK/in${cycle}"; mkfifo "$FIFO_C"

  echo ""
  echo ">> CYCLE ${cycle}/5 — boot into generation ${gen} (soak-gen-${gen}) ..."

  start_swtpm
  run_qemu < "$FIFO_C" > "$LOG_C" 2>&1 &
  VM_C=$!
  VM_PIDS+=("$VM_C")
  exec 4> "$FIFO_C"

  # Try initrd-SSH first (sealed host key from boot 0). If it comes up within 60s,
  # deliver the passphrase via systemd-tty-ask-password-agent so LUKS opens headlessly.
  # Unconditionally also queue a serial feed after a longer delay as a fallback — the
  # serial passphrase is harmless if LUKS is already open (input lands on the login prompt).
  ( sleep 32; printf '%s\n' "$PASS" >&4 ) &   # serial fallback — harmless if redundant
  FEED_C=$!

  initrd_up=0
  for _ in $(seq 1 30); do
    kill -0 "$VM_C" 2>/dev/null || break
    "${SSH[@]}" -o BatchMode=yes true 2>/dev/null && { initrd_up=1; break; }
    sleep 2
  done
  if [ "$initrd_up" = 1 ]; then
    # Is this initrd-SSH or the running-system sshd? Check whether /boot is mounted.
    on_running=$("${SSH[@]}" -o BatchMode=yes "test -d /boot/EFI/Linux && echo yes || echo no" 2>/dev/null || echo no)
    if [ "$on_running" = "no" ]; then
      # initrd-SSH is up; deliver the LUKS passphrase to the password agent.
      echo "   cycle ${cycle}: initrd-SSH up — delivering passphrase via password agent"
      printf '%s\n' "$PASS" | "${SSH[@]}" -tt 'systemd-tty-ask-password-agent --query' 2>/dev/null || true
    fi
  fi
  exec 4>&-
  kill "$FEED_C" 2>/dev/null || true

  # Wait for running-system SSH.
  cycle_ok=1
  wait_running "$VM_C" "cycle ${cycle}" || { cycle_ok=0; tail -30 "$LOG_C"; }
  vm_booted="$cycle_ok"   # track boot success independently from assertion outcomes

  if [ "$cycle_ok" = 1 ]; then
    # Do not race the failed-unit gate against the production boot verifier. The soak
    # specialisations intentionally omit the demo image's write-isolation verifier.
    wait_boot_verifier "cycle ${cycle}" || { cycle_ok=0; tail -50 "$LOG_C"; }

    # (a) boots newest: /etc/nixnas-soak-gen == expected generation number.
    actual_marker=$("${SSH[@]}" "cat /etc/nixnas-soak-gen 2>/dev/null || echo MISSING")
    if [ "$actual_marker" = "$gen" ]; then
      echo "   [PASS] (a) boots newest: /etc/nixnas-soak-gen = '${actual_marker}' == ${gen}"
    else
      echo "   [FAIL] (a) boots newest: /etc/nixnas-soak-gen = '${actual_marker}', expected '${gen}'"
      cycle_ok=0
    fi

    # (b) ESP UKI count == min(cycle+1, keepGenerations=3).
    actual_ukis=$("${SSH[@]}" "find /boot/EFI/Linux -name 'nixos-generation-*.efi' | wc -l")
    if [ "$actual_ukis" = "$expected_ukis" ]; then
      echo "   [PASS] (b) UKI count: ${actual_ukis} == min($((cycle + 1)), ${KEEP}) = ${expected_ukis}"
    else
      echo "   [FAIL] (b) UKI count: ${actual_ukis}, expected ${expected_ukis} (min($((cycle + 1)), ${KEEP}))"
      cycle_ok=0
    fi

    # (c) bootctl list entry count matches expected UKI count.
    # bootctl list emits one "type:" line per boot entry; count only the BLS/UKI entries
    # (type: Boot Loader Specification ...) and exclude the automatic "Reboot Into Firmware
    # Interface" entry whose line reads "type: Automatic".
    bootctl_count=$("${SSH[@]}" "bootctl list 2>/dev/null | grep -c 'type: Boot Loader Specification'" 2>/dev/null || echo "0")
    if [ "$bootctl_count" = "$expected_ukis" ]; then
      echo "   [PASS] (c) bootctl entries: ${bootctl_count} == ${expected_ukis}"
    else
      echo "   [FAIL] (c) bootctl entries: ${bootctl_count}, expected ${expected_ukis}"
      # Log the bootctl output for diagnosis.
      echo "   --- bootctl list ---"
      "${SSH[@]}" "bootctl list 2>&1" | sed 's/^/   /' || true
      cycle_ok=0
    fi

    # (d) store growth bounded.
    store_mib=$("${SSH[@]}" "du -s /nix/store | awk '{print int(\$1/1024)}'")
    delta_mib=$((store_mib - PREV_STORE_MIB))
    CYCLE_STORE_MIB+=("$store_mib")
    CYCLE_UKIS+=("$actual_ukis")
    CYCLE_DELTA_MIB+=("${delta_mib}")
    if [ "$delta_mib" -le "$STORE_GROWTH_LIMIT_MIB" ]; then
      echo "   [PASS] (d) store growth: +${delta_mib} MiB <= ${STORE_GROWTH_LIMIT_MIB} MiB limit"
    else
      echo "   [FAIL] (d) store growth: +${delta_mib} MiB exceeds ${STORE_GROWTH_LIMIT_MIB} MiB limit"
      cycle_ok=0
    fi
    PREV_STORE_MIB="$store_mib"

    # (e) CI quality gate: zero failed units on the freshly booted generation.
    if assert_no_failed_units "cycle ${cycle} (generation ${gen})"; then
      echo "   [PASS] (e) failed-units gate: systemctl --failed empty"
    else
      echo "   [FAIL] (e) failed-units gate: failed units present (see list above)"
      cycle_ok=0
    fi
  else
    # VM failed to boot; record placeholder values.
    CYCLE_STORE_MIB+=("?")
    CYCLE_UKIS+=("?")
    CYCLE_DELTA_MIB+=("?")
  fi

  CYCLE_PASS+=("$cycle_ok")
  [ "$cycle_ok" = 1 ] || FAIL_COUNT=$((FAIL_COUNT + 1))

  # Stage the next cycle's generation (if not the last cycle).
  # Conditional on vm_booted (VM was accessible), not cycle_ok (all assertions passed),
  # so that an assertion failure in one cycle does not cascade and block staging for the
  # subsequent cycle — each cycle must be independently observable.
  if [ "$cycle" -lt "$N" ] && [ "$vm_booted" = 1 ]; then
    next_idx="$cycle"                          # GEN_TOPS[next_idx] = soak-gen-(cycle+2)
    next_gen=$((cycle + 2))
    echo "   staging soak-gen-${next_gen} (generation $((cycle + 2))) for next cycle reboot ..."
    "${SSH[@]}" "nix-env -p /nix/var/nix/profiles/system --set '${GEN_TOPS[$next_idx]}'"
    "${SSH[@]}" "/nix/var/nix/profiles/system/bin/switch-to-configuration boot"
  fi

  "${SSH[@]}" "systemctl poweroff" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$VM_C" 2>/dev/null || break; sleep 2; done
  kill "$VM_C" 2>/dev/null || true; wait "$VM_C" 2>/dev/null || true
  VM_PIDS=()
done

# ── 5. Results ────────────────────────────────────────────────────────────────────────
echo ""
echo "================ GROWTH TABLE ================"
printf "%-7s %-12s %-10s %-16s %s\n" \
  "Cycle" "Profile gen" "ESP UKIs" "/nix/store (MiB)" "Delta (MiB)"
printf "%-7s %-12s %-10s %-16s %s\n" \
  "------" "-----------" "--------" "----------------" "-----------"
printf "%-7s %-12s %-10s %-16s %s\n" \
  "0 (base)" "1" "${CYCLE_UKIS[0]}" "${CYCLE_STORE_MIB[0]}" "-"
for cycle in $(seq 1 "$N"); do
  gen=$((cycle + 1))
  pass_mark=""; [ "${CYCLE_PASS[$((cycle - 1))]:-0}" = "0" ] && pass_mark=" FAIL"
  printf "%-7s %-12s %-10s %-16s %s%s\n" \
    "$cycle" "$gen" "${CYCLE_UKIS[$cycle]:-?}" \
    "${CYCLE_STORE_MIB[$cycle]:-?}" "${CYCLE_DELTA_MIB[$cycle]:-?}" "$pass_mark"
done
echo ""
echo "keepGenerations=${KEEP}  N=${N}  growth_limit=${STORE_GROWTH_LIMIT_MIB} MiB"
echo ""

echo "================ RESULT ================"
if [ "$FAIL_COUNT" = 0 ]; then
  echo "PASS — all ${N} cycles: boots newest generation, ESP UKI count == min(cycle+1, ${KEEP}),"
  echo "       bootctl list correct, store growth bounded, zero failed units per cycle."
  echo "       lanzaboote keepGenerations ✔"
  exit 0
fi
echo "FAIL — ${FAIL_COUNT} of ${N} cycles failed (see [FAIL] lines above)."
exit 1
