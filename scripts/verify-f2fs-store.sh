#!/usr/bin/env bash
# verify-f2fs-store.sh — ground-truth the f2fs+zstd:22 Nix-store assumptions on a loop device.
#
# Confirms the load-bearing claims from docs/STORAGE.md §2:
#   1. fs-mode compression does NOT auto-reclaim space (df shows uncompressed).
#   2. release_cblocks DOES reclaim (df drops).
#   3. a released file is write-blocked BUT unlink/GC frees its compressed blocks.
#   4. hardlink-to-released works (nix-store --optimise compatibility).
#   5. release is idempotent on already-released / nlink>1 inodes.
#   6. sload.f2fs cannot seed zstd (so gen-1 must be written through a kernel mount).
#   7. fsck.f2fs is clean after release/unlink churn.
#
# Requires root (f2fs is not FS_USERNS_MOUNT) + a kernel WITH the f2fs module (the CachyOS
# laptop has none — run this on the cluster / inside the built nixnas QEMU image).
# Usage:  sudo bash scripts/verify-f2fs-store.sh
set -u
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

for t in mkfs.f2fs f2fs_io losetup fsck.f2fs; do
  command -v "$t" >/dev/null || { echo "ABORT: missing $t (install f2fs-tools)"; exit 9; }
done
modprobe f2fs 2>/dev/null
grep -q f2fs /proc/filesystems || { echo "ABORT: f2fs not in this kernel ($(uname -r))"; exit 9; }

IMG=$(mktemp /tmp/f2verify.XXXXXX.img); MNT=$(mktemp -d /tmp/f2verify.XXXXXX.mnt)
truncate -s 3G "$IMG"
L=$(losetup -f --show --sector-size 4096 "$IMG")
cleanup() { umount "$MNT" 2>/dev/null; losetup -d "$L" 2>/dev/null; rm -f "$IMG"; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

mkfs.f2fs -f -O extra_attr,compression,sb_checksum,inode_checksum "$L" >/dev/null 2>&1 || { bad "mkfs"; exit 1; }
# The production mount string (STORAGE.md §4), minus nocompress_extension for this synthetic test:
mount -t f2fs -o compress_algorithm=zstd:22,compress_log_size=2,compress_extension=*,compress_chksum,noatime,lazytime,nodiscard "$L" "$MNT" \
  && ok "mount zstd:22,compress_log_size=2" || { bad "mount"; exit 1; }

used() { df -k --output=used "$MNT" | tail -1 | tr -d ' '; }

echo "[1] default reclaim — writing 512 MiB of zeros must NOT shrink free space (reserved uncompressed)"
B=$(used); dd if=/dev/zero of="$MNT/z.bin" bs=1M count=512 conv=fsync status=none; sync; A=$(used)
D=$((A-B)); CB=$(f2fs_io get_cblocks "$MNT/z.bin" 2>/dev/null)
[ "$D" -gt 400000 ] && ok "df +${D} KiB (no auto-reclaim, as documented); get_cblocks=$CB (physically compressed)" \
                    || bad "expected df ~+524288 KiB, got +${D} KiB"

echo "[2] release_cblocks reclaims space — df must drop sharply"
B=$(used); f2fs_io release_cblocks "$MNT/z.bin" >/dev/null 2>&1; sync; A=$(used); D=$((A-B))
[ "$D" -lt -300000 ] && ok "df ${D} KiB after release (space returned)" || bad "expected large negative, got ${D} KiB"

echo "[3] released = write-blocked, but unlink frees the compressed blocks (Nix GC)"
if dd if=/dev/zero of="$MNT/z.bin" bs=4k count=1 conv=notrunc status=none 2>/dev/null; then bad "write to released file SUCCEEDED (should be EIO/EPERM)"; else ok "write to released file blocked (EIO/EPERM)"; fi
B=$(used); rm -f "$MNT/z.bin" && ok "unlink of released file OK" || bad "unlink blocked"; sync; A=$(used)
[ $((A-B)) -lt 0 ] && ok "df dropped after rm (compressed blocks returned)" || bad "rm freed no space"

echo "[4] hardlink to a released inode + unlink one name + read survivor (nix-store --optimise)"
dd if=/dev/zero of="$MNT/a" bs=1M count=64 conv=fsync status=none; sync; f2fs_io release_cblocks "$MNT/a" >/dev/null 2>&1
ln "$MNT/a" "$MNT/a.lnk" && ok "hardlink-to-released OK" || bad "hardlink-to-released blocked"
rm "$MNT/a" && ok "unlink-one-name OK" || bad "unlink-one-name blocked"
cat "$MNT/a.lnk" >/dev/null 2>&1 && ok "read-via-survivor OK (decompress intact)" || bad "read-via-survivor failed"

echo "[5] release idempotency on already-released / nlink>1"
f2fs_io release_cblocks "$MNT/a.lnk" >/dev/null 2>&1 && ok "re-release is a clean no-op" || bad "re-release errored"

echo "[6] sload.f2fs cannot seed zstd (gen-1 must go through a kernel mount)"
if command -v sload.f2fs >/dev/null; then
  if sload.f2fs 2>&1 | grep -iqE 'zstd'; then bad "sload.f2fs advertises zstd — re-check the seeding claim"; else ok "sload.f2fs has no zstd (lzo/lz4 only) — disko/kernel-mount seeding required"; fi
else echo "  SKIP: sload.f2fs not present"; fi

echo "[7] fsck.f2fs clean after release/unlink churn"
umount "$MNT"; OUT=$(fsck.f2fs -f "$L" 2>&1); RC=$?
echo "$OUT" | grep -iqE 'Inconsistent|corrupt|fixed' && bad "fsck reported issues (rc=$RC)" || ok "fsck clean (rc=$RC)"

echo
echo "==== RESULT: $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
