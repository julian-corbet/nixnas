# nixnas — HOT-MODE.md (the two store locations)

nixnas has two ways to place the OS's `/nix` store **and its root filesystem**, chosen by
`nixnas.store.location`:

| | `usb` (default) | `hot` |
|---|---|---|
| The OS `/nix` store lives on | the USB stick (LUKS2+f2fs) | the operator's own encrypted storage (a "hot" device — SSD pool, etc.) |
| The OS root (`/`) lives on | **tmpfs** (impermanence) | the operator's own encrypted storage (`store.root.*`, REQUIRED — ORDINARY persistent filesystem, no tmpfs, no default) |
| The USB stick holds | the whole OS + ESP | ESP + a self-contained **rescue** system only |
| Store size ceiling | the stick (8 GiB-class) | the hot device (unlimited) — install anything system-wide |
| Boot unlock | TPM2 (auto or PIN) unlocks the stick store | the **operator enters their key** in the initrd (no auto); it unlocks the hot store AND the root |
| Survives a dead data pool | yes — the whole OS is on the stick | via the **rescue** system on the stick |
| For | small appliances, max resilience | hub-class boxes that run a lot, for a long operational lifetime |

`usb` is unchanged from nixnas's original design. This document specifies `hot`.

**Why `hot` gets a real root and `usb` doesn't:** impermanence is right for a system with no
state worth keeping — a small appliance re-flashed from a known config, or a rescue system
booted only when the main OS won't. It is wrong for a MAIN that accumulates operational
state over months: every path an operator forgets to route through `persist.*` is state
silently destroyed on the next reboot, discovered only once it's already gone. `hot` mode's
MAIN therefore carries **no tmpfs root at all** — `/` is an ordinary persistent filesystem,
exactly like `/nix`, and every service's `/var/lib` just survives a reboot with zero special
handling (see `docs/ARCHITECTURE.md` §3.2). `modules/appliance/identity.nix` and
`modules/appliance/persist-enforce.nix` (the machinery that routed identity and enforced
state-accounting around `usb` mode's tmpfs root) both gate on `store.location == "usb"` and
never run in `hot` mode — there is nothing left for them to do once the root is real.

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
  `hot/nixnas/nix`). One normal writable store: autoUpgrade writes new generations, GC
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

**One key, every pool — the unlock algorithm.** The operator key you enter once is tried
against EVERY declared LUKS member in the initrd — the hot-store members (`store.hot.unlock`,
e.g. hot) AND the data members (`storage.unlock`, e.g. a cold archive pool + standalone
archive disks). Whatever the key opens, opens; the pools that become available are imported. So
a whole set of SEPARATE pools that share ONE passphrase all come up from a SINGLE entry — there is
no second post-boot `nixnas-unlock` in hot mode (it stays a manual fallback). The two member
classes differ only in failure semantics: hot members are boot-critical (`device-timeout=0`,
infinite wait — no `/nix` without them), data members are `nofail` with a finite device timeout
(an absent or dead archive disk is SKIPPED, never hangs the boot). Stage-2 then auto-raises
`nixnas-storage.target` off the already-open mappers (imports + mounts) with no further prompt.

Where `/nix` and the data literally share ONE pool (the simplest whole-disk-LUKS box) the same
holds trivially — one key, one pool, everything up. "Full OS running, data still locked" is a
`usb`-mode / rescue property (the rescue needs no pool at all), not a hot-mode one: hot mode's
contract is that one secure entry brings up everything the key fits.

Storage-agnostic: nixnas only requires the hot store to be an operator-declared, unlockable
device with a filesystem NixOS can mount as `/nix`. ZFS is one choice (then the initrd
carries ZFS); LUKS+ext4/btrfs/f2fs work too, with no ZFS anywhere.

