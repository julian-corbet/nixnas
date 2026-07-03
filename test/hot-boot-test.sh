#!/usr/bin/env bash
# test/hot-boot-test.sh — prove the HOT-mode boot path (modules/store/location.nix).
#
# THE CLAIM UNDER TEST: a nixnas MAIN boots its /nix from an EXTERNAL, operator-key-unlocked
# LUKS device — the initrd opens the device with the OPERATOR'S passphrase (interactive, no
# TPM/auto), mounts it as /nix, and switch-roots into the full system.
#
# It DIRECT-KERNEL-BOOTS the demo-hot toplevel (-kernel/-initrd) rather than going through the
# ESP/UKI/Secure-Boot chain — that chain is already proven by the usb boot-test (test/
# seal-2boot-test.sh), and the rescue is itself a usb nixnas. What is NEW in hot mode, and all
# this file tests, is the initrd unlock-external-device + mount-/nix step.
#
# The disk is a single GPT partition labelled `nixstore-demo` (matching hosts/demo-hot.nix's
# store.hot.unlock), LUKS2 + ext4, pre-populated with the toplevel closure via `nix copy` to a
# chroot store — the SAME primitive rescue-maintain uses, so this doubly validates that path.
# At the initrd's LUKS prompt we feed the passphrase over serial; PASS == the box reaches
# `demo login:` (the store was unlocked with the operator key and mounted as /nix).
#
# Needs root (losetup/cryptsetup/mount); CI runs it under sudo. No TPM, no OVMF.
# Usage: [FLAKE=.] [PASS=nixnas-hot] test/hot-boot-test.sh
set -uo pipefail

FLAKE="${FLAKE:-.}"
PASS="${PASS:-nixnas-hot}"

for c in nix qemu-system-x86_64 sgdisk cryptsetup mkfs.ext4 mkfs.vfat losetup; do
  command -v "$c" >/dev/null || { echo "!! missing tool: $c" >&2; exit 1; }
done
[ "$(id -u)" = 0 ] || { echo "!! must run as root (losetup/cryptsetup/mount)" >&2; exit 1; }

