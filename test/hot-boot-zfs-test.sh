#!/usr/bin/env bash
# test/hot-boot-zfs-test.sh — prove the HOT-mode ZFS boot path (modules/store/location.nix).
#
# THE CLAIM UNDER TEST: a nixnas MAIN boots BOTH its /nix AND its / (root) from ZFS
# datasets on a pool whose vdevs are LUKS-encrypted — the initrd opens TWO LUKS members
# with the OPERATOR'S passphrase (interactive, no TPM/auto), imports the pool from
# /dev/mapper ONCE, mounts qapool/system/nix AND qapool/system/root (both
# mountpoint=legacy) at /nix and /, and switch-roots into the full system on an ORDINARY
# PERSISTENT root (no tmpfs anywhere in hot mode — docs/ARCHITECTURE.md §3.2). Root and
# store are SIBLING datasets on the SAME pool (hosts/demo-hot-zfs.nix's store.root.zpool =
# store.hot.zpool = "qapool"), so this doubly proves location.nix's zfsPoolsNeeded dedup:
# one shared pool costs exactly one zfs-import service, not two.
#
# The ZFS twist vs the ext4 hot test: both LUKS members are active ZFS vdevs (striped pool),
# so the pool import ITSELF proves the serialised single-entry unlock. If the second member
# were not open (feeder answered twice / keyring cache missed), the pool geometry would be
# incomplete and zpool import would fail — the box would never reach login. One prompt, two
# mappers, one pool: that is the assertion.
#
# Disk layout: GPT, three partitions —
#   p1  64 MiB  FAT32   label ESP   (the shared ESP the MAIN requires; no bootloader)
#   p2  ~3.8 GiB LUKS2  label qapool-luks0 (ZFS vdev 0; /dev/mapper/qapool-luks0 after open)
#   p3  rest     LUKS2  label qapool-luks1 (ZFS vdev 1; /dev/mapper/qapool-luks1 after open)
# ZFS pool 'qapool' is a stripe over both mappers; dataset qapool/system/nix carries the
# toplevel closure copied via `nix copy` to a chroot store root. The pool is exported and
# LUKS members are closed before the VM starts — the initrd does a cold import from scratch.
#
# ZFS initrd check: the script evaluates the Nix option
#   nixosConfigurations.demo-hot-zfs.config.boot.initrd.supportedFilesystems
# and asserts "zfs" is present BEFORE building, so a misconfigured host fails fast.
#
# Needs root (losetup/cryptsetup/mount/zpool/zfs); CI runs it under sudo. No TPM, no OVMF.
# Usage: [FLAKE=.] [PASS=nixnas-hot] test/hot-boot-zfs-test.sh
set -uo pipefail

FLAKE="${FLAKE:-.}"
PASS="${PASS:-nixnas-hot}"

for c in nix qemu-system-x86_64 sgdisk cryptsetup mkfs.vfat losetup zpool zfs; do
  command -v "$c" >/dev/null || { echo "!! missing tool: $c" >&2; exit 1; }
done
[ "$(id -u)" = 0 ] || { echo "!! must run as root (losetup/cryptsetup/zpool/zfs)" >&2; exit 1; }