**Where the Secure Boot PKI lives — DECIDED (footguns beat imaginary attackers).** The
signing PKI exists in three places: the rescue's stick store (baked in at image build,
TPM+Secure-Boot-guarded), the main's hot store (seeded at install, passphrase-guarded —
what lanzaboote and rescue-maintain sign with at runtime), and the operator's encrypted
config store (sops or equivalent — the root copy). *Considered and rejected:* shredding
the stick copy after install as extra hardening. Extracting it already requires defeating
Secure Boot + the PCR-bound TPM + the firmware password (every physical path converges on
ciphertext, and a brute NVRAM clear wipes an fTPM — destroying the seal, not revealing
it), while the shred adds real self-inflicted failure modes: disaster recovery that needs
the build machine at exactly the worst moment, a latent lanzaboote failure on any future
rescue-side rebuild, and — combined with loss of the config-store copy — a box whose
firmware trusts a key nobody holds. Keys you can't lose beat keys nobody can steal.

## Boot flow

```
firmware → stick ESP → signed systemd-boot menu:
  ├─ MAIN gen N   → UKI → initrd: NIC up, initrd-SSH, WAIT for operator key
  │                        → unlock hot device + root device → mount /nix + / (both
  │                          ORDINARY persistent filesystems — no tmpfs anywhere here)
  │                        → switch-root → full system, exactly as it was before reboot
  ├─ MAIN gen N-1 …  (rollback targets; their UKIs are on the ESP)
  └─ RESCUE      → UKI → boots wholly from the stick (no pool), tmpfs root → repair shell (+ extraPackages)
```

## Install — the rescue system IS the install environment

Works the same whether the box already has a pool (a migration) or has BLANK DISKS (a
fresh machine) — the rescue boots with zero pools and is the bootstrap environment.

0. **Fresh machine only — create your encrypted storage from the rescue shell.** nixnas
   never formats data storage, so this step is yours, with the tools the rescue ships:
   `cryptsetup luksFormat` each member with YOUR passphrase → open them at stable mapper
   names → `zpool create` over `/dev/mapper/*` (or mkfs on LUKS — nixnas is
   storage-agnostic) → create the OS store dataset AND the root dataset — typically
   siblings on the same pool. For ZFS, pick one of the two mount shapes per dataset and
   declare it with `nixnas.store.{hot,root}.zfsMountpoint`:

   ```
   # "legacy" (the default) — ZFS does not manage the mount; mount(8) does.
   zfs create -o mountpoint=legacy pool/system/nix
   zfs create -o mountpoint=legacy pool/system/root

   # "property" — a real mountpoint plus canmount=noauto, mounted with -o zfsutil.
   # An imported pool is then self-describing: zfs list shows where each dataset belongs.
   zfs create -o mountpoint=/nix -o canmount=noauto pool/system/nix
   zfs create -o mountpoint=/    -o canmount=noauto pool/system/root
   ```

   The two are **mutually exclusive at mount(8)** — `-o zfsutil` against a
   `mountpoint=legacy` dataset is refused, and a property-mountpoint dataset cannot be
   mounted without it — so the declared shape must match what the dataset actually
   carries. `nixnas-install-hot` checks this before it writes anything. `canmount=noauto`
   is mandatory for `property`: without it, anything running `zfs mount -a` against the
   imported pool would mount the dataset straight over a live mountpoint.

   Note which half is load-bearing: the mount **target** always comes from nixnas's
   `fileSystems` declaration, never from the dataset's mountpoint property. `zfsutil` only
   makes `mount.zfs` fold the dataset's properties into the mount options. A `property`
   dataset is self-describing, not self-mounting.

   Migrating boxes skip this — the pool exists.
1. Build + flash the **rescue** image (ESP + rescue f2fs) to the stick via the TUI.
   (In `hot` mode the disko image is the RESCUE system; the main store and root are not in
   the image.)
2. Boot the rescue → unlock (or step-0-create) the pool → get the MAIN closure onto the
   box: build it on your build machine and `nix copy --to ssh://<rescue>` it over
   (hub-built doctrine), or build on the box if it has the resources.
