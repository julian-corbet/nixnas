# nixnas — STORAGE.md (the f2fs + zstd Nix store on USB)

The deep reference for the on-stick `/nix` store. The high-level layout is in
[`ARCHITECTURE.md`](ARCHITECTURE.md) §2; this document is the engineering detail and the
hard-won f2fs-compression facts. Every claim here is traceable to a primary source (kernel
`Documentation/filesystems/f2fs.rst`, `fs/f2fs/*`, named commits) — see §9.

## 1. Decision

The persistent `/nix` partition is **f2fs with zstd:22 compression, inside LUKS2**, on the
USB stick. Root `/` is tmpfs (impermanence); only `/nix` (store **and** `/nix/var`) and the
FAT ESP persist.

**Goal priority for the stick:** (1) fast boot, (2) flash longevity / minimal writes,
(3) density. f2fs is log-structured (LFS), the right match for write-once-mostly flash —
*not* CoW (btrfs was considered and rejected: CoW metadata churn, and its data-checksum edge
does not outweigh f2fs's flash fit + the boot-speed win below).

**Why compression at all, on a slow stick:** the stick is **< 10 MB/s**. Reading *compressed*
bytes and decompressing on the 16-core 5950X is **faster to boot** than reading uncompressed —
the stick I/O is the bottleneck, decompression is ~free. Compression also writes *fewer*
physical blocks → less flash wear. Both wins are the point; density is a bonus (see §3).

**LUKS sits below f2fs**, so the order is automatically *compress (f2fs) → encrypt (LUKS)* —
correct (encrypting first would make the data incompressible). Encryption costs nothing here:
dm-crypt with AES-NI does GB/s; the < 10 MB/s stick is the bottleneck.

## 2. How f2fs compression actually works here (the load-bearing mechanic)

f2fs `compress_mode=fs` (the default) auto-compresses files at writeback. **But the space it
saves is NOT returned to the free pool by default** — f2fs keeps the *uncompressed* block
count reserved to each file so a later in-place overwrite with incompressible data can't
`ENOSPC`. Consequence: `df`/`du` report the **uncompressed** total ("free-space accounting is
pessimistic") even though the bytes on flash are compressed.

There are therefore **two separable wins**, and only the first is free:

| Win | How | Cost |
|---|---|---|
| **Less wear + faster boot** | mount options only — physical blocks written/read are compressed | none (no extra machinery) |
| **Density** (`df` reflects the real, smaller size → more generations fit) | a **release pass**: `f2fs_io release_cblocks` over `/nix/store` after each build | a little plumbing + the released-file semantics below |

**The release pass does not get in Nix's way.** `F2FS_IOC_RELEASE_COMPRESS_BLOCKS` returns the
reserved-but-unused blocks and sets the f2fs-internal flag **`FI_COMPRESS_RELEASED`** — which,
since **kernel 5.14** (commit `c61404153eb6`), is **decoupled from the VFS immutable bit**. It
blocks **only in-place writes/mmap-writes** to that file. It does **not** block `unlink`,
`link`, `rename`, `read`, or `stat`:

- **Nix GC / path deletion works** — `f2fs_unlink()` has no released-check; deleting a path
  frees its compressed blocks.
- **`nix-store --optimise` (hardlink dedup) works** — `f2fs_link()` has no released-check.
- **Reads/decompress work.**
- A Nix store path is **write-once by construction** (created once, GC'd whole, never rewritten
  in place), so "writes blocked after release" is irrelevant to normal operation.

The one thing you must never do is `nix-store --repair`/re-realise a path **in place** — that
fails `-EIO/-EPERM` on a released file. Repair = **delete + re-substitute** (delete works).

## 3. zstd:22 and the cluster size

**Level is fixed at zstd:22** (operator decision). It is essentially free: f2fs compresses per
**cluster**, and zstd's window is capped by the cluster size, so at the small clusters we use
zstd:22 ≈ zstd:19 in ratio — but it costs nothing extra at read time (decompression speed is
level-independent) and writes are rare, so we simply take the max.

`compress_log_size` sets the cluster: **cluster = 4 KiB × (1 << compress_log_size)**; bounds
**MIN_COMPRESS_LOG_SIZE = 2 (16 KiB)** … **MAX = 8 (1 MiB)** (`fs/f2fs/f2fs.h`; out-of-range is
rejected `-EINVAL`). 2 is also the default. Bigger clusters give a better ratio **but hurt boot
speed**: boot is demand-paged ELF execution (random 4 KiB page faults), and f2fs reads+decompresses
the *whole* cluster per fault (read amplification, linear in cluster size) from the slow stick.

> **DECISION: `compress_log_size=2` (16 KiB).** It is the read-amplification *floor* for the
> boot path (our #1 goal): a 4 KiB exec fault pulls only ~2–3 compressed blocks and inflates
> 16 KiB — cheap, locality-friendly read-ahead that still reads *fewer* physical bytes than
> uncompressed. ELF (the store's bulk) is largely incompressible and each cluster compresses
> independently, so a bigger cluster buys only a modest ratio gain (~single-digit-to-~15 %,
> concentrated on the non-ELF minority) at the cost of multiplying per-fault boot I/O. The real
> multi-generation density comes from **Nix store-path sharing**, not the cluster. Longevity is
> unaffected (immutable whole-file store). Confirmed from `fs/f2fs/{f2fs.h,super.c,compress.c}`:
> the zstd window equals the cluster, so at 16 KiB **zstd:22 ≈ zstd:19** — we keep zstd:22 because
> it is free at read time. `compress_log_size=2` is also the default → the robust, can't-be-wrong
> choice. *(A QEMU boot-time A/B vs an uncompressed control is still worth measuring, but does not
> gate the decision.)*

The cluster size is **fixed per-inode at file creation** — it cannot be changed later for
existing files. Pick it before seeding generation 1.

## 4. The recipe — what makes zstd:22 actually take effect

Every step is make-or-break; skipping one silently disables compression or blocks boot.

1. **mkfs with the compression feature** (without it, the compress mount options are silently
   ignored):
   ```
   cryptsetup luksFormat --type luks2 --sector-size 4096 --pbkdf argon2id <store-part>
   cryptsetup open <store-part> cryptstore
   mkfs.f2fs -f -O extra_attr,compression,sb_checksum,inode_checksum /dev/mapper/cryptstore
   ```

2. **Mount with the trigger** — `compress_algorithm=zstd:22` *alone compresses nothing*;
   `compress_extension=*` is what arms it for all files:
   ```
   compress_algorithm=zstd:22,compress_extension=*,compress_chksum,
   nocompress_extension=sqlite,compress_log_size=2,noatime,lazytime,nodiscard
   ```
   Keep `compress_mode=fs` (default) — do **not** set `compress_mode=user`.

3. **Seed generation 1 THROUGH a compressed mount** — compression is fixed per-inode at file
   creation and cannot be applied retroactively (`chattr +c` fails on non-empty files). So the
   image builder must write the gen-1 closure onto an **already-zstd-mounted** f2fs:
   - Use **`disko`** (mounts the f2fs with the compress options + dm_crypt and writes the
     closure through the mount in a real-kernel VM). `disko.imageBuilder.extraRootModules =
     [ "f2fs" "dm_crypt" ]`.
   - **`image.repart` cannot** do this (no f2fs entry, no LUKS, never populates) and
     **`sload.f2fs` cannot do zstd** (f2fs-tools 1.16.0 `-a` accepts only `lzo`/`lz4`).
   - Verify with `f2fs_io get_cblocks` on a sample of seeded files **before flashing**.

4. **Carve out the Nix state DB** — `nocompress_extension=sqlite` (covers `db.sqlite`,
   `-wal`, `-shm`). The DB is mmap'd + randomly overwritten; compressing it is slow, and if a
   release pass ever touched it the DB would become write-blocked → total Nix breakage. The
   store is mounted at **`/nix`** (not `/nix/store`) so `/nix/var/nix/{db,profiles,gcroots}`
   persist under tmpfs-root — which is exactly why the DB lands here and must be excluded.

5. **initrd must carry f2fs** (the store is mounted in stage-1 after LUKS unlock):
   ```nix
   boot.initrd.supportedFilesystems.f2fs = true;
   boot.initrd.availableKernelModules = [ "f2fs" "crc32" ];
   fileSystems."/nix".fsType = "f2fs";   # explicit — never "auto"
   ```

6. **Density (optional, only if generation count proves tight)** — a post-rebuild systemd unit,
   scoped **strictly** to `/nix/store`:
   ```
   sync
   find /nix/store -xdev -type f -print0 | xargs -0 -r -n1 -P$(nproc) f2fs_io release_cblocks
   ```
   (Tolerate per-file non-zero exits on symlinks/non-regular inodes; idempotent on already-
   released/`nlink>1` inodes.) **Never** let the `find` reach `/nix/var`.

7. **Validate in QEMU before flashing** — run `scripts/verify-f2fs-store.sh` on a loop device,
   then boot the built image in QEMU+OVMF+swtpm and confirm the `/nix` mount with
   `compress_algorithm=zstd:22` succeeds in stage-1.

**On-box op order:** `nixos-rebuild boot` → `nix-store --optimise` → `sync` → release pass →
`nix-collect-garbage`. GC **before** an update to keep headroom.

## 5. Kernel & ZFS

The data pools are ZFS, so the kernel is **whatever the newest OpenZFS-compatible kernel is on
nixos-unstable** — not bleeding-edge mainline. That cap lands us at **≥ 6.12**, which is exactly
the floor f2fs compression needs:

- release-cblocks decoupled from VFS-immutable since **5.14** (so GC works on released files),
- compressed-block SPOR fix ~**6.7**,
- release/reserve `i_blocks` accounting fix ~**6.12**.

So the ZFS cap puts us in the safe zone automatically — **no separate kernel pin is needed for
f2fs** (it is in-tree and comes with the kernel).

**The current combo (early 2026), confirmed against nixpkgs/OpenZFS:**
- `boot.kernelPackages` default = `pkgs.linuxPackages` = `linux_default` = **linux 6.18** today
  (cache-hot). `linux_latest` (7.1) is excluded — its ZFS module is marked broken.
- `boot.zfs.package` default = `pkgs.zfs` (**stable** OpenZFS, not `zfs_unstable`). OpenZFS
  2.3/2.4 + unstable all declare `kernelMaxSupportedMajorMinor = "7.0"` → landing band **6.18 … ≤ 7.0**.
- **`boot.zfs.package.latestCompatibleLinuxPackages` is DEPRECATED** (now just aliases the default
  kernel + warns) — do **not** use it.

> **DECISION: pin the stock cached default** — `boot.kernelPackages = pkgs.linuxPackages`,
> `boot.zfs.package = pkgs.zfs`. The "newest-ZFS-compatible filter" idiom (NixOS wiki) can select
> a kernel that is **not** in `cache.nixos.org`, forcing a from-source kernel build **on the slow
> stick** — a direct hit to goal #1. The stock default is recent (6.18), ZFS-compatible, and
> pre-built. Only escalate if a newer kernel is genuinely required.

**f2fs is in-tree** (`F2FS_FS = module`, `F2FS_FS_COMPRESSION = yes`; `F2FS_FS_ZSTD` is `default y`
under compression → baked into `f2fs.ko`). Assert it at build time *without* a kernel rebuild
(forcing the config busts the cache → slow-stick kernel compile):
```nix
assertions = [{
  assertion = config.boot.kernelPackages.kernel.config.isEnabled "F2FS_FS_ZSTD";
  message = "nixnas requires F2FS_FS_ZSTD=y (the /nix store is f2fs zstd:22).";
}];
```

**Coexistence:** f2fs goes in the **initrd** (`boot.initrd.kernelModules = [ "f2fs" ]`,
`boot.initrd.systemd.enable`); the operator's **ZFS pools stay out of stage 1** (imported in
stage 2, never `neededForBoot`) — keeping the initrd small (faster boot) and the out-of-tree ZFS
module off the critical boot path. ZFS sets the kernel's *upper* bound, f2fs the *lower* feature
bound; the default 6.18 sits comfortably between.

## 6. Footguns & guards

| # | Footgun | Guard |
|---|---|---|
| 1 | fs-mode frees **no** space without a release pass → store hits ENOSPC at the **uncompressed** total | accept it (boot+wear still won) **or** run the `/nix/store`-scoped release pass for density |
| 2 | gen-1 seeded **uncompressed** (can't be fixed later) | seed through a zstd mount via **disko**; never `image.repart`/`sload`; verify `get_cblocks` pre-flash |
| 3 | Nix DB on the compressed FS → slow + release-could-write-block it | `nocompress_extension=sqlite`; release `find` scoped to `/nix/store`, never `/nix/var` |
| 4 | unbootable on bad mount/module config | explicit `fsType="f2fs"`, `-O extra_attr,compression`, initrd `f2fs`+`crc32`, assert `F2FS_FS_ZSTD=y`, QEMU-validate |
| 5 | transient ENOSPC during on-box autoUpgrade on the tiny LFS | GC before update, keep headroom, keep default overprovisioning, prefer building **off-box** + `nix copy` finished closures |
| 6 | GC broken on pre-5.14 kernel (released = immutable) | assert kernel ≥ 6.12; never GC/optimise the released store from a pre-5.14 rescue kernel |
| 7 | in-place repair of a released path fails `-EIO` | repair = delete + re-substitute, never `--repair` in place |
| 8 | no data integrity on incompressible blobs (compress_chksum covers only compressed clusters; LUKS-XTS adds none) | rely on Nix re-substitution by hash; optional future dm-integrity below LUKS |

## 7. Integrity posture

`compress_chksum` + `sb_checksum` + `inode_checksum` catch corruption in compressed clusters and
metadata. LUKS-XTS gives **confidentiality, not integrity**. Already-compressed blobs inside
closures stay unguarded against bit-rot — acceptable because Nix can re-substitute any path by
hash. Cryptographic userspace integrity is the deferred **dm-integrity-below-LUKS** hybrid (see
`ARCHITECTURE.md` §6).

## 8. Verification

`scripts/verify-f2fs-store.sh` runs the loop-device probes (default reclaim, release reclaims,
released-is-write-blocked-but-deletable, hardlink-to-released, release idempotency, sload-can't-
zstd, fsck-clean). Two probes are target-only (real Nix-store GC; built-image initrd carries
f2fs-zstd) and run during QEMU boot-testing. The CachyOS laptop kernel ships **no f2fs module**,
so all f2fs verification happens on the cluster / in QEMU, never on the laptop.

## 9. Sources

- `Documentation/filesystems/f2fs.rst` — Compression section (no auto-reclaim; mount options).
- `fs/f2fs/file.c` `f2fs_release_compress_blocks()`; `fs/f2fs/namei.c` `f2fs_unlink`/`f2fs_link`.
- Linux commit `c61404153eb6` (Jaegeuk Kim, v5.14) — release decoupled from S_IMMUTABLE.
- f2fs-tools 1.16.0 `sload.f2fs`/`mkfs.f2fs` man pages (no zstd in sload).
