# nixnas

Package **your own** declarative NixOS as a USB appliance (8 GB+) with encrypted
store geometry and your existing storage connected. Nixnas owns the appliance
runtime, storage layout and non-boot payload. Nixboot owns the booted
kernel/initrd artifact and everything from firmware to `switch-root`. Nixdeploy owns every delivery path,
including updates, activation outcomes, rescue materialisation and rollback.

The current source still includes a local flash path, `autoUpgrade`, and
`nixnas-switch`. Those are deprecated
ownership overlaps to remove as consumers migrate to nixdeploy, not evidence
that the boundary above is already fully realised.

**Two store locations** (`nixnas.store.location` — [`docs/HOT-MODE.md`](docs/HOT-MODE.md)):

| | `usb` (default) | `hot` |
|---|---|---|
| The OS `/nix` lives on | the stick (LUKS2+f2fs, runs from RAM) | your encrypted pool — unlimited system-wide installs |
| The stick holds | the whole OS | the ESP; an independent boot role may own separate rescue slots |
| Unlock at boot | **you enter your passphrase** | **you enter your passphrase** in the initrd |
| A dead pool means | the OS still boots | the main cannot boot; use an independently delivered rescue role |
| For | small appliances, max resilience | hub-class boxes that run a lot |

- **`usb` mode boots into RAM** — the root is a tmpfs (impermanence); only `/nix`
  and the ESP persist, and the booted closure is warmed into a compressed page cache, so
  the slow stick is spared after boot. (This is "run from RAM" done right — not
  `copytoram`, which doesn't compose with self-update.)
- **Multiple signed versions, rollback**: each past generation stays bootable as its own
  signed UKI; the bootloader menu is the guaranteed manual rollback, and boot-counting
  adds automatic fallback on top.
- **Survives storage trouble**: in `usb` mode the OS is independent of your data storage —
  the box boots even if a disk is degraded or missing (non-fatal import). In `hot` mode,
  recovery is deliberately a separate `nixrescue` artifact/delivery concern; nixnas neither
  builds a per-host rescue nor writes its slots.
- **Encrypted at rest, passphrase-only**: in `usb` mode the on-stick store is LUKS2 +
  f2fs (zstd-compressed); in `hot` mode the OS store shares your pool's encryption. In both
  cases **only your passphrase opens it**, locally/IPMI or through an authenticated
  TPM-gated initrd-SSH channel. Your data is also passphrase-only — never TPM-bound, never
  keyfile-persisted: post-boot `nixnas-unlock` opens the
  whole set with ONE passphrase. A seized disk (or box) reveals nothing, and a disk pulled
  into another machine still opens with the passphrase — no specific box's TPM required.
- **Bring your own storage**: nixnas imports + unlocks whatever you already use — any Linux
  filesystem and encryption — and never creates, formats, or destroys it.
- **Kind to the stick**: logs, `/tmp`, coredumps and swap live in RAM, so
  routine runtime activity avoids writing the USB. The OS runs from RAM; the
  heavy state (container images, data) lives
  on your encrypted storage, never the stick.
- **Evil-Maid hardened**: UEFI Secure Boot with *your own* keys (Microsoft keys not
  enrolled), signed Unified Kernel Images, mandatory disk passphrase, and a TPM-gated
  remote prompt identity. Firmware remains an unavoidable trust boundary.
- **First boot is fail-closed remotely**: initrd SSH stays down until a successful local/IPMI
  boot has generated the TPM-sealed host credential. There is no ephemeral or TOFU fallback.
  Verify subsequent SSH against the public key beside the credential on the ESP. A monitor
  works in parallel: plug in a display
  + keyboard and the box asks for the store passphrase **on screen**
  (`nixnas.boot.consolePrimary = "video"`, the default). Serial/SOL stays fully supported
  and is one option away (`= "serial"` for IPMI/BMC boxes); both consoles always carry
  kernel logs, a login and the passphrase prompt either way — the option only picks which
  one is `/dev/console`.
- **Headless**: ships sshd + Tailscale with a stable, stick-persisted identity (machine-id +
  pinned SSH host key — the channel you type the data passphrase into is authenticated), and
  unlocks remotely: the data set over the running system's SSH (`nixnas-unlock`), and — after
  the sealed identity exists — the store's passphrase prompt over SSH **in the initrd**.
- **Current automated path**: the shipped source can build, sign, flash and
  self-update stage-only without self-reboot. Triggering, materialising and
  reporting those operations belong to nixdeploy in the target model.
- **Current activation wrapper**: `nixnas-switch [switch|boot|test]` is the shipped way to
  activate a configuration on a running box — the real `switch-to-configuration` runs
  **detached** in a transient systemd unit, so a dropped SSH session can never
  half-activate the system, while the wrapper follows the journal and reports the unit's
  real `Result=`. It refuses to overlap a running switch and clears a stale activation
  lock only when no switch process is alive. Never run activation through a droppable
  session. This wrapper remains functional while activation ownership migrates
  to nixdeploy.

## What nixnas is — and is not

nixnas is the **appliance mechanism**: it turns any `nixosConfiguration` into a
RAM-resident, encrypted USB-appliance artifact. The **workloads** a
particular box runs — k3s, containers, VMs, Samba/NFS, GPU — are **plain NixOS that
*you* declare**, in the same host, alongside `imports = [ nixnas.nixosModules.nixnas ]`.
Nixboot supplies the boot artifact and verification contract; nixdeploy owns
delivery of both the primary and nixrescue roles. See [`docs/SCOPE.md`](docs/SCOPE.md).

## Design

**nixnas is a distribution, not a personal config.** The public repo is the generic,
parameterised core; your machine's real disks, IPs, and secrets live in a *separate,
private overlay repo you own* that imports `nixnas` as a flake input (`templates/host`
scaffolds one). The public core never references any private overlay.

A small **Rust TUI** (`tui/`) currently builds and flashes the image **locally**, on a trusted machine
that holds your Secure Boot keys: it drives the flake's image script, injecting your LUKS
passphrase into the builder VM and your (sops-encrypted) Secure Boot PKI onto the image —
nothing secret enters the Nix store, and the image is personalised *and* self-signed, so it
cannot be built generically or remotely. (The break-glass recovery escrow is a separate
hub-side tool — `nixnas-escrow-recovery`.)

The TUI runs as your **normal user** — the build uses your own Nix and keys — and elevates
*only* the raw-device write with an in-tool sudo prompt (no `sudo nixnas`, no env wrappers).
Its turnkey path, **Build & Flash**, takes one stick end to end: pick the device and the
image is sized to its **exact byte count** — no gigabyte rounding, no wasted space — then
built, flashed, and verified in a single guided flow, with an explicit *back-up-first?*
prompt before anything is overwritten. This is the current implementation;
appliance-payload production remains a nixnas concern, while nixboot supplies
the boot artifact and selecting a target and materialising the composed image
belongs under nixdeploy. A conventional **Build
image** + **Flash stick** pair is present today. The finished
stick carries plain, self-describing labels: partition **`boot`** (the ESP) and **`nixnas`**
(the encrypted store).

**Access model — one passphrase, keys for remote.** There is exactly ONE interactive
secret: the store passphrase. It unlocks the LUKS store at boot,
and it is also the **console login password** for `root` — and for the optional normal
admin user (`nixnas.auth.adminUser`, wheel + sudo-with-password). No autologin, no second
password to remember: the TUI derives a yescrypt hash from the passphrase at build time
and places it as a *runtime* file on the **encrypted** store
(`/nix/nixnas/auth/passphrase.hash` — never in the Nix store). **SSH is key-only** for
both accounts (`nixnas.admin.authorizedKeys`); passwords are never accepted remotely. If
the hash file is absent (e.g. a hot-mode main installed without it) the accounts simply
stay locked for password login — fail-closed, boot unaffected. Known limitation: the
**initrd emergency shell stays locked** (the hash is a runtime file on the still-locked
store, so `boot.initrd.systemd.emergencyAccess` can't use it without going stale) —
stage-1 rescue is the generation menu or a second stick. See
[`modules/appliance/auth.nix`](modules/appliance/auth.nix).

See [`docs/SCOPE.md`](docs/SCOPE.md) (what nixnas is / is not),
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (the decided design), and
[`docs/REPO-LAYOUT.md`](docs/REPO-LAYOUT.md).

## Status

The full decided model boots end-to-end — and CI re-proves it on every push, for free, on
GitHub's KVM-capable public runners (`.github/workflows/boot-test.yml`): the image is
built and booted in QEMU/OVMF/swtpm (`test/`), the TPM-sealed initrd-SSH host key must
survive a genuine power cycle, a wrong TPM must fail closed (`--tamper`), and the hot-mode
external-store boot must reach login from a single operator key entry:

- ✅ CachyOS kernel (x86-64-v3 + ThinLTO, `zfs_cachyos`) + impermanence (tmpfs root) +
  the LUKS2 **f2fs zstd:22** store, all from one disko-built image.
- ✅ **Secure Boot** via lanzaboote (operator-owned keys, signed UKIs).
- ✅ **Passphrase-only disk unlock** on every boot; TPM never receives a LUKS keyslot.
- ✅ **Headless remote unlock** — initrd-SSH uses a per-device TPM-gated host identity and
  hands the mandatory passphrase to the initrd. No TPM means console/IPMI only.
- ✅ **Post-boot data unlock** — data members stay locked (`noauto`) until `nixnas-unlock`
  over SSH: one passphrase opens the set serially, imports the ZFS pools, and raises
  `nixnas-storage.target` for the gated mounts + services.
- ✅ **Stick-persisted identity** — machine-id, the running SSH host key and tailscale state
  live on the encrypted store, so the box is trustably reachable before any data unlock.
- ✅ **Rollback** — bounded kept generations + the bootloader menu (guaranteed), plus
  boot-counting (lanzaboote writes/counts the entry down).
- ✅ **Current self-update implementation** — `autoUpgrade`, stage-only, never
  self-reboots. It is marked for migration because nixdeploy is the delivery owner.
- ✅ **Hot mode** (`store.location = "hot"`) — the MAIN system boots with `/nix` on an
  external, operator-key-unlocked LUKS device: the initrd asks for YOUR key and proceeds
  only then (CI-proven in QEMU, including the serialised single-entry unlock — two LUKS
  members, one passphrase entry). Recovery is an independent, fleet-generic nixrescue release;
  the old per-host maintainer has been removed from nixnas.
  The hot-store-on-ZFS initrd path (legacy dataset mount + import-after-key) is
  design-verified but first runs on real hardware.

Hardware gates remaining (a real UEFI box, not the VM): Secure Boot owner-key enrollment,
firmware setup-password enforcement, physical TPM credential bootstrap, and main/rescue boots.
Signed-version anti-rollback is not claimed; TPM is reserved for SSH identity. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

[Apache-2.0](LICENSE)

Contributions are accepted under the same license.
