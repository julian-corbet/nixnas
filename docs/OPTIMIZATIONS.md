# nixnas — OPTIMIZATIONS.md

Kernel/boot/software tuning for the thin nixnas appliance layer. Two priorities, in order:
**(1) fast boot**, **(2) stick longevity** (minimise writes to the only two persistent
filesystems — `/nix` f2fs-in-LUKS and the FAT ESP). Storage/compression specifics are in
[`STORAGE.md`](STORAGE.md); the boot/crypto model is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

**Scope marker:** ⬢ = nixnas SETS it as an appliance default (implemented in `modules/`);
◇ = decided direction, NOT yet wired (deliberately deferred — reason given inline);
◯ = operator policy nixnas merely enables/recommends (cache choice, GC retention).
Out-of-scope items are listed at the end. The markers are kept honest against the code —
a ⬢ you cannot grep in `modules/` is a doc bug.

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
  supported path for TPM2-LUKS unlock + lanzaboote. (`modules/boot/image.nix`)
- ◇ `boot.kernelParams = [ "quiet" "loglevel=3" "udev.log_level=3" "rd.udev.log_level=3" ];`
  `boot.consoleLogLevel = 3;` — kill console/serial log I/O (slow on a VT, dominates on serial).
  DEFERRED while the appliance is in its bring-up phase: serial output is the debugging channel
  and stays observable until the hardware spikes are done.
- ◇ Slim UKI: `boot.initrd.includeDefaultModules = false;` + an explicit
  `boot.initrd.availableKernelModules` (USB/crypto/f2fs only). On a **< 10 MB/s** stick a smaller
  initrd is read faster — read time dominates, not CPU. DEFERRED: dropping the default module set
  risks unbootable hardware surprises; gate on a real-hardware spike, not the VM.
- ◇ `boot.initrd.compressor = "zstd"; boot.initrd.compressorArgs = [ "-19" ];` — on slow flash
  the smaller read beats the (tiny) decompress cost. Not yet wired (NixOS already defaults the
  systemd initrd to zstd; only the `-19` level is outstanding).
- ◇ `boot.kernelParams += [ "fsck.mode=skip" ];` — skip routine fsck. f2fs does roll-forward
  recovery from its checkpoint and the Nix store is reproducible/re-fetchable, so a heavy
  `fsck.f2fs` over a large store is wasted boot time. (Trade-off: no auto-repair — acceptable
  because the store is disposable; pairs with the "rely on Nix signatures" integrity model.)
- ⬢ `systemd-networkd-wait-online` disabled — `wait-online` is a notorious multi-second
  boot stall; a NAS must not block boot on link-up. (`modules/appliance/optimizations.nix`)
- ⬢ `boot.loader.timeout = 1` (mkDefault) — fast boot, and the generation menu (the guaranteed
  manual rollback) stays reachable with a keypress. (`modules/boot/image.nix`)

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
- GC options (`atgc`, `gc_merge`, `background_gc`): store is read-mostly → defaults are fine, don't
  over-tune.

## 4. Boot integrity & lanzaboote / UKI hygiene

- ⬢ `boot.lanzaboote.enable = true;` + `boot.loader.systemd-boot.enable = lib.mkForce false;` —
  signed UKIs for Secure Boot.
- ⬢ **`boot.lanzaboote.pkiBundle` lives on persistent storage, not tmpfs root** — else the SB
  signing keys vanish each boot. It is `/nix/lanzaboote/pki` directly (the encrypted store), no
  bind needed. (`modules/boot/secureboot.nix`)
- ⬢ **Persist boot identity** that tmpfs would wipe: `/etc/machine-id`, the running system's SSH
  host key, each `nixnas.persist.overlayClients` entry's state, `/var/lib/nixos` — all on the
  encrypted store at `/nix/persist` (`modules/appliance/identity.nix`). If these regenerated each
  boot, machine-id / the pinned SSH identity / the mesh node identity would drift. (The LUKS
  header is on-disk already; the initrd unlock host key is separately TPM-sealed by
  remote-unlock.) `modules/appliance/persist-enforce.nix` then fails the build for any OTHER
  `StateDirectory`-declaring service that is neither persisted nor an acknowledged
  `nixnas.persist.explicitlyEphemeral` entry.
- ⬢ generation count = `nixnas.boot.keepGenerations` (default **8**, sized to the 1 GiB ESP —
  one signed UKI each) via `boot.loader.systemd-boot.configurationLimit`, which lanzaboote
  inherits; bounding the count caps ESP writes/space (the ESP is the tighter bound — see
  ARCHITECTURE.md §2). (`modules/boot/rollback.nix`)
