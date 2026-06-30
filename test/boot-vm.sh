#!/usr/bin/env bash
# test/boot-vm.sh — lean QEMU rig to BOOT a built nixnas image and watch the boot chain.
#
# Division of labour (respects "build on the capable machine, not here"):
#   * the IMAGE is BUILT on the cluster (heavy Nix eval/build) — see test/README.md;
#   * this script only BOOTS the finished .raw locally, in a deliberately tiny VM.
# It models the real appliance firmware so the boot chain is meaningful:
#   UEFI (OVMF) + Secure Boot variant + a software TPM2 (swtpm) + serial-only console
#   (the box is headless) + a virtio disk (usb-storage corrupts large reads — learned in v0)
#   + snapshot=on (the image file is never mutated — re-runnable, safe).
#
# Usage:  test/boot-vm.sh <image.raw> [--secboot] [--mem MB] [--smp N] [--ssh PORT]
#   --secboot   use the Secure-Boot OVMF firmware (enforces signature checks)
#   --mem 2048  guest RAM in MiB     (default 2048 — lean; the appliance must fit small boxes)
#   --smp 2     guest vCPUs          (default 2)
#   --ssh 2222  forward host :PORT -> guest :22 (to reach initrd-SSH / the running sshd)
set -euo pipefail

IMG="${1:?usage: boot-vm.sh <image.raw> [--secboot] [--mem MB] [--smp N] [--ssh PORT]}"; shift
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
SECBOOT=0; MEM=2048; SMP=2; SSHFWD=""; PASS=""; PASS_DELAY=28
while [ $# -gt 0 ]; do case "$1" in
  --secboot) SECBOOT=1 ;;
  --mem) MEM="${2:?}"; shift ;;
  --smp) SMP="${2:?}"; shift ;;
  --ssh) SSHFWD="$2"; shift ;;
  --passphrase) PASS="$2"; shift ;;        # type this on the serial after the LUKS/TPM2 prompt
  --pass-delay) PASS_DELAY="$2"; shift ;;  # seconds to wait before typing it (default 28)
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done

# --- locate OVMF firmware (Arch ships it under edk2-ovmf/x64 or edk2/x64) ---
FWDIR=""
for d in /usr/share/edk2-ovmf/x64 /usr/share/edk2/x64 /usr/share/OVMF; do
  [ -e "$d/OVMF_CODE.4m.fd" ] && { FWDIR="$d"; break; }
done
[ -n "$FWDIR" ] || { echo "OVMF firmware not found (install edk2-ovmf)" >&2; exit 1; }
if [ "$SECBOOT" = 1 ]; then CODE="$FWDIR/OVMF_CODE.secboot.4m.fd"; else CODE="$FWDIR/OVMF_CODE.4m.fd"; fi
[ -f "$CODE" ] || { echo "missing firmware: $CODE" >&2; exit 1; }

WORK="$(mktemp -d /tmp/nixnas-vm.XXXXXX)"
SWTPM_PID=""
cleanup(){ [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# writable per-run copy of the UEFI variable store (holds SB keys / boot entries)
cp "$FWDIR/OVMF_VARS.4m.fd" "$WORK/OVMF_VARS.fd"

# --- software TPM2 (for TPM2-with-PIN unlock + measured boot) ---
mkdir -p "$WORK/tpm"
swtpm socket --tpm2 --tpmstate dir="$WORK/tpm" \
  --ctrl type=unixio,path="$WORK/tpm/sock" \
  --pid file="$WORK/tpm/pid" --daemon
SWTPM_PID="$(cat "$WORK/tpm/pid")"

NET="user,id=n0"; [ -n "$SSHFWD" ] && NET="$NET,hostfwd=tcp::${SSHFWD}-:22"

echo ">> booting $IMG  (mem=${MEM}MiB smp=${SMP} secboot=${SECBOOT}${SSHFWD:+ ssh=$SSHFWD->22})"
echo ">> serial console below — Ctrl-a x to quit, Ctrl-a c for the QEMU monitor"
QEMU=(
  qemu-system-x86_64
  -machine q35,smm=on,accel=kvm -cpu host -smp "$SMP" -m "$MEM"
  -global ICH9-LPC.disable_s3=1
  -global driver=cfi.pflash01,property=secure,value=on
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE"
  -drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd"
  -chardev socket,id=chrtpm,path="$WORK/tpm/sock"
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0
  -drive if=virtio,format=raw,snapshot=on,file="$IMG"
  -netdev "$NET" -device virtio-net,netdev=n0
  -nographic
)
if [ -n "$PASS" ]; then
  # Feed the LUKS/TPM2 passphrase to the guest serial once the unlock prompt is up.
  echo ">> will type the passphrase on serial after ${PASS_DELAY}s"
  { sleep "$PASS_DELAY"; printf '%s\n' "$PASS"; sleep 100000; } | "${QEMU[@]}" -serial mon:stdio
else
  exec "${QEMU[@]}" -serial mon:stdio
fi