WORK="$(mktemp -d /tmp/nixnas-hot.XXXXXX)"
DISK="$WORK/nix.raw"
LOOP=""; MAPPER=""; MNT=""
cleanup() {
  [ -n "$MNT" ] && umount "$MNT" 2>/dev/null
  [ -n "$MAPPER" ] && cryptsetup close nixstore-demo 2>/dev/null
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  pkill -f "$DISK" 2>/dev/null   # reap any qemu bound to THIS run's unique disk path
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. build the hot toplevel (also realizes the full closure + initrd = a build check) ──
echo ">> building demo-hot toplevel …"
TOP="$(nix build --no-link --print-out-paths \
  "$FLAKE#nixosConfigurations.demo-hot.config.system.build.toplevel")" \
  || { echo "!! toplevel build failed" >&2; exit 1; }
echo "   toplevel: $TOP"

# ── 2. assemble the disk: a labelled ESP (for the /boot mount) + the LUKS+ext4 /nix ──
# demo-hot mounts /boot by-label NIXNAS-ESP (it shares the stick ESP in reality); without it
# the boot drops to emergency mode. This is direct-kernel-boot, so the ESP need only exist +
# carry the label — no bootloader is installed on it.
echo ">> assembling the disk (ESP NIXNAS-ESP + LUKS+ext4 /nix + a 2nd bare LUKS member) …"
truncate -s 6G "$DISK"
sgdisk -n1:0:+64M -t1:EF00 -c1:esp \
       -n2:0:+5G  -t2:8300 -c2:nixstore-demo \
       -n3:0:0    -t3:8300 -c3:nixstore-demo2 "$DISK" >/dev/null
LOOP="$(losetup --find --show --partscan "$DISK")"
mkfs.vfat -n NIXNAS-ESP "${LOOP}p1" >/dev/null
part="${LOOP}p2"
[ -b "$part" ] || { echo "!! loop partition $part not present" >&2; exit 1; }
# Fast KDF (pbkdf2, low iters) — this is a throwaway CI volume, not a real secret.
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "$part" -
# The 2nd member (same passphrase, NO filesystem): it exists to prove the SERIALISED
# single-entry unlock — the initrd must open it from the kernel-keyring cache without a
# second prompt (the feeder below deliberately answers only ONCE).
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "${LOOP}p3" -
echo -n "$PASS" | cryptsetup open "$part" nixstore-demo -; MAPPER=1
mkfs.ext4 -q -L nixstore /dev/mapper/nixstore-demo
# Mount at $ROOT/nix so $ROOT is a chroot-store root (store at $ROOT/nix/store) — exactly the
# shape rescue-maintain copies into.
ROOT="$WORK/root"; MNT="$ROOT/nix"; mkdir -p "$MNT"
mount /dev/mapper/nixstore-demo "$MNT"
echo ">> copying the toplevel closure onto the ext4 store (nix copy → chroot store) …"
nix copy --no-check-sigs --to "$ROOT" "$TOP" || { echo "!! nix copy to the chroot store failed" >&2; exit 1; }
sync
umount "$MNT"; MNT=""
cryptsetup close nixstore-demo; MAPPER=""
losetup -d "$LOOP"; LOOP=""

# ── 3. direct-kernel-boot; feed the passphrase to the initrd LUKS prompt over serial ──
echo ">> booting (direct kernel) — the initrd must unlock nixstore-demo with the operator key …"
LOG="$WORK/serial.log"; FIFO="$WORK/in"; mkfifo "$FIFO"
ACCEL=""; [ -e /dev/kvm ] && ACCEL=",accel=kvm"
qemu-system-x86_64 \
  -machine "q35${ACCEL}" -cpu "$([ -e /dev/kvm ] && echo host || echo max)" -smp 2 -m 2048 \
  -kernel "$TOP/kernel" -initrd "$TOP/initrd" \
  -append "init=$TOP/init $(cat "$TOP/kernel-params") console=ttyS0" \
  -drive if=virtio,format=raw,file="$DISK" \
  -netdev user,id=n0 -device virtio-net,netdev=n0 \
  -nographic -serial "mon:stdio" -no-reboot < "$FIFO" > "$LOG" 2>&1 &
VM=$!
exec 3> "$FIFO"                        # hold the FIFO writer open so the serial stays live

# Feed the passphrase EXACTLY ONCE. Two LUKS members are enrolled; the serialised unlock
# (location.nix drop-ins) must open the second from the kernel-keyring cache with no second
# prompt — if it re-prompts, the boot hangs and the test FAILS. That is the assertion.
fed=0
for _ in $(seq 1 60); do
  kill -0 "$VM" 2>/dev/null || break
  if grep -qaiE 'please enter|passphrase for|unlocking|nixstore-demo' "$LOG" && [ "$fed" -lt 1 ]; then
    printf '%s\n' "$PASS" >&3; fed=$((fed+1)); sleep 3; continue
  fi
  grep -qa 'demo login:' "$LOG" && break
  sleep 2
done

ok=0
for _ in $(seq 1 20); do
  grep -qa 'demo login:' "$LOG" && { ok=1; break; }
  kill -0 "$VM" 2>/dev/null || break
  sleep 2
done
exec 3>&-
kill "$VM" 2>/dev/null; wait "$VM" 2>/dev/null

echo "================ RESULT ================"
if [ "$ok" = 1 ]; then
  echo "PASS — the initrd unlocked the EXTERNAL LUKS device with the operator passphrase,"
  echo "       mounted it as /nix, and the hot-mode system reached login. (location.nix ✔)"
  exit 0
fi
echo "FAIL — the hot-mode system did not reach login. Serial tail:"
tail -50 "$LOG"
exit 1
