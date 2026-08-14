# nixnas — KERNEL.md (the CachyOS kernel + ZFS)

How nixnas gets a CachyOS-quality, task-tailored kernel. The storage/boot model is in
[`ARCHITECTURE.md`](ARCHITECTURE.md), appliance tuning in [`OPTIMIZATIONS.md`](OPTIMIZATIONS.md).

## 1. Decision

**Kernel = the CachyOS kernel, via the [`xddxdd/nix-cachyos-kernel`](https://github.com/xddxdd/nix-cachyos-kernel)
flake.** ZFS = the matching **`zfs_cachyos`**. Tuned for speed: `x86_64-v3` (Zen3), ThinLTO.

Why this over a hand-rolled "vanilla newest-ZFS base + lifted CachyOS patches":
- **It IS the CachyOS kernel** — the full, maintained patchset + config, not a re-derivation.
- **It matches the Arch/CachyOS LXC** we run on top (the LXC shares the host kernel — one world,
  not two).
- **Binary cache → no local kernel compile** (the maintainer publishes pre-built variants; see §3).
- **Tracks nixpkgs, pinned for cache hits** — the `release` branch publishes pre-built variants
  and the `pinned` overlay keeps the exact rev the maintainer's cache was built for; catching up
  with a kernel bump is a deliberate `nix flake update` (which lands the NEXT cached rev), not an
  unpinned live-follow.

> **The failsafe is structural, not the software choice.** Running `zfs_cachyos` (which forward-ports
> ZFS onto a kernel newer than upstream OpenZFS's cap) is acceptable **because a bad update cannot
> throw us off the rails** — see §5. We do not buy safety by picking conservative software; we buy it
> with rollback + pool hygiene.

## 2. Wiring

```nix
# flake.nix (operator's host flake / nixnas demo)
inputs.nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";  # release = pre-built

# host module
{ config, pkgs, ... }:
{
  nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ];  # pinned = cache hits

  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest;  # tuned variant: §4
  boot.zfs.package    = config.boot.kernelPackages.zfs_cachyos;            # matching CachyOS ZFS

  # the flake's cache (also auto-set via the flake's nixConfig):
  nix.settings.substituters         = [ "https://attic.xuyh0120.win/lantian" ];
  nix.settings.trusted-public-keys  = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
}
```

*(The tuned-combo attribute scheme, as consumed by `modules/boot/kernel.nix`, is
`linuxPackages-cachyos-<variant>[-lto][-<march>]` — the `lto` suffix comes BEFORE the march,
e.g. `linuxPackages-cachyos-latest-lto-x86_64-v3`. kernel.nix fails with an actionable error
when the requested combo is absent from the pinned set.)*

## 3. Binary cache vs local compile

- **`release` branch + `overlays.pinned`** → the maintainer's pre-built variants are **pulled** from
  `attic.xuyh0120.win/lantian`. The `x86_64-v3` latest/LTS variants are published (only the `x86_64-v2`
  variants are flagged "no binary cache").
- A combo the maintainer didn't pre-build (an unusual `lto`/`march` mix) would **compile locally** —
  `modules/boot/kernel.nix` fails EARLY with an actionable error instead, because a from-source
  kernel build on the target box defeats the pull-from-cache design. If you deliberately want an
  uncached combo, build it **once** on a capable machine and push it to your own substituter so a
  re-flash isn't a fresh kernel compile: `nix copy --to 'https://<your-cache>' <kernel-drv-out>`.
- **Interaction with x86_64-v3 userland (flag):** if we later set `nixpkgs.hostPlatform.gcc.arch` globally
  (whole-userland v3, see the v3 discussion), that changes the stdenv and **busts the lantian cache hit
  for the kernel too** → the kernel then compiles locally. Either accept that (it's a small fraction of a
  v3 world-build) or keep the kernel pulled from lantian and apply v3 only to the userland. Settle when
  v3 scope is locked.

## 4. Tuning — our choices + the options

| Option (`nixnas.kernel.*`) | Tuned example | General-distro default | Note |
|---|---|---|---|
| `variant` | `latest` | `latest` (or `lts` for stability) | `server` = EEVDF + lazy-preempt; `hardened` = +linux-hardened |
| `march` | **`x86_64-v3`** (any Zen 3+) | `x86_64-v1` (boots anywhere) | v3 = AVX2/FMA/BMI2; helps ZFS fletcher4/zstd, AES-NI, memcpy. `native`/`znver3` are rejected early (not pre-built — would compile on the box) |
| `lto` | **`thin`** | `thin` | ThinLTO = cheap + measurable; `full` is RAM-heavy for little gain |

Exposed as `nixnas.kernel.{variant,march,lto}` with these defaults. There is deliberately NO
`cpusched` option: the published pre-built variants bake `eevdf` in (the server-correct pick),
and a knob that silently delivered eevdf regardless would lie. A known CPU maxes speed
(`latest` + `x86_64-v3` + `thin` LTO); a general adopter who doesn't build for a known CPU stays
on the portable `x86_64-v1`.

**ZFS source** is an option too — `nixnas.zfs.source = cachyos | upstream`:
- **`cachyos`** (our default): matches `linux-cachyos-latest` (which is newer than upstream's ZFS cap).
- **`upstream`**: stock `zfs_2_4`, but then the kernel must stay **at/under the OpenZFS cap** (≈ 7.0.x) —
  i.e. pair with `linux-cachyos-lts` (6.18.x) or `-hardened` (7.0.x), which are under the cap. The
  conservative choice for an adopter who wants upstream-validated ZFS on their data.

## 5. The failsafe model (this, not the software choice, is the safety)

A failed kernel/ZFS update must never throw the box off the rails. Two independent safety nets:

- **OS — generation rollback.** Every update is a new generation with its own signed UKI; the previous
  known-good generation stays bootable. A kernel that won't boot, or a `zfs_cachyos` that won't build,
  is caught here: **boot-counting × lanzaboote** auto-reverts after repeated boot failure, and the
  **generation menu** is the guaranteed manual fallback. This makes "the CachyOS ZFS may fail to compile
  from time to time" a non-event: the build fails on the *build machine* (caught before flash), or a bad
  pull can roll back. The OVMF boot-chain suite checks the firmware boot-count path and requires
  the post-bless verifier to pass under enforced operator-owned Secure Boot keys. Exhausting a
  deliberately failed generation's tries and observing automatic selection of the previous one
  remains an explicit experiment; the generation menu is the proven fallback today.
- **Pool — scrub + snapshots + backups.** Rollback protects the OS, **not data already written to the
  pool**. The only risk class it can't undo is *silent on-disk corruption* — low-probability for a
  *compat* fork (its patches are kernel-API shims, not ZIO/on-disk-format changes; ZFS's historical
  silent-corruption bugs came from upstream *feature* work), and covered the same structural way: regular
  `zfs scrub` (detects it), snapshots, and the off-box backups. Standard ZFS hygiene, owned by the
  operator.
- **Build-then-test-then-flash.** The image (kernel included) is built and **QEMU-booted on the local TUI
  machine before it ever reaches the stick** — so a non-building/non-booting kernel never ships.

## 6. F2FS + the CachyOS kernel

The store is f2fs-zstd:22 (STORAGE.md). The CachyOS kernel inherits nixpkgs' f2fs config plus the
CachyOS patchset; `F2FS_FS_ZSTD` (`default y` under compression) holds. It is proven at RUNTIME by
the `verify-image` self-check in the built image (an eval-time kernel-config assertion is not
reliable for externally-packaged kernels — STORAGE.md §5); `f2fs` + `crc32` ride in the initrd
(STORAGE.md §4). ZFS stays out of stage 1 (post-boot import via nixnas-unlock); f2fs is the only
stage-1 filesystem.

## Sources
- [`xddxdd/nix-cachyos-kernel`](https://github.com/xddxdd/nix-cachyos-kernel) — packages, `processorOpt`/
  `lto`/`cpusched` params, `overlays.pinned`, cache `attic.xuyh0120.win/lantian` + key
  `lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=`, the `zfs_cachyos` "may fail to compile" caveat.
- OpenZFS 2.4.3 kernel cap 4.18–7.0; nixpkgs `zfs/generic.nix` `kernelMaxSupportedMajorMinor`.
