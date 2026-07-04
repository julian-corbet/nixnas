# nixnas

Boot **your own** declarative NixOS from a USB stick (8 GB+) — with the whole boot chain
hardened, self-update and rollback built in, and your existing storage connected. nixnas
is the appliance mechanism (boot, crypto, the store, the kernel); the workloads are plain
NixOS you bring. A local TUI writes your signed image. Built to be adopted (and
contributed to) by others, not just one machine.

**Two store locations** (`nixnas.store.location` — [`docs/HOT-MODE.md`](docs/HOT-MODE.md)):

| | `usb` (default) | `hot` |
|---|---|---|
| The OS `/nix` lives on | the stick (LUKS2+f2fs, runs from RAM) | your encrypted pool — unlimited system-wide installs |
| The stick holds | the whole OS | the ESP + a self-contained **rescue** system |
| Unlock at boot | TPM2 (PIN optional) | **you enter your key** in the initrd — never auto |
| A dead pool means | the OS still boots | the rescue boots (repair shell + your own tools) |
| For | small appliances, max resilience | hub-class boxes that run a lot |

- **`usb` mode boots into RAM** — the root is a tmpfs (impermanence); only `/nix`
  and the ESP persist, and the booted closure is warmed into a compressed page cache, so
  the slow stick is spared after boot. (This is "run from RAM" done right — not
  `copytoram`, which doesn't compose with self-update.)
- **Multiple signed versions, rollback**: each past generation stays bootable as its own
  signed UKI; the bootloader menu is the guaranteed manual rollback, and boot-counting
  adds automatic fallback on top.
- **Survives storage trouble**: in `usb` mode the OS is independent of your data storage —
  the box boots even if a disk is degraded or missing (non-fatal import). In `hot` mode
  that role moves to the **rescue** system: a small, self-contained NixOS on the stick that
  boots with zero pools and carries the repair tools *plus whatever you want at 3 a.m. with
  a dead pool* (`rescue.extraPackages` — an AI CLI, say). The running main maintains it
  automatically (closure, GC, signed boot entry).
- **Encrypted at rest, two independent layers**: in `usb` mode the on-stick store is LUKS2 +
  f2fs (zstd-compressed), bound to the TPM2 (PIN optional — with it a powered-off box never
  auto-decrypts; without it the box self-recovers from a power cut). In `hot` mode the OS
  store shares your pool's encryption and **only your key opens it — entered in the initrd
  over an authenticated channel (TPM-sealed initrd-SSH host key), never TPM-released**: a
  stolen, powered-off box sits at the initrd forever. Your DATA is passphrase-only in both
  modes — never TPM-bound, never keyfile-persisted: post-boot `nixnas-unlock` opens the
  whole set with ONE passphrase. A seized disk (or box) reveals nothing, and a disk pulled
  into another machine still opens with the passphrase — no specific box's TPM required.
- **Bring your own storage**: nixnas imports + unlocks whatever you already use — any Linux
  filesystem and encryption — and never creates, formats, or destroys it.
- **Kind to the stick**: logs, `/tmp`, coredumps and swap live in RAM, so the USB takes ~no
  writes except updates — measured at **60 KiB** for ~100 MiB of log+file activity. Cheap
  sticks don't wear out. The OS runs from RAM; the heavy state (container images, data) lives
  on your encrypted storage, never the stick.
- **Evil-Maid hardened**: UEFI Secure Boot with *your own* keys (Microsoft keys not
  enrolled), signed Unified Kernel Images, and LUKS bound to TPM2 + PIN. *(Roadmap: a
  dm-verity/AEAD store hash sealed into the signed UKI.)*
- **First boot just works on a monitor**: plug in a display + keyboard and the box asks for
  the store passphrase **on screen** (`nixnas.boot.consolePrimary = "video"`, the default).
  This matters because the very first unlock can never happen over initrd-SSH — the
  TPM-sealed initrd host key is generated *on* that first boot, so remote unlock is
  available from the second boot on. Serial/SOL stays fully supported and is one option
  away (`= "serial"` for genuinely headless IPMI/BMC boxes); both consoles always carry
  kernel logs, a login and the passphrase prompt either way — the option only picks which
  one is `/dev/console`.
- **Headless**: ships sshd + Tailscale with a stable, stick-persisted identity (machine-id +
  pinned SSH host key — the channel you type the data passphrase into is authenticated), and
  unlocks remotely: the data set over the running system's SSH (`nixnas-unlock`), and — when
  the strict TPM2 PIN is on — the store's PIN prompt over SSH **in the initrd** (no console
  needed, from the second boot on — the first unlock happens at the machine or over SOL;
  see the first-boot bullet above).
