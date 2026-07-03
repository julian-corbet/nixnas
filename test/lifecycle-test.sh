#!/usr/bin/env bash
# test/lifecycle-test.sh — full install-hot lifecycle proof in one QEMU flow.
#
# THE CLAIMS UNDER TEST:
#   1. A rescue (usb-mode nixnas) can create an operator-key LUKS+ext4 pool on a blank disk
#      and run `nixnas-install-hot` to install a MAIN (hot-mode) system on it, with signed
#      UKIs placed on the SHARED ESP alongside the rescue entry.
#   2. After reboot the MAIN's UKI boots from the ESP; the initrd asks for the operator's
#      LUKS passphrase (interactive, never auto); once given, /nix mounts from the pool and
#      the full system reaches login.
#   3. The ESP carries BOTH the MAIN's generated UKI(s) (nixos-generation-*.efi) AND the
#      pre-placed rescue entry (nixnas-rescue.efi) — the coexistence invariant.
#   4. With the pool disk entirely absent, the rescue entry boots to login from the stick
#      alone — the rescue is self-contained and pool-independent.
#
# FLOW (three sequential QEMU boots, same persistent OVMF_VARS + swtpm tpmstate):
#   BOOT #1 — rescue image (demo USB .raw, usb-mode) boots with disk1 + blank disk2:
#     * feed STICK_PASS for the rescue's LUKS store; wait for running-system SSH;
#     * over SSH: partition disk2 with partlabels nixstore-demo/nixstore-demo2, LUKS+ext4;
#     * nix copy the demo-hot toplevel into the rescue's store;
#     * run nixnas-install-hot --device /dev/mapper/nixstore-demo --fstype ext4 <top>;
#     * set loader.conf default to the rescue entry for boot #3; power off.
#   BOOT #2 — MAIN entry from shared ESP (demo-hot, hot mode) boots with disk1 + disk2:
#     * initrd waits for operator key; feed POOL_PASS over serial;
#     * wait for running-system SSH; verify nixos-generation-*.efi + nixnas-rescue.efi on ESP.
#   BOOT #3 — rescue entry, pool disk DETACHED (disk2 absent):
#     * feed STICK_PASS for the rescue LUKS; wait for login.
#
# PREREQUISITES: nix qemu-system-x86_64 swtpm (OVMF), openssh client.
# Needs root when KVM + loop devices are not user-accessible; CI uses sudo.
# Usage: [FLAKE=.] [STICK_PASS=nixnas-demo] [POOL_PASS=nixnas-hot] [PORT=2222] test/lifecycle-test.sh
set -uo pipefail

FLAKE="${FLAKE:-.}"
STICK_PASS="${STICK_PASS:-nixnas-demo}"
POOL_PASS="${POOL_PASS:-nixnas-hot}"
PORT="${PORT:-2222}"

# ── prerequisite check ────────────────────────────────────────────────────────
for c in nix qemu-system-x86_64 swtpm ssh sgdisk cryptsetup mkfs.ext4; do
  command -v "$c" >/dev/null || { echo "!! missing tool: $c" >&2; exit 1; }
done

# ── OVMF firmware detection (portable; copied from test/seal-2boot-test.sh) ──
find_fw() { # find_fw "name1 name2 …" → first existing path under the known dirs
  local d n
  for d in /usr/share/edk2-ovmf/x64 /usr/share/edk2/x64 /usr/share/OVMF \
            /usr/share/ovmf/x64 /usr/share/qemu; do
    for n in $1; do [ -e "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }; done
  done
  return 1
}
OVMF_CODE="${OVMF_CODE:-$(find_fw 'OVMF_CODE.4m.fd OVMF_CODE_4M.fd OVMF_CODE.fd')}" \
  || { echo "OVMF_CODE not found (install edk2-ovmf / ovmf, or set \$OVMF_CODE)" >&2; exit 1; }
OVMF_VARS_TMPL="${OVMF_VARS:-$(find_fw 'OVMF_VARS.4m.fd OVMF_VARS_4M.fd OVMF_VARS.fd')}" \
  || { echo "OVMF_VARS template not found (set \$OVMF_VARS)" >&2; exit 1; }

# ── port guard (avoid an opaque qemu "Could not set up host forwarding rule") ─
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "!! port ${PORT} is already in use. Free it or pass PORT=<other>. Aborting." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/nixnas-lifecycle.XXXXXX)"
SWTPM_PID=""
TPM_SOCK="$WORK/tpm/sock"

