# nixnas — the f2fs compression "release pass" (STORAGE.md §4/§2).
#
# f2fs's fs-mode compression (modules/lib/f2fs-store-mount-opts.nix) shrinks what's WRITTEN
# to flash, but by kernel design it does NOT free the reserved blocks back to free space —
# that needs an explicit per-file ioctl(F2FS_IOC_RELEASE_COMPRESS_BLOCKS), exposed as
# `f2fs_io release_cblocks <file>`. Skipping this defeats the entire point of compressing the
# store: writes shrink, but `df` (and the store's actual capacity) never do. Confirmed live on
# a real deployment 2026-07-04: a flashed, already-installed store released ~824 MiB (55%→40%
# used) the first time this pass ran — nothing had ever reclaimed it before.
#
# Released files become WRITE-BLOCKED (EIO/EPERM) until truncated or explicitly re-reserved —
# a non-issue for the Nix store, whose paths are immutable by construction; this is exactly
# the behavior scripts/verify-f2fs-store.sh proves safe (hardlink-to-released, unlink-and-GC,
# fsck-clean).
#
# ONE script, THREE call sites — because release only happens where NEW files land on an
# f2fs-backed nix store, and none of those sites overlap:
#   1. Image build (modules/boot/disk.nix, an activationScript): covers gen-1, written once
#      by the disko installer inside the builder VM.
#   2. rescue-maintain (modules/appliance/rescue-maintain.nix): its `nix copy --to $mnt`
#      writes into a MOUNTED-ELSEWHERE store from the MAIN's own daemon — a foreign-store
#      write that no local nix-daemon hook ever sees.
#   3. Ongoing local rebuilds (modules/appliance/optimizations.nix, nix.extraOptions
#      post-build-hook): auto-upgrade's `system.autoUpgrade` runs as a LOCAL build on the
#      box's own daemon, so Nix's post-build-hook fires per new path automatically — no
#      explicit call needed there, just this registration.
# The hot-mode MAIN is explicitly OUT of scope: its /nix lives on the operator's own pool
# (ZFS or whatever they use), never f2fs, so this pass is meaningless there.
{ pkgs }:
pkgs.writeShellApplication {
  name = "nixnas-f2fs-release-cblocks";
  runtimeInputs = [ pkgs.f2fs-tools pkgs.findutils ];
  text = ''
    # One or more roots to sweep: "/nix/store" for a full local pass (disk.nix's install-time
    # hook), a mounted-elsewhere chroot store root's "$mnt/nix/store" (rescue-maintain), or the
    # individual $OUT_PATHS Nix's post-build-hook hands us (word-split by the caller — the
    # common ongoing case, one path per newly-built derivation output, no full-store rescan).
    if [ "$#" -eq 0 ]; then
      echo "usage: nixnas-f2fs-release-cblocks <store-root>..." >&2
      exit 1
    fi
    for root in "$@"; do
      [ -d "$root" ] || { echo "nixnas-f2fs-release-cblocks: $root does not exist — skipping" >&2; continue; }
      # Not every path is f2fs (a hot-mode MAIN never reaches this, but stay defensive: never
      # touch a filesystem that isn't f2fs, or the ioctl is a meaningless no-op at best).
      fstype=$(stat -f -c %T "$root" 2>/dev/null || echo unknown)
      if [ "$fstype" != "f2fs" ]; then
        echo "nixnas-f2fs-release-cblocks: $root is not f2fs ($fstype) — skipping" >&2
        continue
      fi
      total=0; released=0
      while IFS= read -r -d "" f; do
        total=$((total + 1))
        # Non-compressed files (excluded extensions, too-small clusters, symlinks already
        # filtered by -type f) harmlessly fail this ioctl — count, don't treat as an error.
        f2fs_io release_cblocks "$f" >/dev/null 2>&1 && released=$((released + 1))
      done < <(find "$root" -xdev -type f -print0)
      echo "nixnas-f2fs-release-cblocks: $root — $released/$total files released"
    done
  '';
}