- ◯ `nix.settings.require-sigs = true;` + trust only the hub's cache key → `nix store verify`
  covers store integrity. f2fs has no default data checksums; rely on Nix signatures +
  reproducibility rather than fs-level data checksums (this is also what justifies `fsck.mode=skip`).

## 5. RAM: compressed store-in-RAM, zram, build placement (the slow-stick answer)

- ◯ **Substitute what a cache already has:** `nix.settings.substituters = [ "<your cache>" ];`
  so `system.autoUpgrade` *downloads* prebuilt, signed closures where they exist — then the only
  `/nix` writes are the new closure itself, no build intermediates hammering the slow flash, and
  no transient-ENOSPC mid-build (STORAGE.md §6 footgun 5). Note the frame from ARCHITECTURE §4:
  nixnas targets boxes strong enough to build themselves (a nixnas box is typically the *hub*
  that builds for weaker machines) — so on-box building is sanctioned; a cache is an
  optimisation, not a doctrine, here.
- ⬢ **The memory subsystem belongs to [nixram](https://github.com/julian-corbet/nixram-corbet-ch),
  not to nixnas.** nixnas composes it (`nixosModules.nixnas` pulls in `nixram.nixosModules.nixram`)
  and sets only `nixram.enable = true` + `mode = "zram"` — the latter forced by
  `swapDevices = [ ]`, since zswap is a cache in *front* of a durable swap device and there is none.
  **Every host must declare its RAM level once**, because nix evaluation cannot read the target's
  `/proc/meminfo`:

  ```
  nix run github:julian-corbet/nixram-corbet-ch#detect-level
  nixram.level = "…";   # paste the printed line
  ```

  Skipping it is a build failure with that command in the message, never a silently-wrong tuning.
  nixram then derives zram sizing/algorithm, the `vm.*` reclaim sysctls and the systemd-oomd
  thresholds from that one level, as a coherent set.

  *Why it moved:* nixnas used to hand-declare `zramSwap` at 20 % and own **nothing** else in the
  subsystem — no zswap stance at all. The CachyOS kernel nixnas ships is built
  `CONFIG_ZSWAP_DEFAULT_ON=y`, so zswap was armed before userspace existed, in front of a zram-only
  swap, on a live 125 GiB deployment: compressing already-compressed pages into the same RAM it was
  caching, with `written_back_pages` pinned at 0 because there was nowhere to evict to. Nothing in
  any config file pointed at it. A subsystem split across two owners has gaps exactly where neither
  is looking, so it now has one owner. nixram's `zram` mode also actively disables zswap.

- ⬢ **No disk swap.** This is the **RAM-compression** lever: the appliance keeps its writable working
  set (tmpfs root + anon memory) small by compressing cold pages *in RAM* instead of writing them —
  zero flash writes, and it makes nixnas fit boxes with far less than 128 GB. (Pairs with f2fs
  `compress_cache`, which caches *compressed* store blocks in RAM — STORAGE.md §4 / OPTIMIZATIONS §3.)
  Note: the stick is **not** copied wholesale into RAM (that was the dropped copytoram idea); only hot
  store paths are page-cached on demand, and that cache is self-limiting.
- ⬢ **`nixnas.store.preload` — "copytoram done right" for a slow stick.** A low-priority post-boot
  service warms the booted generation's closure into the (compress-)cache (`vmtouch`-style), so after
  warmup **runtime reads come from RAM, the stick is untouched, no cold-path stalls** — copytoram's
  one real win, but it (a) keeps self-update working (writes still hit the persistent stick store) and
  (b) costs ~⅓ the RAM of classic copytoram because `compress_cache` holds the blocks **compressed**
  (zstd:22), not decompressed. **Does NOT speed the cold boot** — the closure is read from the stick
  once regardless (zstd:22 already cuts that ~2–3×). Default: **on** for the reference box (128 GB);
  **RAM-gated** for the general distro (on only when RAM comfortably exceeds the closure, else
  demand-paged + `compress_cache` alone). A fast USB-3 stick makes the whole question moot.
- ⬢ `boot.tmp.useTmpfs = true;` (from §1); if any local build ever runs, keep its `TMPDIR` in RAM.

## Out of scope (operator territory — flag, don't tune here)

- ZFS ARC sizing (`zfs_arc_max`), `recordsize`, dataset `compression`/`atime` on the **data
  pools** — operator's plain-NixOS config. (Per house doctrine: never fence RAM away from ARC.)
- k3s, GPU drivers, Samba/NFS share tuning, libvirt/VMs — operator.
- Kernel **version** is a *constraint* (newest cached OpenZFS-compatible), not a tunable — don't
  chase mainline/bleeding-edge (STORAGE.md §5).
- `fstrim`/discard on the **data disks** — operator.