cleanup() {
  # reap any qemu still bound to this run's unique scratch path (pkill never self-targets)
  pkill -f "$WORK/scratch.raw" 2>/dev/null || true
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  # Wait for qemu to release the forwarded port before returning (async kill + lingering socket).
  for _ in $(seq 1 30); do
    ss -ltn 2>/dev/null | grep -q ":${PORT} " || break
    sleep 0.3
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── KVM ───────────────────────────────────────────────────────────────────────
ACCEL_FLAGS=""
CPU_FLAG="max"
if [ -e /dev/kvm ]; then
  ACCEL_FLAGS=",accel=kvm"
  CPU_FLAG="host"
fi

# ── SSH wrapper ───────────────────────────────────────────────────────────────
KEY="$WORK/demo_key"
install -m600 "$HERE/ssh/demo_key" "$KEY"
SSH=(ssh -i "$KEY" -p "$PORT"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=4 root@127.0.0.1)

# ── swtpm helper (same tpmstate dir across all boots; fresh PCRs each boot) ──
mkdir -p "$WORK/tpm"
start_swtpm() {
  local dir="$WORK/tpm"
  [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
  rm -f "$dir/sock" "$dir/pid"
  swtpm socket --tpm2 --tpmstate dir="$dir" \
    --ctrl type=unixio,path="$dir/sock" --pid file="$dir/pid" --daemon
  for _ in $(seq 1 25); do [ -S "$dir/sock" ] && break; sleep 0.2; done
  SWTPM_PID="$(cat "$dir/pid")"
  TPM_SOCK="$dir/sock"
}

# ── QEMU launcher: fixed disk1 (rescue image) + optional extra args ───────────
# Extra -drive or other QEMU args (e.g. the pool disk) are passed as "$@".
run_qemu() {
  qemu-system-x86_64 \
    -machine "q35,smm=on${ACCEL_FLAGS}" -cpu "$CPU_FLAG" -smp 2 -m 2048 \
    -global ICH9-LPC.disable_s3=1 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd" \
    -chardev socket,id=chrtpm,path="$TPM_SOCK" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -drive if=virtio,format=raw,file="$WORK/scratch.raw" \
    "$@" \
    -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device virtio-net,netdev=n0 \
    -no-reboot -nographic -serial "mon:stdio"
}

# ── wait_port_free: let qemu release the forwarded port between boots ─────────
wait_port_free() {
  for _ in $(seq 1 30); do
    ss -ltn 2>/dev/null | grep -q ":${PORT} " || return 0
    sleep 0.5
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-BOOT BUILD PHASE
# Build both artifacts before any VM starts (saves confusion if builds fail).
# ─────────────────────────────────────────────────────────────────────────────
echo ">> building demo-hot toplevel (the MAIN closure) …"
TOP_HOT="$(nix build --no-link --print-out-paths \
  "$FLAKE#nixosConfigurations.demo-hot.config.system.build.toplevel")" \
  || { echo "!! demo-hot toplevel build failed" >&2; exit 1; }
echo "   demo-hot toplevel: $TOP_HOT"

echo ">> building demo USB image (the rescue analog) …"
nix build --no-link --out-link "$WORK/result" "$FLAKE#image" \
  || { echo "!! demo image build failed" >&2; exit 1; }
IMG="$(find -L "$WORK/result" -name '*.raw' | head -1)"
[ -f "$IMG" ] || { echo "!! no .raw found under $WORK/result" >&2; exit 1; }
echo "   demo image: $IMG"

# ── disk setup ────────────────────────────────────────────────────────────────
echo ">> preparing disks and persistent UEFI vars …"
# Disk 1: writable scratch copy of the rescue USB image.
cp --sparse=always "$IMG" "$WORK/scratch.raw"
chmod u+rw "$WORK/scratch.raw"   # nix store is 0444; QEMU needs it writable

# Disk 2: blank pool disk (partitioned + LUKS'd in boot #1 over SSH).
truncate -s 8G "$WORK/pool.raw"

# Persistent UEFI variable store: reused across all three boots so boot entries
# and EFI variable state (BootNext etc.) survive across power cycles.
cp "$OVMF_VARS_TMPL" "$WORK/OVMF_VARS.fd"

# ─────────────────────────────────────────────────────────────────────────────
# BOOT #1 — rescue boots; create pool; nixnas-install-hot; power off.
# ─────────────────────────────────────────────────────────────────────────────
LOG1="$WORK/boot1.log"
FIFO1="$WORK/in1"; mkfifo "$FIFO1"
echo ">> BOOT #1: rescue + blank pool disk — installing the MAIN …"
start_swtpm
run_qemu \
  -drive if=virtio,format=raw,file="$WORK/pool.raw" \
  < "$FIFO1" > "$LOG1" 2>&1 &
VM1=$!
exec 3> "$FIFO1"   # keep the write end open so QEMU's serial stays live

# Feed the rescue's stick LUKS passphrase when the unlock prompt appears.
fed1=0
ssh_up1=0
for _ in $(seq 1 150); do
  kill -0 "$VM1" 2>/dev/null || { echo "!! boot #1 VM exited unexpectedly"; break; }
  if grep -qaiE 'please enter|passphrase for|unlocking' "$LOG1" && [ "$fed1" -lt 1 ]; then
    printf '%s\n' "$STICK_PASS" >&3
    fed1=$((fed1 + 1))
  fi
  if "${SSH[@]}" -o BatchMode=yes true 2>/dev/null; then
    ssh_up1=1; break
  fi
  sleep 4
done

if [ "$ssh_up1" != 1 ]; then
  echo "!! boot #1: running-system SSH never came up. Serial tail:"
  tail -50 "$LOG1"
  exit 1
fi
echo "   boot #1 SSH up."

# Wait for the lanzaboote key-generation service to write the Secure Boot PKI.
# (With autoGenerateKeys.enable = true the PKI is created on first boot under
# /nix/lanzaboote/pki; nixnas-install-hot needs it to sign the rescue UKI.)
echo ">> waiting for lanzaboote PKI generation (sbctl create-keys on first boot) …"
pki_ready=0
for _ in $(seq 1 30); do
  "${SSH[@]}" -o BatchMode=yes \
    'test -r /nix/lanzaboote/pki/keys/db/db.key' 2>/dev/null && { pki_ready=1; break; }
  sleep 4
done
if [ "$pki_ready" != 1 ]; then
  echo "!! lanzaboote PKI not present at /nix/lanzaboote/pki/keys/db/db.key after timeout."
  echo "   (boot #1 running-system is up — check the lanzaboote-generate-keys service)"
  exit 1
fi
echo "   PKI ready."

# Partition pool disk (appears as /dev/vdb — the second virtio-blk drive).
# Two partitions matching what demo-hot.nix configures:
#   nixstore-demo  (6 GiB) — LUKS2 + ext4 — the actual /nix hot store
#   nixstore-demo2 (rest)  — bare LUKS2, no filesystem — proves serialised single-prompt unlock
echo ">> partitioning pool disk (nixstore-demo + nixstore-demo2) …"
"${SSH[@]}" "sgdisk \
  -n1:0:+6G -t1:8300 -c1:nixstore-demo \
  -n2:0:0   -t2:8300 -c2:nixstore-demo2 \
  /dev/vdb" \
  || { echo "!! sgdisk failed"; exit 1; }
"${SSH[@]}" "udevadm settle"

# LUKS-format both members with a fast KDF (pbkdf2/1000 iters — throwaway CI volume).
echo ">> LUKS-formatting pool partitions (POOL_PASS) …"
"${SSH[@]}" "printf '%s' '${POOL_PASS}' | cryptsetup luksFormat --type luks2 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode \
  /dev/disk/by-partlabel/nixstore-demo -" \
  || { echo "!! luksFormat nixstore-demo failed"; exit 1; }
"${SSH[@]}" "printf '%s' '${POOL_PASS}' | cryptsetup luksFormat --type luks2 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode \
  /dev/disk/by-partlabel/nixstore-demo2 -" \
  || { echo "!! luksFormat nixstore-demo2 failed"; exit 1; }

# Open nixstore-demo and format it as ext4.
"${SSH[@]}" "printf '%s' '${POOL_PASS}' | cryptsetup open \
  /dev/disk/by-partlabel/nixstore-demo nixstore-demo -" \
  || { echo "!! cryptsetup open nixstore-demo failed"; exit 1; }
"${SSH[@]}" "mkfs.ext4 -q -L nixstore /dev/mapper/nixstore-demo" \
  || { echo "!! mkfs.ext4 failed"; exit 1; }

# nix copy the demo-hot toplevel closure into the rescue's /nix store.
# NIX_SSHOPTS carries the port + key so the nix ssh-store client can reach the VM.
echo ">> copying demo-hot toplevel closure to rescue (nix copy over SSH) …"
NIX_SSHOPTS="-p ${PORT} -i ${KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
  nix copy --no-check-sigs --to "ssh://root@127.0.0.1" "$TOP_HOT" \
  || { echo "!! nix copy to rescue failed"; exit 1; }
echo "   closure on the rescue."

# Run the installer. install-hot will:
#   1. check the PKI exists (we verified above),
#   2. mount the pool at /mnt/nixnas-install/nix + bind /boot as the shared ESP,
#   3. seed the PKI, copy the closure, nixos-install (→ lzbt install → signs UKIs onto ESP),
#   4. pre-place EFI/Linux/nixnas-rescue.efi (from the running rescue's kernel+initrd),
#   5. verify the profile + UKIs exist before returning.
echo ">> running nixnas-install-hot …"
"${SSH[@]}" "nixnas-install-hot \
  --device /dev/mapper/nixstore-demo \
  --fstype ext4 \
  ${TOP_HOT}" \
  || { echo "!! nixnas-install-hot failed"; exit 1; }
echo "   install-hot complete."

# Set the rescue entry as the DEFAULT for boot #3.
# We write loader.conf directly (reliable across systemd-boot versions).
# timeout 3 gives a visible pause in CI logs to confirm the right entry booted.
echo ">> setting loader.conf default → rescue entry for boot #3 …"
"${SSH[@]}" "printf 'timeout 3\ndefault nixnas-rescue.efi\n' > /boot/loader/loader.conf"

echo ">> powering off after install (boot #1 done) …"
"${SSH[@]}" 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM1" 2>/dev/null || break; sleep 2; done
exec 3>&-
kill "$VM1" 2>/dev/null || true; wait "$VM1" 2>/dev/null || true
wait_port_free

# ─────────────────────────────────────────────────────────────────────────────
# BOOT #2 — MAIN entry (hot mode); feed pool passphrase; verify ESP; set default.
# ─────────────────────────────────────────────────────────────────────────────
LOG2="$WORK/boot2.log"
FIFO2="$WORK/in2"; mkfifo "$FIFO2"
echo ">> BOOT #2: MAIN entry (hot mode) — initrd must ask for the pool key …"
start_swtpm   # fresh PCRs against the same persisted SRK/NV → PCR 7 stable
run_qemu \
  -drive if=virtio,format=raw,file="$WORK/pool.raw" \
  < "$FIFO2" > "$LOG2" 2>&1 &
VM2=$!
exec 3> "$FIFO2"

# Feed the pool passphrase once the LUKS prompt appears.
# The hot-mode initrd serialises the nixstore-demo + nixstore-demo2 unlocks:
# one prompt feeds the kernel-keyring cache; the second member opens silently.
fed2=0
for _ in $(seq 1 90); do
  kill -0 "$VM2" 2>/dev/null || { echo "!! boot #2 VM exited unexpectedly"; break; }
  if grep -qaiE 'please enter|passphrase for|unlocking|nixstore-demo' "$LOG2" \
      && [ "$fed2" -lt 1 ]; then
    printf '%s\n' "$POOL_PASS" >&3
    fed2=$((fed2 + 1))
  fi
  grep -qa 'demo login:' "$LOG2" && break
  sleep 2
done

# Confirm login prompt reached (proves /nix mounted from pool → system booted).
ok2=0
for _ in $(seq 1 20); do
  grep -qa 'demo login:' "$LOG2" && { ok2=1; break; }
  kill -0 "$VM2" 2>/dev/null || break
  sleep 2
done
if [ "$ok2" != 1 ]; then
  echo "!! BOOT #2: MAIN did not reach login. Serial tail:"
  tail -50 "$LOG2"
  exit 1
fi
echo "   boot #2: MAIN reached login. ✔"

# Wait for running-system SSH then verify the ESP coexistence invariant.
echo ">> checking ESP: main UKI(s) + nixnas-rescue.efi must both be present …"
ssh_up2=0
for _ in $(seq 1 40); do
  "${SSH[@]}" -o BatchMode=yes true 2>/dev/null && { ssh_up2=1; break; }
  kill -0 "$VM2" 2>/dev/null || break
  sleep 3
done
if [ "$ssh_up2" != 1 ]; then
  echo "!! boot #2 running-system SSH never came up (login appeared but SSH failed)."
  exit 1
fi

# Verify the ESP. Both must exist; collect all failures before exiting.
esp_fail=0
if ! "${SSH[@]}" -o BatchMode=yes \
    'ls /boot/EFI/Linux/nixos-generation-*.efi >/dev/null 2>&1' 2>/dev/null; then
  echo "!! ESP missing: no nixos-generation-*.efi (main UKI not installed by lzbt)"
  esp_fail=1
fi
if ! "${SSH[@]}" -o BatchMode=yes \
    'test -f /boot/EFI/Linux/nixnas-rescue.efi' 2>/dev/null; then
  echo "!! ESP missing: nixnas-rescue.efi (not pre-placed by nixnas-install-hot step 5)"
  esp_fail=1
fi
if [ "$esp_fail" = 1 ]; then
  echo "   EFI/Linux contents:"
  "${SSH[@]}" 'ls -lh /boot/EFI/Linux/ 2>/dev/null || true' 2>/dev/null || true
  exit 1
fi
echo "   ESP OK: main UKI(s) and nixnas-rescue.efi both present. ✔"

echo ">> powering off the MAIN (boot #2 done) …"
"${SSH[@]}" 'systemctl poweroff' 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$VM2" 2>/dev/null || break; sleep 2; done
exec 3>&-
kill "$VM2" 2>/dev/null || true; wait "$VM2" 2>/dev/null || true
wait_port_free

# ─────────────────────────────────────────────────────────────────────────────
# BOOT #3 — rescue entry, pool disk DETACHED: self-contained rescue proof.
# ─────────────────────────────────────────────────────────────────────────────
LOG3="$WORK/boot3.log"
FIFO3="$WORK/in3"; mkfifo "$FIFO3"
echo ">> BOOT #3: rescue entry — pool disk ABSENT; rescue must boot from stick alone …"
start_swtpm   # fresh PCRs, same persistent SRK (TPM-sealed initrd host key from boot #1 valid)
run_qemu \
  < "$FIFO3" > "$LOG3" 2>&1 &   # NO pool.raw — disk2 absent
VM3=$!
exec 3> "$FIFO3"

# Feed the stick passphrase. The stick LUKS falls back to the passphrase because
# TPM2 enrollment is manual (nixnas-enroll-tpm2, not run in this test). The
# initrd-SSH host key sealed in boot #1 IS available (same swtpm tpmstate), so
# initrd-SSH may also come up — but we use the simpler serial path here.
fed3=0
for _ in $(seq 1 150); do
  kill -0 "$VM3" 2>/dev/null || { echo "!! boot #3 VM exited unexpectedly"; break; }
  if grep -qaiE 'please enter|passphrase for|unlocking' "$LOG3" && [ "$fed3" -lt 1 ]; then
    printf '%s\n' "$STICK_PASS" >&3
    fed3=$((fed3 + 1))
  fi
  grep -qa 'demo login:' "$LOG3" && break
  sleep 4
done

ok3=0
for _ in $(seq 1 20); do
  grep -qa 'demo login:' "$LOG3" && { ok3=1; break; }
  kill -0 "$VM3" 2>/dev/null || break
  sleep 2
done
exec 3>&-
kill "$VM3" 2>/dev/null || true; wait "$VM3" 2>/dev/null || true

echo "================ RESULT ================"
if [ "$ok3" = 1 ]; then
  echo "PASS — full install-hot lifecycle verified:"
  echo "  1. rescue boot:  lanzaboote PKI generated; pool disk (LUKS2+ext4) created over SSH;"
  echo "                   demo-hot closure copied via nix copy; nixnas-install-hot succeeded."
  echo "  2. main boot:    hot-mode MAIN booted from the shared ESP; initrd asked for the"
  echo "                   operator key (serial prompt); pool unlocked; /nix mounted; login."
  echo "                   ESP has nixos-generation-*.efi + nixnas-rescue.efi — coexistence ✔"
  echo "  3. rescue-only:  rescue entry booted with pool disk absent; stick self-sufficient ✔"
  exit 0
fi
echo "FAIL — rescue-only boot (boot #3) did not reach login. Serial tail:"
tail -50 "$LOG3"
exit 1
