#!/usr/bin/env bash
# test/seal-3boot-test.sh — the FULL end-to-end proof of the TPM-sealed initrd-SSH host key.
#
# verify-sealed-hostkey.nix proves the seal + a decrypt round-trip WITHIN one boot. This
# script proves the part that only real reboots can: that the INITRD (boot #3) mounts the
# ESP, unseals the host key from the TPM, and brings up initrd-SSH BEFORE the store is
# unlocked — i.e. the actual unseal-before-sshd ordering, over a genuine power cycle.
#
# It needs persistence that boot-vm.sh deliberately drops (snapshot=on + a fresh swtpm each
# run), so it runs its own QEMU with:
#   * a WRITABLE scratch COPY of the image (enrollment and the post-enrollment sealed blob
#     must survive their power cycles; the original .raw is never touched),
#   * a PERSISTENT swtpm state dir + PERSISTENT OVMF_VARS reused across all boots. Boot #1
#     enrolls the appliance's keys; boots #2/#3 therefore measure the same enforced Secure
#     Boot state into PCR 7, which is the phase-stable anchor used by the sealed credential.
#
# BOOT #1: unlock over serial in firmware Setup Mode, enroll the generated appliance keys,
#          remove the pre-enrollment credential, then power off. Sealing before enrollment
#          would bind the identity to the wrong PCR 7 value and is deliberately discarded.
# BOOT #2: boot with Secure Boot enforced, unlock over serial, seal the host key at the final
#          PCR 7 state, require a clean system, then power off.
# BOOT #3: NO serial passphrase. If initrd-SSH comes up at all, the initrd unsealed the key
#          (no blob / failed unseal ⇒ sshd never starts). Then hand the passphrase to the
#          initrd password agent over SSH and confirm the box reaches login — headless,
#          with a host key that was never on the plaintext ESP.
#
# --tamper NEGATIVE proof: boot #3 runs against a FRESH TPM (different SRK) — the seal MUST
#          then fail to unseal, sshd must NOT come up, the box must fall back to serial. This is
#          what proves the key is genuinely bound to THIS box's TPM, not decryptable by any TPM.
#          In tamper mode a NON-unlock is the PASS.
#
# Usage: test/seal-3boot-test.sh <image.raw> [--pass nixnas-demo] [--login-pass nixnas]
#        [--port 2222] [--tamper]
set -uo pipefail

IMG="${1:?usage: seal-3boot-test.sh <image.raw>}"; shift || true
PASS="nixnas-demo"; LOGIN_PASS="nixnas"; PORT=2222; TAMPER=0
while [ $# -gt 0 ]; do case "$1" in
  --pass) PASS="$2"; shift ;;
  --login-pass) LOGIN_PASS="$2"; shift ;;
  --port) PORT="$2"; shift ;;
  --tamper) TAMPER=1 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

# --- OVMF firmware (must support Secure Boot; blank/Setup-Mode VARS are enrolled in boot #1) ---
# Prefer the Secure-Boot-capable code image explicitly where distros split it from their
# ordinary OVMF build. $OVMF_CODE / $OVMF_VARS env overrides win (CI can inject Nix OVMFFull).
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

