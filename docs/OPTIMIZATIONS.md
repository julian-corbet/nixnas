# nixnas — OPTIMIZATIONS.md

Kernel/boot/software tuning for the thin nixnas appliance layer. Two priorities, in order:
**(1) fast boot**, **(2) stick longevity** (minimise writes to the only two persistent
filesystems — `/nix` f2fs-in-LUKS and the FAT ESP). Storage/compression specifics are in
[`STORAGE.md`](STORAGE.md); the boot/crypto model is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

**Scope marker:** ⬢ = nixnas sets it as an appliance default; ◯ = operator policy nixnas merely
enables/recommends (cache choice, GC retention). Out-of-scope items are listed at the end.

**Framing:** root is tmpfs, so `/var`, `/var/log`, `/tmp`, coredumps and machine state are
*already in RAM*. "Longevity" therefore reduces to: minimise writes to `/nix` + the ESP, and
never let an impermanence misconfig silently start persisting onto them.

## 1. Kill avoidable stick writes (longevity)

- ⬢ `services.journald.storage = "volatile";` — logs to `/run` (RAM); never create
  `/var/log/journal`. (Belt-and-suspenders under tmpfs root; initrd-phase journald ignores it —
  nixpkgs#244892.)
- ⬢ `systemd.coredump.extraConfig = [ "Storage=none" ];` — don't spool coredumps (a sporadic
  large-write path).
- ⬢ `fileSystems."/nix".options` include `noatime,lazytime`; `fileSystems."/boot".options`
  include `noatime`. `noatime` kills read-triggered writes; `lazytime` coalesces timestamp
  writes into existing writebacks (VFS-level; applies to f2fs + vfat).
- ⬢ `swapDevices = [ ];` — **no on-stick swap** (a swapfile on `/nix` is the worst possible
  write-amplifier); use zram (§5).
- ⬢ `boot.tmp.useTmpfs = true;` — `/tmp` in RAM; build/activation scratch never touches flash.
- ⬢ `documentation.enable = false; documentation.nixos.enable = false;` — smaller closures →
  fewer bytes written per upgrade (longevity + density).
- ◯ `nix.gc.automatic = true; nix.gc.options = "--delete-older-than 14d";` +
  `nix.settings.min-free`/`max-free` — bound store size and auto-trim *during* autoUpgrade so a
  near-full 8 GB stick can't wedge the upgrade. Retention is operator policy.
- ⬢ **Avoid inline `nix.settings.auto-optimise-store`** — the hardlink-dedup pass adds write
  churn on every store mutation; run `nix-store --optimise` deliberately (post-build, before the
  optional release pass), not on every build.

## 2. Faster boot

- ⬢ `boot.initrd.systemd.enable = true;` — parallel, dependency-ordered initrd; also the
  supported path for TPM2-LUKS unlock + lanzaboote.
- ⬢ `boot.kernelParams = [ "quiet" "loglevel=3" "udev.log_level=3" "rd.udev.log_level=3" ];`
  `boot.consoleLogLevel = 3;` — kill console/serial log I/O (slow on a VT, dominates on serial).
- ⬢ Slim UKI: `boot.initrd.includeDefaultModules = false;` + an explicit
  `boot.initrd.availableKernelModules` (USB/crypto/f2fs only). On a **< 10 MB/s** stick a smaller
  initrd is read faster — read time dominates, not CPU.
- ⬢ `boot.initrd.compressor = "zstd"; boot.initrd.compressorArgs = [ "-19" ];` — on slow flash
  the smaller read beats the (tiny) decompress cost.
- ⬢ `boot.kernelParams += [ "fsck.mode=skip" ];` — skip routine fsck. f2fs does roll-forward
  recovery from its checkpoint and the Nix store is reproducible/re-fetchable, so a heavy
  `fsck.f2fs` over a large store is wasted boot time. (Trade-off: no auto-repair — acceptable
  because the store is disposable; pairs with the "rely on Nix signatures" integrity model.)
- ⬢ `systemd.network.wait-online.enable = false;` — `wait-online` is a notorious multi-second
  boot stall; a NAS must not block boot on link-up.
- ⬢ `boot.loader.timeout` — `0`/`1`. Keep **`1`** so the lanzaboote generation menu is reachable
  for manual rollback.

## 3. f2fs mount tuning (the non-compression options)

