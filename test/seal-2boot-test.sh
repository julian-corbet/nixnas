#!/usr/bin/env bash
# test/seal-2boot-test.sh — the FULL end-to-end proof of the TPM-sealed initrd-SSH host key.
#
# verify-sealed-hostkey.nix proves the seal + a decrypt round-trip WITHIN one boot. This
# script proves the part that only a real reboot can: that the INITRD (boot #2) mounts the
# ESP, unseals the host key from the TPM, and brings up initrd-SSH BEFORE the store is
# unlocked — i.e. the actual unseal-before-sshd ordering, over a genuine power cycle.
#
# It needs persistence that boot-vm.sh deliberately drops (snapshot=on + a fresh swtpm each
# run), so it runs its own QEMU with:
#   * a WRITABLE scratch COPY of the image (the sealed blob written in boot #1 must survive
#     into boot #2; the original .raw is never touched),
#   * a PERSISTENT swtpm state dir + PERSISTENT OVMF_VARS reused across both boots, so PCR 7
#     (Secure Boot state) is identical at seal time (boot #1, stage-2) and unseal time
#     (boot #2, initrd) — which is exactly why PCR 7 is the chosen, phase-stable anchor.
#
# BOOT #1: unlock over serial (the bootstrap console path), wait for nixnas-seal-hostkey to
#          write the blob, then power off cleanly over the running-system SSH.
# BOOT #2: NO serial passphrase. If initrd-SSH comes up at all, the initrd unsealed the key
#          (no blob / failed unseal ⇒ sshd never starts). Then hand the passphrase to the
#          initrd password agent over SSH and confirm the box reaches login — headless,
#          with a host key that was never on the plaintext ESP.
#
# --tamper NEGATIVE proof: boot #2 runs against a FRESH TPM (different SRK) — the seal MUST
#          then fail to unseal, sshd must NOT come up, the box must fall back to serial. This is
#          what proves the key is genuinely bound to THIS box's TPM, not decryptable by any TPM.
#          In tamper mode a NON-unlock is the PASS.
#
# Usage: test/seal-2boot-test.sh <image.raw> [--pass nixnas-demo] [--port 2222] [--tamper]
set -uo pipefail

IMG="${1:?usage: seal-2boot-test.sh <image.raw>}"; shift || true
PASS="nixnas-demo"; PORT=2222; TAMPER=0
while [ $# -gt 0 ]; do case "$1" in
  --pass) PASS="$2"; shift ;;
  --port) PORT="$2"; shift ;;
  --tamper) TAMPER=1 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

