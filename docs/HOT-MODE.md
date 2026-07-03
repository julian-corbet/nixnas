# nixnas — HOT-MODE.md (the two store locations)

nixnas has two ways to place the OS's `/nix` store, chosen by `nixnas.store.location`:

| | `usb` (default) | `hot` |
|---|---|---|
| The OS `/nix` store lives on | the USB stick (LUKS2+f2fs) | the operator's own encrypted storage (a "hot" device — SSD pool, etc.) |
| The USB stick holds | the whole OS + ESP | ESP + a self-contained **rescue** system only |
| Store size ceiling | the stick (8 GiB-class) | the hot device (unlimited) — install anything system-wide |
| Boot unlock | TPM2 (auto or PIN) unlocks the stick store | the **operator enters their key** in the initrd (no auto); it unlocks the hot store |
| Survives a dead data pool | yes — the whole OS is on the stick | via the **rescue** system on the stick |
| For | small appliances, max resilience | hub-class boxes that run a lot |

`usb` is unchanged from nixnas's original design. This document specifies `hot`.

## Why `hot` exists — and why it is NOT a composed store

A hub wants an unlimited, fast, system-wide `/nix` (k3s, docker, ROCm userland, AI CLIs,
dev toolchains as real store paths), which physically cannot fit an 8 GiB stick. Every
attempt to COMPOSE one `/nix/store` from stick + pool is unsound (researched + rejected):
Nix's `local-overlay-store` needs an append-only lower (nixnas's stick is written by
autoUpgrade + pruned by GC); kernel overlayfs can't add a lower to a mounted store and you
can't remount a busy `/nix`; and a single toplevel spanning both media makes
`/run/current-system` dangle into the locked pool → non-bootable rescue.

So `hot` does **not** compose. It uses **two independent systems, each a normal single
store on its own medium** — the proven "NixOS root-on-ZFS + a USB rescue" pattern:

- **MAIN system** — its `/nix` is the operator's hot store (e.g. the ZFS dataset
  `hot/system/nix`). One normal writable store: autoUpgrade writes new generations, GC
  prunes them, exactly as any NixOS-on-ZFS box. This is what runs in normal operation.
- **RESCUE system** — a small, self-contained NixOS closure on the stick's own f2fs store,
  with its own signed UKI. It references ZERO paths on the hot store, so it boots to a full
  repair shell even with the pool totally dead. It carries `nixnas.rescue.extraPackages`
  (operator's pick — e.g. `claude-code`), so useful tools are present exactly when the pool
  is broken.

## The unlock model — operator key, never auto (the feature)

The hot store is on the operator's encrypted storage. At boot the initrd brings the NIC up,
runs initrd-SSH, and **blocks waiting for the operator to enter their key** (over SSH, or
console/IPMI-SOL). No TPM auto-unlock of the hot store or the data. A stolen, powered-off,
or maid-tampered box sits at the initrd forever without the key — encryption never opens
unattended. The channel is authenticated by the **TPM-sealed initrd host key** (PCR 7), so a
tampered initrd/swapped stick can't phish the key. Data confidentiality is a *feature*: you
must enter a key in a secure environment to unlock anything.

On a box where `/nix` and the data share one LUKS pool (the common case, e.g. example-host's
whole-disk-LUKS `hot`), the single key you enter at boot unlocks the pool — so `/nix` and
the data come up together. "Full OS running, data still locked" is not available in that
layout without a second encryption boundary; the **rescue** system covers the
data-free-maintenance case instead (it needs no pool at all).

Storage-agnostic: nixnas only requires the hot store to be an operator-declared, unlockable
device with a filesystem NixOS can mount as `/nix`. ZFS is one choice (then the initrd
carries ZFS); LUKS+ext4/btrfs/f2fs work too, with no ZFS anywhere.

## Boot flow

```
firmware → stick ESP → signed systemd-boot menu:
  ├─ MAIN gen N   → UKI → initrd: NIC up, initrd-SSH, WAIT for operator key
  │                        → unlock hot device → mount it at /nix → switch-root → full system
  ├─ MAIN gen N-1 …  (rollback targets; their UKIs are on the ESP)
  └─ RESCUE      → UKI → boots wholly from the stick (no pool) → repair shell (+ extraPackages)
```

## Install — the rescue system IS the install environment

1. Build + flash the **rescue** image (ESP + rescue f2fs) to the stick via the TUI.
   (In `hot` mode the disko image is the RESCUE system; the main store is not in the image.)
2. Boot the rescue → unlock the pool (`nixnas-unlock`) → stage the target: a tmpfs at
   `/mnt/target` with the hot store mounted at `/mnt/target/nix` and the stick ESP at
   `/mnt/target/boot`; seed the Secure Boot PKI into the target store
   (`mkdir -p /mnt/target/nix/lanzaboote && cp -a /nix/lanzaboote/pki /mnt/target/nix/lanzaboote/`).
3. Get the MAIN closure into the hot store — build it on your build machine and
   `nix copy --to "ssh://<rescue>?remote-store=/mnt/target"` it over (hub-built doctrine),
   or build on the box with `nix build --store /mnt/target` if it has the resources. Then
   `nixos-install --root /mnt/target --system <toplevel> --no-root-passwd` registers the
   profile in the hot store and installs the main's signed UKIs onto the shared ESP.
   (NOT `nixos-rebuild` from the rescue — that would build into the rescue's own stick
   store and switch the RESCUE's profile, not the main's.)
4. Before rebooting, pre-place the rescue's own `EFI/Linux/nixnas-rescue.efi` (the main's
   bootloader install prunes the rescue's original `nixos-*` entries — see the coexistence
   rules above; the durable entry normally comes from rescue-maintain, which hasn't run
   yet). One manual run of the same recipe: ukify the rescue's `/run/current-system`,
   sbsign with the db key, copy to the ESP.