- **Hands-off**: everything except the one boot passphrase is automated — build, sign,
  roll out, self-update (stage-only, never self-reboot), rollback. *If you have to think
  about it, something has gone wrong.*

## What nixnas is — and is not

nixnas is the **appliance mechanism**: it turns any `nixosConfiguration` into a
bootable, RAM-resident, encrypted, rollback-safe USB stick. The **workloads** a
particular box runs — k3s, containers, VMs, Samba/NFS, GPU — are **plain NixOS that
*you* declare**, in the same host, alongside `imports = [ nixnas.nixosModules.nixnas ]`.
nixnas builds + signs + flashes whatever closure you hand it. See [`docs/SCOPE.md`](docs/SCOPE.md).

## Design

**nixnas is a distribution, not a personal config.** The public repo is the generic,
parameterised core; your machine's real disks, IPs, and secrets live in a *separate,
private overlay repo you own* that imports `nixnas` as a flake input (`templates/host`
scaffolds one). The public core never references any private overlay.

A small **Rust TUI** (`tui/`) builds and flashes the image **locally**, on a trusted machine
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
prompt before anything is overwritten. A conventional **Build image** + **Flash stick** pair
is there for reuse (the latter grows a minimal image to fill any larger stick). The finished
stick carries plain, self-describing labels: partition **`boot`** (the ESP) and **`nixnas`**
(the encrypted store).

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
- ✅ **TPM2** store unlock (PIN strict-by-default, auto-unlock optional), passphrase recovery
  keyslot, first-boot `nixnas-enroll-tpm2` helper.
- ✅ **Headless remote unlock** — initrd-SSH brings the NIC up and hands the passphrase to
  the boot in the initrd (validated unlocking the box entirely over the network).
- ✅ **Post-boot data unlock** — data members stay locked (`noauto`) until `nixnas-unlock`
  over SSH: one passphrase opens the set serially, imports the ZFS pools, and raises
  `nixnas-storage.target` for the gated mounts + services.
- ✅ **Stick-persisted identity** — machine-id, the running SSH host key and tailscale state
  live on the encrypted store, so the box is trustably reachable before any data unlock.
- ✅ **Rollback** — bounded kept generations + the bootloader menu (guaranteed), plus
  boot-counting (lanzaboote writes/counts the entry down).
- ✅ **Self-update** — `autoUpgrade`, stage-only, never self-reboots.
- ✅ **Hot mode** (`store.location = "hot"`) — the MAIN system boots with `/nix` on an
  external, operator-key-unlocked LUKS device: the initrd asks for YOUR key and proceeds
  only then (CI-proven in QEMU, including the serialised single-entry unlock — two LUKS
  members, one passphrase entry). The stick carries a self-contained rescue; the main
  maintains it (`rescue-maintain`: closure → stick, GC to current+prev, self-signed UKI at
  `EFI/Linux/nixnas-rescue.efi` — a name lanzaboote's ESP GC provably never prunes).
  The hot-store-on-ZFS initrd path (legacy dataset mount + import-after-key) is
  design-verified but first runs on real hardware.

Hardware spikes remaining (a real UEFI box, not the VM): the boot-counting **bless** loop
(auto-clear on a good boot; the manual menu is the fallback meanwhile), the firmware setup
password, and the TPM2-NV anti-rollback counter. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §9.

## License

[Apache-2.0](LICENSE)

Contributions are accepted under the same license.