3. Run the installer — one command does the whole error-prone dance, verified:

   ```
   nixnas-install-hot --device pool/system/nix --root-device pool/system/root \
     /nix/store/…-nixos-system-main
   ```

   It stages the target — the ROOT device mounted at `/mnt/nixnas-install` (a REAL
   persistent filesystem, not a scratch tmpfs: everything `nixos-install` writes there —
   `/etc`, `/var`, every service's state directory — must survive every future reboot), the
   hot store mounted at `./nix` within it, and the booted stick's ESP bind-mounted at
   `./boot` — seeds the Secure Boot PKI into the target store, `nixos-install --system`s
   the main (profile in the hot store, signed UKIs onto the shared ESP, and the real root
   populated), pre-places the durable `EFI/Linux/nixnas-rescue.efi` (the main's installer
   prunes the rescue's original `nixos-*` entries, and rescue-maintain only takes over
   after the main first boots), and verifies all of it before telling you to reboot.
   (Do NOT `nixos-rebuild` from the rescue — that would build into the rescue's own stick
   store and switch the RESCUE's profile, not the main's.)
4. Reboot → the main UKI's initrd asks for your key → unlocks the hot device AND the root
   device → mounts the now-populated `/nix` and `/` → the full system boots. From then on
   the main's rescue-maintain keeps the rescue entry + stick store current automatically,
   and every reboot after the first finds the SAME root it left — no re-provisioning, no
   `persist.*` list to maintain.

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
  (`store.hot.*`, neededForBoot) AND root (`store.root.*`, an ORDINARY persistent
  filesystem — REQUIRED, no default, no tmpfs fallback), and the initrd operator-key
  unlock of **all members — hot, root, AND data** (`store.hot.unlock` ∪ `store.root.unlock`
  ∪ `storage.unlock`), serialised into one kernel-keyring chain so a SINGLE entry opens
  every pool that shares the key. Hot and root members are boot-critical
  (`device-timeout=0`); data members are `nofail` + finite timeout (skip an absent/dead disk).
  ZFS-in-initrd when EITHER the hot store or the root is a dataset (import ordered after
  cryptsetup.target — the pool appears only after the key; one `zfs-import-<pool>` service
  per distinct pool name, so hot and root sharing one pool cost only one import); by-label
  ESP mount disko no longer provides. `modules/appliance/identity.nix` and
  `persist-enforce.nix` (the usb-mode tmpfs-routing machinery) do not run here at all —
  see the "Why `hot` gets a real root" note above.
- `modules/storage/connect.nix`: hot-aware. Since the initrd opened the data members too, in
  hot mode it does NOT re-open them and AUTO-RAISES `nixnas-storage.target` at boot (imports the
  data pools off the open mappers + mounts) — no manual `nixnas-unlock`. In `usb`/rescue mode it
  is unchanged: members stay locked at boot, `nixnas-unlock` raises the target post-boot.
- `modules/boot/disk.nix` + `modules/store/budget.nix` + `modules/crypto/tpm2.nix`
  (auto-unlock half): gated to `usb`-mode systems — which includes the RESCUE, a minimal
  usb nixnas the operator declares as a second host (there is no separate rescue module;
  `rescue.extraPackages` rides `appliance/base.nix`).
- `modules/appliance/rescue-maintain.nix`: the MAIN maintains the rescue (closure → stick
  f2fs with the shared compression options + GC to current/prev; self-contained signed UKI
  → ESP). Runs at boot, on deploys that change the rescue, and daily. The UKI's build+sign+
  place+rotate step is now `nixboot.extraEntries.rescue` (github:julian-corbet/nixboot-corbet-ch)
  for the pinned/hub-built persona (`rescue.toplevel`) — this file's own build/sign/place code
  stays only for the self-upgrading persona (`rescue.flakeAttr`), which resolves its toplevel at
  runtime and so cannot be expressed as one of nixboot's declarative `extraEntries` (see that
  file's header for the full split).
- Docs: this file + ARCHITECTURE §3.2 (the persistent-root boot flow) + §10 (the
  composed-store rejection).

## Already running a `hot`-mode host on the old tmpfs root?

`nixnas-install-hot` only targets a blank root (a fresh install or a migration onto new
disks). Moving a LIVE host from the old tmpfs root onto `store.root.*` is a separate,
by-hand procedure — see **[`MIGRATE-HOT-ROOT.md`](MIGRATE-HOT-ROOT.md)**.