# --- OVMF firmware (non-secboot: the seal binds to PCR 7 = "SB disabled", stable both boots) ---
# Portable across distros: Arch names it OVMF_CODE.4m.fd, Debian/Ubuntu OVMF_CODE_4M.fd,
# older/other layouts OVMF_CODE.fd. $OVMF_CODE / $OVMF_VARS env override wins (CI can inject).
find_fw() { # find_fw "name1 name2 …" → prints first existing path under the known dirs
  local d n
  for d in /usr/share/edk2-ovmf/x64 /usr/share/edk2/x64 /usr/share/OVMF /usr/share/ovmf/x64 /usr/share/qemu; do
    for n in $1; do [ -e "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }; done
  done
  return 1
}
OVMF_CODE="${OVMF_CODE:-$(find_fw 'OVMF_CODE.4m.fd OVMF_CODE_4M.fd OVMF_CODE.fd')}" \
  || { echo "OVMF_CODE firmware not found (install edk2-ovmf / ovmf, or set \$OVMF_CODE)" >&2; exit 1; }
OVMF_VARS_TMPL="${OVMF_VARS:-$(find_fw 'OVMF_VARS.4m.fd OVMF_VARS_4M.fd OVMF_VARS.fd')}" \
  || { echo "OVMF_VARS template not found (set \$OVMF_VARS)" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# Failed-units gate (assert_no_failed_units*): systemctl --failed must be EMPTY on every
# booted system we reach over SSH. Allowlist: NIXNAS_FAILED_UNITS_ALLOWLIST (default empty).
. "$HERE/assert-no-failed-units.sh"
WORK="$(mktemp -d /tmp/nixnas-2boot.XXXXXX)"
# A fresh clone checks the demo key out 0644 and OpenSSH refuses world-readable
# private keys — use a 0600 copy, never the repo file directly.
KEY="$WORK/demo_key"
install -m600 "$HERE/ssh/demo_key" "$KEY"
SCRATCH="$WORK/disk.raw"
SWTPM_PID=""
# cleanup also reaps any qemu still bound to THIS run's unique scratch path. $SCRATCH is an
# mktemp path that never appears in this script's own cmdline, so the match can't self-target.
cleanup(){
  pkill -f "$SCRATCH" 2>/dev/null || true   # pkill excludes its own PID; $SCRATCH is unique to this run
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
cp "$OVMF_VARS_TMPL" "$WORK/OVMF_VARS.fd"   # persistent UEFI vars, reused both boots

# Software TPM2. A FRESH swtpm per boot, both against the SAME persistent --tpmstate dir:
# the state dir persists the SRK/NV (so the sealed blob stays decryptable), while each boot
# resets the volatile PCRs to zero and the firmware re-extends PCR 7 to the SAME (deterministic
# Secure-Boot-state) value — which is why seal (boot #1 stage-2) and unseal (boot #2 initrd)
# agree. Reusing one long-lived swtpm would instead DOUBLE-extend PCR 7 and break the unseal.
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
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=4 root@127.0.0.1)

# Launch QEMU against the persistent scratch + persistent tpm/vars. $1 = extra stdin feeder.
run_qemu() { # run_qemu <logfile>
  qemu-system-x86_64 \
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

# ─────────────────────────────── BOOT #1 — seal ───────────────────────────────
# Drive the serial via a FIFO (not a `… | qemu` pipe) so $VM1 is PURELY qemu's PID — a
# pipeline PID would keep the passphrase-feeder alive and make the later wait hang.
LOG1="$WORK/boot1.log"; FIFO1="$WORK/in1"; mkfifo "$FIFO1"
echo ">> BOOT #1: unlocking over serial, waiting for the host key to be sealed …"
start_swtpm
run_qemu < "$FIFO1" > "$LOG1" 2>&1 &
VM1=$!
exec 3> "$FIFO1"                       # hold the write end open so qemu's serial stays live
( sleep 32; printf '%s\n' "$PASS" >&3 ) &   # feed the passphrase once the unlock prompt is up
FEED1=$!
sealed=0
for _ in $(seq 1 75); do
  kill -0 "$VM1" 2>/dev/null || { echo "!! boot #1 VM exited early"; break; }
  # The running-system sshd (demo key) is up at multi-user; confirm the sealed credential exists.
  if "${SSH[@]}" -o BatchMode=yes 'test -f /boot/loader/credentials/nixnas-initrd-hostkey.cred' 2>/dev/null; then
    sealed=1; break
  fi
  sleep 4
done
kill "$FEED1" 2>/dev/null || true
if [ "$sealed" != 1 ]; then
  echo "!! boot #1 never produced the sealed blob. Serial tail:"; tail -30 "$LOG1"; exit 1
fi
echo ">> boot #1: sealed blob present on the ESP …"
# CI quality gate: the sealed-blob marker only proves the happy path progressed — a
# failed oneshot behind it would sail through. The booted system must be CLEAN.
assert_no_failed_units "boot #1 (running system)" || exit 1
echo ">> powering off cleanly over SSH …"
"${SSH[@]}" 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM1" 2>/dev/null || break; sleep 2; done
exec 3>&-                              # release the FIFO writer
kill "$VM1" 2>/dev/null || true; wait "$VM1" 2>/dev/null || true; rm -f "$FIFO1"

# ─────────────────────────────── BOOT #2 — unseal ─────────────────────────────
LOG2="$WORK/boot2.log"
if [ "$TAMPER" = 1 ]; then
  echo ">> BOOT #2 (TAMPER): fresh TPM (different SRK) — unseal MUST fail, sshd MUST NOT come up …"
  start_swtpm "$WORK/tpm-fresh"   # a brand-new TPM: different storage seed ⇒ cannot unseal boot #1's cred
else
  echo ">> BOOT #2: NO serial passphrase — initrd must unseal the host key to bring up sshd …"
  start_swtpm   # fresh PCRs against the same persisted SRK/NV; firmware re-extends PCR 7 to seal-time value
fi
run_qemu < /dev/null > "$LOG2" 2>&1 &
VM2=$!
kill_vm2(){ kill "$VM2" 2>/dev/null; pkill -P "$VM2" 2>/dev/null; }
trap 'kill_vm2; cleanup' EXIT

up=0
for _ in $(seq 1 60); do
  kill -0 "$VM2" 2>/dev/null || { echo "!! boot #2 VM exited early"; break; }
  # initrd-SSH answering === the initrd unsealed the key (else sshd never started).
  if "${SSH[@]}" -o BatchMode=yes true 2>/dev/null; then up=1; break; fi
  sleep 2
done

# ── TAMPER mode: a NON-unlock is the PASS (the wrong TPM must not be able to unseal). ──
if [ "$TAMPER" = 1 ]; then
  echo "================ RESULT (TAMPER) ================"
  if [ "$up" = 1 ]; then
    echo "FAIL — initrd-SSH came up on a DIFFERENT TPM. The key is NOT bound to this box's TPM!"
    tail -30 "$LOG2"; exit 1
  fi
  echo "PASS — a fresh/wrong TPM could NOT unseal the host key; initrd-SSH stayed down."
  echo "       Proof the key is genuinely sealed to THIS box's TPM (SRK), not any TPM."
  echo "       credential-load failure on the serial:"
  grep -aiE "credential|initrd-hostkey|LoadCredential|decrypt|tpm" "$LOG2" | tail -12
  exit 0
fi

# ── Positive mode: initrd-SSH must come up (proves the unseal), then unlock to login. ──
if [ "$up" != 1 ]; then
  echo "!! initrd-SSH never came up in boot #2 — the initrd unseal FAILED."
  cp "$LOG2" /tmp/nixnas-boot2-serial.log 2>/dev/null || true
  echo "   (full serial saved to /tmp/nixnas-boot2-serial.log)"
  echo "   credential / sshd output:"; grep -aiE "credential|initrd-hostkey|sshd|hostkey|TPM|tpm2|decrypt|LoadCredential" "$LOG2" | tail -25
  exit 1
fi
echo ">> initrd-SSH up in boot #2 — the initrd unsealed the TPM-sealed host key. ✔"

echo ">> handing the store passphrase to the initrd password agent over SSH …"
printf '%s\n' "$PASS" | "${SSH[@]}" -tt 'systemd-tty-ask-password-agent --query' 2>/dev/null || true

ok=0
for _ in $(seq 1 40); do
  grep -q 'demo login:' "$LOG2" && { ok=1; break; }
  kill -0 "$VM2" 2>/dev/null || break
  sleep 2
done

# CI quality gate on the boot-#2 RUNNING system: after switch-root the forwarded port
# moves from initrd-SSH to the running sshd — reconnect and require zero failed units.
clean=1
if [ "$ok" = 1 ]; then
  assert_no_failed_units_after_ssh_wait "boot #2 (running system)" 20 || clean=0
fi

echo "================ RESULT ================"
if [ "$ok" = 1 ] && [ "$clean" = 1 ]; then
  echo "PASS — sealed in boot #1; boot #2 unsealed the host key in the initrd, initrd-SSH"
  echo "       came up, the store was unlocked over the network, box reached login headless,"
  echo "       and systemctl --failed is empty on both booted systems."
elif [ "$ok" != 1 ]; then
  echo "FAIL — initrd-SSH came up but the unlock hand-off did not reach login. Serial tail:"
  tail -40 "$LOG2"
else
  echo "FAIL — boot #2 reached login but the booted system has FAILED units (see gate output above)."
fi
[ "$ok" = 1 ] && [ "$clean" = 1 ]