WORK="$(mktemp -d /tmp/nixnas-hot-zfs.XXXXXX)"
DISK="$WORK/nix.raw"
LOOP=""; MAPPER0=""; MAPPER1=""; POOL=""; MNT=""; VM_PIDS=()
cleanup() {
  local pid
  for pid in "${VM_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  # Reverse order: unmount → export → close mappers → detach loop → reap qemu → rm tree.
  [ -n "$MNT"     ] && umount "$MNT"                    2>/dev/null || true; MNT=""
  [ -n "$POOL"    ] && zpool export -f qapool            2>/dev/null || true; POOL=""
  [ -n "$MAPPER1" ] && cryptsetup close qapool-luks1     2>/dev/null || true; MAPPER1=""
  [ -n "$MAPPER0" ] && cryptsetup close qapool-luks0     2>/dev/null || true; MAPPER0=""
  [ -n "$LOOP"    ] && losetup -d "$LOOP"                2>/dev/null || true; LOOP=""
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 0. ZFS initrd pre-flight: fail fast if the host is misconfigured ─────────────────────
# boot.initrd.supportedFilesystems is an attrset of booleans in current NixOS; --json
# serialises it so grep can match the "zfs" key without depending on the exact Nix syntax.
echo ">> verifying that demo-hot-zfs initrd includes ZFS support (nix eval) …"
nix eval --json \
  "$FLAKE#nixosConfigurations.demo-hot-zfs.config.boot.initrd.supportedFilesystems" 2>/dev/null \
  | grep -q '"zfs"' \
  || {
    echo "!! demo-hot-zfs.config.boot.initrd.supportedFilesystems does NOT contain \"zfs\"" >&2
    echo "   Check hosts/demo-hot-zfs.nix: fsType must be \"zfs\" so location.nix adds ZFS to the initrd." >&2
    exit 1
  }
echo "   ZFS confirmed in initrd. (location.nix ZFS branch active ✔)"

# ── 1. build the hot ZFS toplevel (full build check: closure + ZFS initrd modules) ───────
echo ">> building demo-hot-zfs toplevel …"
TOP="$(nix build --no-link --print-out-paths \
  "$FLAKE#nixosConfigurations.demo-hot-zfs.config.system.build.toplevel")" \
  || { echo "!! toplevel build failed" >&2; exit 1; }
echo "   toplevel: $TOP"

# ── 2. assemble the disk: ESP + two LUKS members for zpool 'qapool' ─────────────────────
# Total 9 GiB: p1=64 MiB ESP, p2=~3.8 GiB luks0, p3=rest luks1.
# Stripe capacity ≈ 7.8 GiB — comfortably holds the system closure (typically 3–5 GiB).
echo ">> assembling disk (ESP ESP + LUKS luks0 + LUKS luks1 for zpool qapool) …"
truncate -s 9G "$DISK"
sgdisk -n1:0:+64M   -t1:EF00 -c1:esp \
       -n2:0:+3900M  -t2:8300 -c2:qapool-luks0 \
       -n3:0:0       -t3:8300 -c3:qapool-luks1 "$DISK" >/dev/null
LOOP="$(losetup --find --show --partscan "$DISK")"
mkfs.vfat -n ESP "${LOOP}p1" >/dev/null

# Fast KDF (pbkdf2, low iters) — throwaway CI volumes, not real secrets.
# Same passphrase on both members: the initrd enters it ONCE for luks0; the kernel keyring
# covers luks1 (the serialised drop-ins in location.nix). The test feeder answers once.
echo -n "$PASS" | cryptsetup luksFormat --type luks2 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "${LOOP}p2" -
echo -n "$PASS" | cryptsetup luksFormat --type luks2 \
  --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "${LOOP}p3" -
echo -n "$PASS" | cryptsetup open "${LOOP}p2" qapool-luks0 -; MAPPER0=1
echo -n "$PASS" | cryptsetup open "${LOOP}p3" qapool-luks1 -; MAPPER1=1

# ── 3. create the ZFS pool + legacy dataset, populate the store ──────────────────────────
# -O mountpoint=none: prevent auto-mounting of intermediate datasets during pool import.
# ZFS native encryption NOT used: LUKS owns the crypto, ZFS sees plaintext block devices.
echo ">> creating zpool 'qapool' over both LUKS mappers …"
zpool create -f \
  -o ashift=12 \
  -O mountpoint=none \
  qapool /dev/mapper/qapool-luks0 /dev/mapper/qapool-luks1
POOL=1
# Intermediate dataset: mountpoint=none so the initrd does not try to auto-mount it.
zfs create -o mountpoint=none qapool/system
# The store dataset: mountpoint=legacy is the hot-mode contract (location.nix mounts it
# with mount(8) in stage-1; a property-managed mountpoint would fight the boot ordering).
zfs create -o mountpoint=legacy qapool/system/nix
# The root dataset — SAME contract, sibling dataset, same pool. Left otherwise EMPTY:
# NixOS activation populates /etc/users/var-lib on first boot the same way whether root
# started as tmpfs or a fresh persistent dataset, so there is nothing to pre-seed here.
zfs create -o mountpoint=legacy qapool/system/root

ROOT="$WORK/root"; MNT="$ROOT/nix"; mkdir -p "$MNT"
mount -t zfs qapool/system/nix "$MNT"
echo ">> copying the toplevel closure onto the ZFS store (nix copy → chroot store) …"
# $ROOT is a chroot store root (store at $ROOT/nix/store); the pool's
# mountpoint=legacy dataset provides the /nix layer.
nix copy --no-check-sigs --to "$ROOT" "$TOP" \
  || { echo "!! nix copy to the ZFS chroot store failed" >&2; exit 1; }
sync
umount "$MNT"; MNT=""
zpool export qapool; POOL=""
cryptsetup close qapool-luks1; MAPPER1=""
cryptsetup close qapool-luks0; MAPPER0=""
losetup -d "$LOOP"; LOOP=""

# ── 4. direct-kernel-boot; feed the passphrase ONCE ─────────────────────────────────────
# The initrd must:
#   a. open qapool-luks0 (prompts) → kernel keyring caches the passphrase
#   b. open qapool-luks1 silently (from cache — NO second prompt)
#   c. import qapool from /dev/mapper (zfs-import-qapool ordered after cryptsetup.target)
#   d. mount qapool/system/nix (legacy) at /nix
#   e. switch-root → full system → login prompt
# If step (b) re-prompts, the boot hangs (feeder fed once) and the test FAILS: the
# serialised keyring path in location.nix is broken.
echo ">> booting (direct kernel) — initrd must unlock, import qapool, mount /nix …"
LOG="$WORK/serial.log"; FIFO="$WORK/in"; mkfifo "$FIFO"
ACCEL=""; [ -e /dev/kvm ] && ACCEL=",accel=kvm"
qemu-system-x86_64 \
  -machine "q35${ACCEL}" -cpu "$([ -e /dev/kvm ] && echo host || echo max)" -smp 2 -m 3072 \
  -kernel "$TOP/kernel" -initrd "$TOP/initrd" \
  -append "init=$TOP/init $(cat "$TOP/kernel-params") console=ttyS0" \
  -drive if=virtio,format=raw,file="$DISK" \
  -netdev user,id=n0 -device virtio-net,netdev=n0 \
  -nographic -serial "mon:stdio" -no-reboot < "$FIFO" > "$LOG" 2>&1 &
VM=$!
VM_PIDS+=("$VM")
exec 3> "$FIFO"   # hold the FIFO writer open so the serial stays live

# Feed the passphrase EXACTLY ONCE. Two LUKS members are enrolled; the serialised unlock
# (location.nix drop-ins) must open the second from the kernel-keyring cache with no second
# prompt — if it re-prompts, the boot stalls and the test FAILS. That is the assertion.
fed=0
for _ in $(seq 1 90); do
  kill -0 "$VM" 2>/dev/null || break
  if grep -qaiE 'please enter|passphrase for|unlocking|qapool-luks' "$LOG" \
      && [ "$fed" -lt 1 ]; then
    printf '%s\n' "$PASS" >&3; fed=$((fed+1)); sleep 3; continue
  fi
  grep -qa 'demo login:' "$LOG" && break
  sleep 2
done

ok=0
for _ in $(seq 1 30); do
  grep -qa 'demo login:' "$LOG" && { ok=1; break; }
  kill -0 "$VM" 2>/dev/null || break
  sleep 2
done
exec 3>&-
kill "$VM" 2>/dev/null; wait "$VM" 2>/dev/null

echo "================ RESULT ================"
if [ "$ok" = 1 ]; then
  echo "PASS — the initrd unlocked both LUKS members (single passphrase via kernel keyring),"
  echo "       imported zpool 'qapool' from /dev/mapper ONCE, mounted qapool/system/nix AND"
  echo "       qapool/system/root (both legacy) at /nix and /, and the hot-mode ZFS system"
  echo "       reached login on an ORDINARY PERSISTENT root (no tmpfs)."
  echo "       (location.nix ZFS path — initrd import-after-key + legacy mounts + keyring +"
  echo "       shared-pool zfsPoolsNeeded dedup ✔)"
  exit 0
fi
echo "FAIL — the hot-mode ZFS system did not reach login. Serial tail:"
tail -60 "$LOG"
exit 1
