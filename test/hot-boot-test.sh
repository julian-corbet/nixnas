#!/usr/bin/env bash
# test/hot-boot-test.sh — prove the HOT-mode boot path (modules/store/location.nix).
#
# THE CLAIM UNDER TEST: a nixnas MAIN boots BOTH its /nix and its / (root) from EXTERNAL,
# operator-key-unlocked LUKS devices — the initrd opens both with the OPERATOR'S passphrase
# (interactive, no TPM/auto), mounts them as /nix and /, and switch-roots into the full
# system on an ORDINARY PERSISTENT root (no tmpfs anywhere in hot mode — the whole point of
# this refactor: docs/ARCHITECTURE.md §3.2).
#
# It DIRECT-KERNEL-BOOTS the demo-hot toplevel (-kernel/-initrd) rather than going through the
# ESP/UKI/Secure-Boot chain — that chain is already proven by the usb boot-test (test/
# seal-2boot-test.sh), and the rescue is itself a usb nixnas. What is NEW in hot mode, and all
# this file tests, is the initrd unlock-external-devices + mount-/nix-and-/ step.
#
# The disk carries THREE LUKS members: `nixstore-demo` (ext4, pre-populated with the toplevel
# closure via `nix copy` to a chroot store), `nixstore-demo2` (no filesystem — proves the serialised
# single-entry unlock), and `nixroot-demo` (ext4, matching hosts/demo-hot.nix's
# store.root.unlock) — freshly `mkfs.ext4`'d and otherwise EMPTY: NixOS activation populates
# /etc, users, and every service's /var/lib on first boot exactly the same way whether root is
# tmpfs or a fresh persistent filesystem, so an empty partition is the correct fixture, not a
# gap. At the initrd's LUKS prompt we feed the passphrase over serial ONCE; PASS == the box
# reaches `demo login:` (all three members opened from that single entry, /nix and / both
# mounted from their own external device).
#
# SECOND BOOT — VIDEO-primary console coverage (closes the console-flip open risk):
# the same system is rebuilt via extendModules with nixnas.boot.consolePrimary FORCED to
# "video" (tty0 last = /dev/console; the option's default for real operators — the CI
# hosts pin "serial"). The video build must (a) reach the same serial `demo login:` gate
# as the serial build, and (b) still print the LUKS passphrase prompt ON THE SERIAL LOG —
# systemd's password agent asks on every console in /sys/class/tty/console/active, which
# is exactly what keeps IPMI/SOL users alive under the video default (the reorder-never-
# drop invariant of modules/boot/image.nix, proven here at runtime, not just by eval).
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
LOOP=""; MAPPER=""; MAPPER_ROOT=""; MNT=""
cleanup() {
  [ -n "$MNT" ] && umount "$MNT" 2>/dev/null
  [ -n "$MAPPER_ROOT" ] && cryptsetup close nixroot-demo 2>/dev/null
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

# ── 1b. build the VIDEO-primary variant of the SAME system (extendModules) ──────────
# nixnas.boot.consolePrimary is FORCED to "video" (mkForce: hosts/demo pins "serial"
# for the serial-observed CI rigs). Nearly free: the closure is shared, only the
# toplevel + kernel-params differ. $FLAKE may be a path (resolve to absolute for
# builtins.getFlake) or already a proper flake ref.
echo ">> building demo-hot VIDEO-primary variant (consolePrimary forced to \"video\") …"
FLAKE_URI="$FLAKE"
[ -e "$FLAKE" ] && FLAKE_URI="$(readlink -f "$FLAKE")"
TOP_VIDEO="$(nix build --no-link --print-out-paths --impure --expr "
  ((builtins.getFlake \"${FLAKE_URI}\").nixosConfigurations.demo-hot.extendModules {
    modules = [ ({ lib, ... }: { nixnas.boot.consolePrimary = lib.mkForce \"video\"; }) ];
  }).config.system.build.toplevel")" \
  || { echo "!! video-variant toplevel build failed" >&2; exit 1; }
echo "   video toplevel: $TOP_VIDEO"

# Structural pre-flight on both kernel command lines (fail fast, before any QEMU):
#   serial build: console=ttyS0,115200 LAST (serial is /dev/console),
#   video  build: console=tty0 LAST (display is /dev/console),
#   and console=ttyS0 must be PRESENT in the video build — reorder, never drop.
last_console() { grep -o 'console=[^ ]*' "$1/kernel-params" | tail -1; }
[ "$(last_console "$TOP")" = "console=ttyS0,115200" ] \
  || { echo "!! serial build: expected console=ttyS0,115200 last, got '$(last_console "$TOP")'" >&2; exit 1; }
[ "$(last_console "$TOP_VIDEO")" = "console=tty0" ] \
  || { echo "!! video build: expected console=tty0 last, got '$(last_console "$TOP_VIDEO")'" >&2; exit 1; }
grep -q 'console=ttyS0,115200' "$TOP_VIDEO/kernel-params" \
  || { echo "!! video build DROPPED console=ttyS0 — SOL/serial users would lose the LUKS prompt" >&2; exit 1; }
echo "   console ordering verified: serial=[…,ttyS0] video=[…,tty0] (ttyS0 kept). ✔"

# ── 2. assemble the disk: a labelled ESP + LUKS+ext4 /nix + LUKS+ext4 / (root) + a 2nd
#      bare LUKS member (single-entry-unlock proof) ──────────────────────────────────────
# demo-hot mounts /boot by-label ESP (it shares the stick ESP in reality); without it
# the boot drops to emergency mode. This is direct-kernel-boot, so the ESP need only exist +
# carry the label — no bootloader is installed on it. `nixroot-demo` matches
# hosts/demo-hot.nix's store.root.unlock: hot mode has NO tmpfs root (docs/ARCHITECTURE.md
# §3.2), so a real device backs "/" here too, exactly like /nix.
echo ">> assembling the disk (ESP ESP + LUKS+ext4 /nix + LUKS+ext4 / + a bare LUKS member) …"
truncate -s 7G "$DISK"
sgdisk -n1:0:+64M -t1:EF00 -c1:esp \
       -n2:0:+5G  -t2:8300 -c2:nixstore-demo \
       -n3:0:+512M -t3:8300 -c3:nixstore-demo2 \
       -n4:0:0    -t4:8300 -c4:nixroot-demo "$DISK" >/dev/null
LOOP="$(losetup --find --show --partscan "$DISK")"
mkfs.vfat -n ESP "${LOOP}p1" >/dev/null
part="${LOOP}p2"
rootpart="${LOOP}p4"
[ -b "$part" ] || { echo "!! loop partition $part not present" >&2; exit 1; }
[ -b "$rootpart" ] || { echo "!! loop partition $rootpart not present" >&2; exit 1; }
# Fast KDF (pbkdf2, low iters) — this is a throwaway CI volume, not a real secret.
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "$part" -
# The 2nd member (same passphrase, NO filesystem): it exists to prove the SERIALISED
# single-entry unlock — the initrd must open it from the kernel-keyring cache without a
# second prompt (the feeder below deliberately answers only ONCE).
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "${LOOP}p3" -
# The root device: same passphrase, ext4, freshly formatted and left EMPTY — NixOS
# activation populates /etc/users/var-lib on first boot the same way whether root started
# as tmpfs or a fresh persistent filesystem, so there is nothing to pre-seed here.
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode "$rootpart" -
echo -n "$PASS" | cryptsetup open "$rootpart" nixroot-demo -; MAPPER_ROOT=1
mkfs.ext4 -q -L nixroot /dev/mapper/nixroot-demo
cryptsetup close nixroot-demo; MAPPER_ROOT=""
echo -n "$PASS" | cryptsetup open "$part" nixstore-demo -; MAPPER=1
mkfs.ext4 -q -L nixstore /dev/mapper/nixstore-demo
# Mount at $ROOT/nix so $ROOT is a chroot-store root (store at $ROOT/nix/store).
ROOT="$WORK/root"; MNT="$ROOT/nix"; mkdir -p "$MNT"
mount /dev/mapper/nixstore-demo "$MNT"
echo ">> copying BOTH toplevel closures onto the ext4 store (nix copy → chroot store) …"
# Both boots share one disk: the video toplevel's delta over the serial one is tiny
# (toplevel dir + kernel-params — kernel/initrd/store contents are identical).
nix copy --no-check-sigs --to "$ROOT" "$TOP" "$TOP_VIDEO" \
  || { echo "!! nix copy to the chroot store failed" >&2; exit 1; }
sync
umount "$MNT"; MNT=""
cryptsetup close nixstore-demo; MAPPER=""
losetup -d "$LOOP"; LOOP=""

# ── 3. BOOT #1 (serial-primary): feed the passphrase to the initrd LUKS prompt over serial ──
# NOTE: allUnlockNames sorts alphabetically (modules/store/location.nix), so with
# {nixroot-demo, nixstore-demo, nixstore-demo2} the FIRST member the initrd actually prompts
# for is nixroot-demo (root), not the store — the assertion under test doesn't care which
# specific member prompts first, only that ONE entry opens the whole chain.
echo ">> BOOT #1 (serial-primary): the initrd must unlock the whole chain with ONE operator key …"
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

# Feed the passphrase EXACTLY ONCE. THREE LUKS members are enrolled (nixroot-demo,
# nixstore-demo, nixstore-demo2); the serialised unlock (location.nix drop-ins) must open
# the other two from the kernel-keyring cache with no second/third prompt — if it
# re-prompts, the boot hangs and the test FAILS. That is the assertion.
fed=0
for _ in $(seq 1 60); do
  kill -0 "$VM" 2>/dev/null || break
  if grep -qaiE 'please enter|passphrase for|unlocking|nixroot-demo|nixstore-demo' "$LOG" && [ "$fed" -lt 1 ]; then
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

if [ "$ok" != 1 ]; then
  echo "================ RESULT ================"
  echo "FAIL — the hot-mode system (serial-primary) did not reach login. Serial tail:"
  tail -50 "$LOG"
  exit 1
fi
echo ">> BOOT #1 (serial-primary) reached login. ✔"

# ── 4. BOOT #2 (VIDEO-primary): same disk, same serial gates, tty0 is /dev/console ──
# The video build keeps console=ttyS0,115200 on the cmdline (verified above), so the
# serial port must still carry: the kernel log, the LUKS passphrase prompt (systemd's
# password agent asks on EVERY console in /sys/class/tty/console/active — this boot is
# the runtime proof that SOL/serial users survive the video default), and a getty.
# Differences vs boot #1:
#   * NO extra `console=ttyS0` is appended — that would put ttyS0 last again and undo
#     the very console order under test; the build's own kernel-params are authoritative.
#   * snapshot=on — boot #1's writes are irrelevant here, and the ext4 journal replay
#     after boot #1's hard kill lands in the throwaway overlay (the disk stays pristine).
echo ">> BOOT #2 (VIDEO-primary): serial must still show the LUKS prompt and reach login …"
LOG_V="$WORK/serial-video.log"; FIFO_V="$WORK/in-video"; mkfifo "$FIFO_V"
qemu-system-x86_64 \
  -machine "q35${ACCEL}" -cpu "$([ -e /dev/kvm ] && echo host || echo max)" -smp 2 -m 2048 \
  -kernel "$TOP_VIDEO/kernel" -initrd "$TOP_VIDEO/initrd" \
  -append "init=$TOP_VIDEO/init $(cat "$TOP_VIDEO/kernel-params")" \
  -drive if=virtio,format=raw,snapshot=on,file="$DISK" \
  -netdev user,id=n0 -device virtio-net,netdev=n0 \
  -nographic -serial "mon:stdio" -no-reboot < "$FIFO_V" > "$LOG_V" 2>&1 &
VMV=$!
exec 3> "$FIFO_V"

# Feed once, but trigger ONLY on the password agent's actual ask line ('please enter' /
# 'passphrase for') — with tty0 primary, systemd's status stream stays off the serial,
# and looser matches (unit names in the kernel log) could fire before an agent listens.
fedv=0
for _ in $(seq 1 60); do
  kill -0 "$VMV" 2>/dev/null || break
  if grep -qaiE 'please enter|passphrase for' "$LOG_V" && [ "$fedv" -lt 1 ]; then
    printf '%s\n' "$PASS" >&3; fedv=$((fedv+1)); sleep 3; continue
  fi
  grep -qa 'demo login:' "$LOG_V" && break
  sleep 2
done

okv=0
for _ in $(seq 1 20); do
  grep -qa 'demo login:' "$LOG_V" && { okv=1; break; }
  kill -0 "$VMV" 2>/dev/null || break
  sleep 2
done
exec 3>&-
kill "$VMV" 2>/dev/null; wait "$VMV" 2>/dev/null

# Assertion (b): the LUKS prompt line must be IN the serial log of the video build.
LUKS_PROMPT_LINE="$(grep -aiE 'please enter|passphrase for' "$LOG_V" | head -1)"

echo "================ RESULT ================"
if [ "$okv" = 1 ] && [ -n "$LUKS_PROMPT_LINE" ]; then
  echo "PASS — serial-primary boot: initrd unlocked the EXTERNAL LUKS devices with ONE"
  echo "       operator passphrase, mounted them as /nix AND / (no tmpfs anywhere), reached"
  echo "       login. (location.nix ✔ — persistent-root boot path)"
  echo "     — VIDEO-primary boot (consolePrimary=\"video\" forced via extendModules):"
  echo "       reached the SAME serial login gate, and the LUKS prompt appeared on the"
  echo "       serial log — SOL/serial users survive the video default. ✔"
  echo "       prompt line: ${LUKS_PROMPT_LINE}"
  exit 0
fi
if [ "$okv" = 1 ]; then
  echo "FAIL — VIDEO-primary boot reached login but NO LUKS prompt line appeared on the"
  echo "       serial log (the password agent did not fan out to ttyS0 — SOL users would"
  echo "       be locked out under the video default). Serial extract:"
  grep -aiE 'passphrase|cryptsetup|ask-password|nixstore' "$LOG_V" | head -20
  exit 1
fi
echo "FAIL — the VIDEO-primary boot did not reach login (serial-primary boot passed)."
echo "       LUKS prompt on serial: ${LUKS_PROMPT_LINE:-<never appeared>}"
echo "       Serial tail:"
tail -50 "$LOG_V"
exit 1