Set on `fileSystems."/nix".options` alongside the fixed `compress_algorithm=zstd:22,…`
(see STORAGE.md §4). Verified against `Documentation/filesystems/f2fs.rst`:

- ⬢ `lazytime` — defer timestamp writes (also §1).
- ⬢ `nodiscard` — disable inline discard/TRIM (USB rarely does TRIM well; it stalls the slow bus).
- ⬢ `flush_merge` — merge concurrent cache-flush commands → fewer flushes to slow flash.
- ⬢ `checkpoint_merge` — kernel daemon merges checkpoint requests → smoother write bursts.
- ⬢ `compress_cache` — cache compressed blocks in RAM → better random-read hit ratio on the
  zstd:22 store (helps activation/boot read paths).
- ⬢ `fsync_mode=nobarrier` — fewer barriers for non-atomic files; safe-ish because store paths are
  re-fetchable. **Do NOT use the bare `nobarrier` mount option** — that assumes the device
  guarantees a cache flush, which a USB stick does **not**. The `fsync_mode=` form is the narrow,
  correct one.
- ⬢ **Do NOT set `data_flush`** — it flushes data before checkpoint → strictly *more* writes.
- ◯ `mode=lfs` (default `adaptive`) — pure-sequential suits a write-once store on sequential flash
  but raises GC pressure; **benchmark on the real stick** before adopting. Leave `adaptive` unless
  measured.
- GC knobs (`atgc`, `gc_merge`, `background_gc`): store is read-mostly → defaults are fine, don't
  over-tune.

## 4. Boot integrity & lanzaboote / UKI hygiene

- ⬢ `boot.lanzaboote.enable = true;` + `boot.loader.systemd-boot.enable = lib.mkForce false;` —
  signed UKIs for Secure Boot.
- ⬢ **`boot.lanzaboote.pkiBundle` must live on persistent storage, not tmpfs root** — else the SB
  signing keys vanish each boot. Bind from a `/nix`-persisted path (impermanence).
- ⬢ **Persist boot identity** that tmpfs would wipe: `/etc/machine-id`, SSH host keys, the sbctl
  PKI, TPM2 enrollment metadata. If these regenerate each boot, machine-id / measured-boot / TPM2
  PCR sealing drift and unlock breaks. (The LUKS header is on-disk already.)
- ⬢ `boot.lanzaboote.configurationLimit = 5;` (+ `nix.gc`) — each generation is a signed UKI on
  the tiny FAT ESP; bounding the count caps ESP writes/space (the ESP is the tighter bound on
  generation count — see ARCHITECTURE.md §2).
- ◯ `nix.settings.require-sigs = true;` + trust only the hub's cache key → `nix store verify`
  covers store integrity. f2fs has no default data checksums; rely on Nix signatures +
  reproducibility rather than fs-level data checksums (this is also what justifies `fsck.mode=skip`).

## 5. zram / build placement — surviving on-box autoUpgrade on a tiny store

- ◯ **Biggest lever — never build on the box:** `nix.settings.substituters = [ "<hub cache>" ];`
  so `system.autoUpgrade` *downloads* prebuilt, signed closures (the "build on hub, never on node"
  doctrine). Then the only `/nix` writes are the new closure itself — no build intermediates
  hammering the slow flash, and no transient-ENOSPC mid-build (STORAGE.md §6 footgun 5).
- ⬢ `zramSwap.enable = true; zramSwap.algorithm = "zstd"; zramSwap.memoryPercent = 50;` —
  compressed RAM swap absorbs memory pressure during activation with zero flash writes.
- ⬢ `boot.tmp.useTmpfs = true;` (from §1); if any local build ever runs, keep its `TMPDIR` in RAM.

## Out of scope (operator territory — flag, don't tune here)

- ZFS ARC sizing (`zfs_arc_max`), `recordsize`, dataset `compression`/`atime` on the **data
  pools** — operator's plain-NixOS config. (Per fleet doctrine: never fence RAM away from ARC.)
- k3s, GPU drivers, Samba/NFS share tuning, libvirt/VMs — operator.
- Kernel **version** is a *constraint* (newest cached OpenZFS-compatible), not a tunable — don't
  chase mainline/bleeding-edge (STORAGE.md §5).
- `fstrim`/discard on the **data disks** — operator.