5. Reboot → the main UKI's initrd asks for your key → unlocks the hot device → mounts the
   now-populated `/nix` → the full system boots. From then on the main's rescue-maintain
   keeps the rescue entry + stick store current automatically.

## autoUpgrade — maintains BOTH stores, from ONE nixpkgs pin

The main and rescue systems build from the same flake + pin (load-bearing: the rescue's
ZFS/kernel must always be able to import the live pool). Each run:

- **Main** → new closure into the hot store; new signed UKI → ESP; new boot entry. (Needs the
  hot device unlocked — true in normal operation.)
- **Rescue** → rebuilt only if its closure hash actually moved (a kernel/ZFS/base bump, or an
  `rescue.extraPackages` update like a new claude-code). Then: closure → stick f2fs; new
  signed rescue UKI → ESP. A pure main-app change writes nothing to the stick.

Result: the big closure never touches the stick; the stick takes one main UKI per update
(a UKI is the kernel + initrd in one PE — typically ~80–150 MiB, more if the initrd carries
ZFS; measure yours) and a rescue write only on rescue changes — kinder to the stick than
`usb` mode. Budget the ESP explicitly: set `boot.keepGenerations` so
(keepGenerations + 1 rescue + 1 rescue-prev) × your-UKI-size fits `boot.usb.espSizeMiB`.
`keepGenerations` thus splits into "bootable main UKIs on the ESP" (small) vs "hot-store
history depth" (as deep as you like).

Rollback: per store, independent. Caveat: don't `zpool upgrade` casually — an older main (or
rescue) built against a pre-upgrade ZFS can't import an upgraded pool; keep the rescue
current (the shared pin does this).

## Stick sizing (recommended per-host settings — the RESCUE host sets these)

Recommended: `boot.usb.espSizeMiB = 2048` (2 GiB — holds the main's kept UKIs + the rescue
pair; see the ESP budget rule above) and an image that never occupies more than **32 GiB**
regardless of stick size (a rescue system + generations never needs more): 8 GB stick →
`imageSizeGiB = 7` (2 + ~5); 16 GB → ~2 + 12; 32 GB → ~2 + 28; a 1 TB stick still gets 32.
The rescue closure alone is ~1.5–3 GiB, comfortable in ~5 GiB with current+prev (which is
exactly what rescue-maintain's GC keeps).

## What changes vs `usb` mode (implementation map)

- `modules/store/location.nix`: the `store.location` switch; the hot-mode MAIN /nix
  (`store.hot.*`, neededForBoot), the initrd operator-key LUKS unlock (serialised — one
  entry opens all members via the kernel-keyring cache), ZFS-in-initrd when the hot store
  is a dataset (with the import ordered after cryptsetup.target — the pool appears only
  after the operator's key), and the tmpfs root + by-label ESP mount disko no longer provides.
- `modules/boot/disk.nix` + `modules/store/budget.nix` + `modules/crypto/tpm2.nix`
  (auto-unlock half): gated to `usb`-mode systems — which includes the RESCUE, a minimal
  usb nixnas the operator declares as a second host (there is no separate rescue module;
  `rescue.extraPackages` rides `appliance/base.nix`).
- `modules/appliance/rescue-maintain.nix`: the MAIN maintains the rescue (closure → stick
  f2fs with the shared compression options + GC to current/prev; self-contained signed UKI
  → ESP). Runs at boot, on deploys that change the rescue, and daily.
- Docs: this file + ARCHITECTURE §10 (the composed-store rejection).