HERE="$(cd "$(dirname "$0")" && pwd)"
# Failed-units gate (assert_no_failed_units*): systemctl --failed must be EMPTY on every
# booted system we reach over SSH. Allowlist: NIXNAS_FAILED_UNITS_ALLOWLIST (default empty).
. "$HERE/assert-no-failed-units.sh"
WORK="$(mktemp -d /tmp/nixnas-3boot.XXXXXX)"
# A fresh clone checks the demo key out 0644 and OpenSSH refuses world-readable
# private keys — use a 0600 copy, never the repo file directly.
KEY="$WORK/demo_key"
install -m600 "$HERE/ssh/demo_key" "$KEY"
SCRATCH="$WORK/disk.raw"
SWTPM_PID=""
# Track each QEMU PID explicitly. Cleanup must never pattern-kill processes: another concurrent
# test can legitimately have the same executable and must remain untouched.
VM_PIDS=()
cleanup(){
  local pid
  for pid in "${VM_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  # Wait for the qemu to actually release the SSH-forward port, so a chained next run doesn't
  # race the port-free guard (killing qemu is async; the socket lingers a moment).
  for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ":${PORT} " || break; sleep 0.3; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Fail fast (with a clear message) if the SSH-forward port is already taken — otherwise qemu
# dies with an opaque "Could not set up host forwarding rule" mid-boot.
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "!! port ${PORT} is already in use (a stale VM?). Free it or pass --port. Aborting." >&2
  exit 1
fi

echo ">> preparing persistent scratch (writable copy; original untouched) …"
cp --sparse=always "$IMG" "$SCRATCH"
chmod u+rw "$SCRATCH"   # the source .raw is 0444 (nix store); QEMU needs the scratch writable
cp "$OVMF_VARS_TMPL" "$WORK/OVMF_VARS.fd"   # persistent UEFI vars, reused across all boots
# Nix-store firmware templates are 0444; distro packages commonly install them writable.
# The scratch must be writable regardless of source or QEMU cannot persist the first boot's
# UEFI variables into the second boot.
chmod u+w "$WORK/OVMF_VARS.fd"

# Software TPM2. A FRESH swtpm per boot, both against the SAME persistent --tpmstate dir:
# the state dir persists the SRK/NV (so the sealed blob stays decryptable), while each boot
# resets the volatile PCRs to zero. After boot #1 enrollment, firmware re-extends PCR 7 to
# the same enforced-Secure-Boot value in boots #2/#3, so seal and unseal agree. Reusing one
# long-lived swtpm would instead double-extend PCR 7 and break the unseal.
mkdir -p "$WORK/tpm"
TPM_SOCK="$WORK/tpm/sock"   # run_qemu reads this; start_swtpm may repoint it (tamper = fresh TPM)
start_swtpm() {            # start_swtpm [statedir]  (default: the persistent $WORK/tpm)
  local dir="${1:-$WORK/tpm}"
  mkdir -p "$dir"
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  rm -f "$dir/sock" "$dir/pid"
  swtpm socket --tpm2 --tpmstate dir="$dir" \
    --ctrl type=unixio,path="$dir/sock" --pid file="$dir/pid" --daemon
  for _ in $(seq 1 25); do [ -S "$dir/sock" ] && break; sleep 0.2; done
  SWTPM_PID="$(cat "$dir/pid")"
  TPM_SOCK="$dir/sock"
}

SSH=(ssh -i "$KEY" -p "$PORT"
     -o IdentitiesOnly=yes
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=4 root@127.0.0.1)

# Launch QEMU against the persistent scratch + persistent tpm/vars.
run_qemu() { # run_qemu <logfile>
  # This function is always backgrounded. exec makes $! the actual QEMU PID, so cleanup can
  # never kill only a wrapper subshell and leave the VM holding the scratch disk/SSH port.
  exec qemu-system-x86_64 \
    -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 2048 \
    -global ICH9-LPC.disable_s3=1 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd" \
    -chardev socket,id=chrtpm,path="$TPM_SOCK" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -drive if=virtio,format=raw,file="$SCRATCH" \
    -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device virtio-net,netdev=n0 \
    -no-reboot -nographic -serial "mon:stdio"
}

# ─────────────────────────────── BOOT #1 — enroll ─────────────────────────────
# Drive the serial via a FIFO (not a `… | qemu` pipe) so $VM1 is PURELY qemu's PID — a
# pipeline PID would keep the passphrase-feeder alive and make the later wait hang.
LOG1="$WORK/boot1.log"; FIFO1="$WORK/in1"; mkfifo "$FIFO1"
echo ">> BOOT #1: Setup-Mode bootstrap; unlocking over serial and enrolling appliance keys …"
start_swtpm
run_qemu < "$FIFO1" > "$LOG1" 2>&1 &
VM1=$!
VM_PIDS+=("$VM1")
exec 3> "$FIFO1"                       # hold the write end open so qemu's serial stays live
( sleep 32; printf '%s\n' "$PASS" >&3 ) &   # feed the passphrase once the unlock prompt is up
FEED1=$!
stage2=0
for _ in $(seq 1 150); do
  kill -0 "$VM1" 2>/dev/null || { echo "!! boot #1 VM exited early"; break; }
  grep -q '=== NIXNAS-WRITES-END ===' "$LOG1" && { stage2=1; break; }
  sleep 2
done
kill "$FEED1" 2>/dev/null || true
if [ "$stage2" != 1 ]; then
  echo "!! boot #1 never reached the stage-2 verifier-complete marker. Current service state:"
  "${SSH[@]}" -o BatchMode=yes '
    systemctl status --no-pager -l \
      generate-sb-keys.service nixboot-seal-hostkey.service nixboot-verify.service || true
    journalctl -b --no-pager \
      -u generate-sb-keys.service -u nixboot-seal-hostkey.service -u nixboot-verify.service || true
    find /boot/loader/credentials -maxdepth 1 -type f -ls 2>/dev/null || true
  ' 2>&1 || true
  echo "Serial tail:"
  tail -30 "$LOG1"
  exit 1
fi
# Do not poll SSH before stage 2: current OpenSSH treats repeated half-started connections as
# a per-source attack and locks the harness itself out. One connection after the serial
# verifier-complete marker reaches the settled running-system daemon instead.
if ! "${SSH[@]}" -o BatchMode=yes true 2>"$WORK/boot1-ssh.err"; then
  echo "!! boot #1 reached login but running-system SSH was not reachable"
  echo "   first stage-2 SSH error:"
  sed 's/^/   /' "$WORK/boot1-ssh.err"
  echo "   verbose retry:"
  "${SSH[@]}" -vvv true 2>&1 | tail -80 | sed 's/^/   /' || true
  # SSH itself may be the failed service, so retain a serial-only path for reporting the
  # prerequisite state that normally has to be queried over SSH.
  printf '\nroot\n' >&3
  sleep 2
  printf '%s\n' "$LOGIN_PASS" >&3
  sleep 2
  printf '%s\n' \
    'echo === NIXNAS-SSH-DIAGNOSTIC-START ===' \
    'ls -ld /var /var/empty /run/wrappers/bin/unix_chkpwd 2>&1 || true' \
    'systemctl status --no-pager -l systemd-tmpfiles-setup.service nixnas-stage2-tmpfiles.service suid-sgid-wrappers.service sshd.service 2>&1 || true' \
    'journalctl -b --no-pager -u systemd-tmpfiles-setup.service -u nixnas-stage2-tmpfiles.service -u suid-sgid-wrappers.service -u sshd.service -n 100 2>&1 || true' \
    'journalctl -b -o cat --no-pager | grep -Fi "ordering cycle" || true' \
    'findmnt / /var /var/empty 2>&1 || true' \
    'echo === NIXNAS-SSH-DIAGNOSTIC-END ===' >&3
  sleep 6
  tail -40 "$LOG1"
  exit 1
fi
echo ">> boot #1: stage 2 reached and generated the appliance key material …"

# This boot must be the one deliberate pre-enrollment state: Setup Mode on and Secure Boot
# enforcement off. A non-Secure-Boot OVMF build used to make this suite green while testing
# a firmware posture the appliance explicitly rejects.
sbctl_json="$("${SSH[@]}" -o BatchMode=yes 'sbctl --disable-landlock status --json' 2>&1)"
if ! grep -Eq '"setup_mode"[[:space:]]*:[[:space:]]*true' <<< "$sbctl_json" \
  || ! grep -Eq '"secure_boot"[[:space:]]*:[[:space:]]*false' <<< "$sbctl_json"; then
  echo "!! boot #1 is not a Secure-Boot-capable firmware in Setup Mode. sbctl said:"
  printf '%s\n' "$sbctl_json"
  echo "   Use Secure-Boot-capable OVMF_CODE with a blank OVMF_VARS template."
  exit 1
fi

# nixboot-verify must make the pre-enrollment posture red, while every other unit stays
# healthy. Allow exactly that unit for this one transitional boot, then inspect its FAIL
# lines so the allowlist cannot conceal an unrelated verifier regression.
saved_allowlist="${NIXNAS_FAILED_UNITS_ALLOWLIST:-}"
NIXNAS_FAILED_UNITS_ALLOWLIST="${saved_allowlist:+$saved_allowlist }nixboot-verify.service"
if ! assert_no_failed_units "boot #1 (pre-enrollment transition)"; then
  NIXNAS_FAILED_UNITS_ALLOWLIST="$saved_allowlist"
  echo "!! boot #1 verifier diagnostics:"
  "${SSH[@]}" -o BatchMode=yes '
    ls -l /etc/sbctl /etc/sbctl/sbctl.conf 2>&1 || true
    sed -n "1,40p" /etc/sbctl/sbctl.conf 2>&1 || true
    command -v sbctl 2>&1 || true
    sbctl --debug --disable-landlock status --json 2>&1
    echo "sbctl-exit=$?"
    findmnt /sys/firmware/efi/efivars 2>&1 || true
    ls -ld /sys/firmware/efi /sys/firmware/efi/efivars 2>&1 || true
    bootctl --no-pager status 2>&1 | sed -n "1,50p" || true
  ' 2>&1 || true
  exit 1
fi
NIXNAS_FAILED_UNITS_ALLOWLIST="$saved_allowlist"
verify_log="$("${SSH[@]}" -o BatchMode=yes \
  'journalctl -b -u nixboot-verify.service -o cat --no-pager' 2>/dev/null)"
verify_fails="$(sed -n '/^FAIL  /p' <<< "$verify_log")"
if [ -z "$verify_fails" ] \
  || grep -Ev '^FAIL  secureBoot\.enable:' <<< "$verify_fails" >/dev/null; then
  echo "!! boot #1 verifier did not fail solely for the expected pre-enrollment Secure Boot state:"
  printf '%s\n' "$verify_fails"
  "${SSH[@]}" -o BatchMode=yes '
    echo "--- LoaderBootCountPath variables ---"
    for f in /sys/firmware/efi/efivars/LoaderBootCountPath-*; do
      [ -e "$f" ] || continue
      echo "$f"
      tail -c +5 "$f" | tr -d "\000" || true
      echo
    done
    echo "--- systemd-bless-boot ---"
    systemctl status --no-pager -l systemd-bless-boot.service 2>&1 || true
    systemctl show systemd-bless-boot.service -p ActiveState -p Result -p ConditionResult 2>&1 || true
    echo "--- bootctl ---"
    bootctl --no-pager status 2>&1 | sed -n "1,90p" || true
  ' 2>&1 || true
  exit 1
fi
if ! grep -Fq 'PASS  remoteUnlock: sealed initrd SSH host key decrypts' <<< "$verify_log"; then
  echo "!! boot #1 verifier did not prove the generated sealed identity decrypts"
  printf '%s\n' "$verify_log"
  exit 1
fi

echo ">> enrolling the generated appliance keys into OVMF …"
if ! "${SSH[@]}" -o BatchMode=yes nixnas-enroll-sb; then
  echo "!! Secure Boot enrollment failed"
  exit 1
fi
# Any credential sealed before enrollment has the pre-enrollment PCR 7 value. Remove it so
# boot #2 cannot mistake it for the final identity and must seal again under enforcement.
"${SSH[@]}" -o BatchMode=yes \
  'rm -f /boot/loader/credentials/nixboot-initrd-hostkey.cred /boot/loader/credentials/nixboot-initrd-hostkey.pub'
echo ">> powering off after enrollment …"
"${SSH[@]}" -o BatchMode=yes 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM1" 2>/dev/null || break; sleep 2; done
exec 3>&-                              # release the FIFO writer
kill "$VM1" 2>/dev/null || true; wait "$VM1" 2>/dev/null || true; rm -f "$FIFO1"
VM_PIDS=()

# ─────────────────────────────── BOOT #2 — seal ───────────────────────────────
LOG2="$WORK/boot2.log"; FIFO2="$WORK/in2"; mkfifo "$FIFO2"
echo ">> BOOT #2: Secure Boot enforced; unlocking over serial and sealing at final PCR 7 …"
start_swtpm
run_qemu < "$FIFO2" > "$LOG2" 2>&1 &
VM2=$!
VM_PIDS+=("$VM2")
exec 4> "$FIFO2"
( sleep 32; printf '%s\n' "$PASS" >&4 ) &
FEED2=$!
stage2=0
for _ in $(seq 1 150); do
  kill -0 "$VM2" 2>/dev/null || { echo "!! boot #2 VM exited early"; break; }
  grep -q '=== NIXNAS-WRITES-END ===' "$LOG2" && { stage2=1; break; }
  sleep 2
done
kill "$FEED2" 2>/dev/null || true
if [ "$stage2" != 1 ]; then
  echo "!! boot #2 never reached the post-enrollment verifier-complete marker. Current service state:"
  "${SSH[@]}" -o BatchMode=yes '
    systemctl status --no-pager -l nixboot-seal-hostkey.service nixboot-verify.service || true
    journalctl -b --no-pager -u nixboot-seal-hostkey.service -u nixboot-verify.service || true
  ' 2>&1 || true
  echo "Serial tail:"
  tail -40 "$LOG2"
  exit 1
fi
if ! "${SSH[@]}" -o BatchMode=yes '
  for _ in $(seq 1 30); do
    systemctl is-active --quiet nixboot-seal-hostkey.service && exit 0
    systemctl is-failed --quiet nixboot-seal-hostkey.service && exit 1
    sleep 2
  done
  exit 1
' 2>"$WORK/boot2-ssh.err"; then
  echo "!! boot #2 reached login but the post-enrollment sealing unit did not become active"
  echo "   first stage-2 SSH error:"
  sed 's/^/   /' "$WORK/boot2-ssh.err"
  echo "   verbose retry:"
  "${SSH[@]}" -vvv true 2>&1 | tail -80 | sed 's/^/   /' || true
  tail -40 "$LOG2"
  exit 1
fi
echo ">> boot #2: sealed blob present under enforced Secure Boot …"
assert_no_failed_units "boot #2 (post-enrollment running system)" || exit 1
identity_sha2="$("${SSH[@]}" -o BatchMode=yes \
  'sha256sum /boot/loader/credentials/nixboot-initrd-hostkey.cred /boot/loader/credentials/nixboot-initrd-hostkey.pub' \
  2>/dev/null)"
if [ -z "$identity_sha2" ]; then
  echo "!! boot #2 could not hash the sealed initrd-SSH identity"
  exit 1
fi
echo ">> powering off cleanly over SSH …"
"${SSH[@]}" -o BatchMode=yes 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM2" 2>/dev/null || break; sleep 2; done
exec 4>&-
kill "$VM2" 2>/dev/null || true; wait "$VM2" 2>/dev/null || true; rm -f "$FIFO2"
VM_PIDS=()

# ─────────────────────────────── BOOT #3 — unseal ─────────────────────────────
LOG3="$WORK/boot3.log"
if [ "$TAMPER" = 1 ]; then
  echo ">> BOOT #3 (TAMPER): fresh TPM (different SRK) — unseal MUST fail, sshd MUST NOT come up …"
  start_swtpm "$WORK/tpm-fresh"   # a brand-new TPM: different storage seed ⇒ cannot unseal boot #2's cred
else
  echo ">> BOOT #3: NO serial passphrase — initrd must unseal the host key to bring up sshd …"
  start_swtpm   # fresh PCRs against the same persisted SRK/NV; firmware re-extends PCR 7 to seal-time value
fi
run_qemu < /dev/null > "$LOG3" 2>&1 &
VM3=$!
VM_PIDS+=("$VM3")
trap cleanup EXIT

up=0; vm_alive=1
for _ in $(seq 1 60); do
  kill -0 "$VM3" 2>/dev/null || { echo "!! boot #3 VM exited early"; vm_alive=0; break; }
  # initrd-SSH answering === the initrd unsealed the key (else sshd never started).
  if "${SSH[@]}" -o BatchMode=yes true 2>/dev/null; then up=1; break; fi
  sleep 2
done

# ── TAMPER mode: a NON-unlock is the PASS (the wrong TPM must not be able to unseal). ──
if [ "$TAMPER" = 1 ]; then
  echo "================ RESULT (TAMPER) ================"
  if [ "$up" = 1 ]; then
    echo "FAIL — initrd-SSH came up on a DIFFERENT TPM. The key is NOT bound to this box's TPM!"
    tail -30 "$LOG3"; exit 1
  fi
  # A timeout alone is not evidence: an unrelated firmware, disk, or network failure would
  # also keep SSH down. systemd blocks in encrypted-credential setup rather than emitting an
  # immediate error on this path, so require the whole observable prefix: live VM, TPM/SRK and
  # network ready, serial unlock fallback present, sshd start attempted but never completed.
  prompt=0; tpm_ready=0; network_ready=0; ssh_start=0; ssh_started=0
  grep -aqE 'Please enter passphrase|Enter passphrase for|Password required for' "$LOG3" && prompt=1
  grep -aqE 'Finished .*Early TPM SRK Setup|Reached target .*Trusted Platform Module' "$LOG3" && tpm_ready=1
  grep -aqE 'Started .*Network Management|Reached target .*Network' "$LOG3" && network_ready=1
  grep -aqE 'Starting .*SSH Daemon' "$LOG3" && ssh_start=1
  grep -aqE 'Started .*SSH Daemon' "$LOG3" && ssh_started=1
  if [ "$vm_alive" != 1 ] || [ "$prompt" != 1 ] || [ "$tpm_ready" != 1 ] \
    || [ "$network_ready" != 1 ] || [ "$ssh_start" != 1 ] || [ "$ssh_started" != 0 ]; then
    echo "FAIL — SSH stayed down, but the serial does not prove the expected wrong-TPM unseal failure."
    echo "       vm_alive=$vm_alive serial_fallback=$prompt tpm_ready=$tpm_ready"
    echo "       network_ready=$network_ready ssh_start=$ssh_start ssh_started=$ssh_started"
    tail -50 "$LOG3"
    exit 1
  fi
  echo "PASS — a fresh/wrong TPM could NOT unseal the host key; initrd-SSH stayed down."
  echo "       Proof the key is genuinely sealed to THIS box's TPM (SRK), not any TPM."
  echo "       wrong-TPM blocked credential path; relevant serial context:"
  grep -aiE "credential|initrd-hostkey|LoadCredential|decrypt|tpm" "$LOG3" | tail -12
  exit 0
fi

# ── Positive mode: initrd-SSH must come up (proves the unseal), then unlock to login. ──
if [ "$up" != 1 ]; then
  echo "!! initrd-SSH never came up in boot #3 — the initrd unseal FAILED."
  cp "$LOG3" /tmp/nixnas-boot3-serial.log 2>/dev/null || true
  echo "   (full serial saved to /tmp/nixnas-boot3-serial.log)"
  echo "   credential / sshd output:"; grep -aiE "credential|initrd-hostkey|sshd|hostkey|TPM|tpm2|decrypt|LoadCredential" "$LOG3" | tail -25
  exit 1
fi
echo ">> initrd-SSH up in boot #3 — the initrd unsealed the TPM-sealed host key. ✔"

echo ">> handing the store passphrase to the initrd password agent over SSH …"
printf '%s\n' "$PASS" | "${SSH[@]}" -tt 'systemd-tty-ask-password-agent --query' 2>/dev/null || true

ok=0
for _ in $(seq 1 40); do
  grep -q 'demo login:' "$LOG3" && { ok=1; break; }
  kill -0 "$VM3" 2>/dev/null || break
  sleep 2
done

# CI quality gate on the boot-#3 RUNNING system: after switch-root the forwarded port
# moves from initrd-SSH to the running sshd — reconnect and require zero failed units.
clean=1
if [ "$ok" = 1 ]; then
  assert_no_failed_units_after_ssh_wait "boot #3 (running system)" 20 || clean=0
fi

# The stage-2 self-heal must not silently rotate a valid identity every boot. Exact hashes are
# stronger than comparing a displayed fingerprint and cover both encrypted credential + public key.
stable=0
if [ "$ok" = 1 ] && [ "$clean" = 1 ]; then
  identity_sha3="$("${SSH[@]}" -o BatchMode=yes \
    'sha256sum /boot/loader/credentials/nixboot-initrd-hostkey.cred /boot/loader/credentials/nixboot-initrd-hostkey.pub' \
    2>/dev/null)"
  if [ -n "$identity_sha3" ] && [ "$identity_sha3" = "$identity_sha2" ]; then
    stable=1
    echo ">> boot #3: valid sealed initrd-SSH identity remained byte-for-byte stable. ✔"
  else
    echo "!! boot #3 changed or lost a valid sealed initrd-SSH identity"
  fi
fi

echo "================ RESULT ================"
if [ "$ok" = 1 ] && [ "$clean" = 1 ] && [ "$stable" = 1 ]; then
  echo "PASS — enrolled in boot #1, sealed under enforcement in boot #2, and boot #3"
  echo "       unsealed the host key in the initrd; initrd-SSH"
  echo "       came up, the store was unlocked over the network, box reached login headless,"
  echo "       and systemctl --failed is empty on both post-enrollment systems."
elif [ "$ok" != 1 ]; then
  echo "FAIL — initrd-SSH came up but the unlock hand-off did not reach login. Serial tail:"
  tail -40 "$LOG3"
else
  echo "FAIL — boot #3 reached login, but readiness, failed-unit, or stable-identity proof failed."
fi
[ "$ok" = 1 ] && [ "$clean" = 1 ] && [ "$stable" = 1 ]
