# nixnas

Boot **your own** declarative NixOS from a USB stick (8 GB+) into RAM — with the whole
boot chain hardened, self-update and rollback built in, and your existing storage
connected. nixnas is the appliance mechanism (boot, crypto, the on-stick store, the
kernel); the workloads are plain NixOS you bring. A local TUI writes your signed image.
Built to be adopted (and contributed to) by others, not just one machine.

- **Boots from a USB stick into RAM** — the root is a tmpfs (impermanence); only `/nix`
  and the ESP persist, and the booted closure is warmed into a compressed page cache, so
  the slow stick is spared after boot. (This is "run from RAM" done right — not
  `copytoram`, which doesn't compose with self-update.)
- **Multiple signed versions, rollback**: each past generation stays bootable as its own
  signed UKI; the bootloader menu is the guaranteed manual rollback, and boot-counting
  adds automatic fallback on top.
- **Survives storage trouble**: the OS is independent of your data storage — the box boots
  even if a disk is degraded or missing (non-fatal import).
- **Encrypted at rest**: the on-stick store is LUKS2 + f2fs (zstd-compressed); a single
  passphrase is the TPM2 PIN and unlocks your storage too — one prompt. Only the stick binds
  to the TPM; your data takes a plain passphrase keyslot, so a disk pulled into another
  machine still opens — no specific box's TPM required.
- **Bring your own storage**: nixnas imports + unlocks whatever you already use — any Linux
  filesystem and encryption — and never creates, formats, or destroys it.
- **Kind to the stick**: logs, `/tmp`, coredumps and swap live in RAM, so the USB takes ~no
  writes except updates — measured at **60 KiB** for ~100 MiB of log+file activity. Cheap
  sticks don't wear out. The OS runs from RAM; the heavy state (container images, data) lives
  on your encrypted storage, never the stick.
- **Evil-Maid hardened**: UEFI Secure Boot with *your own* keys (Microsoft keys not
  enrolled), signed Unified Kernel Images, and LUKS bound to TPM2 + PIN. *(Roadmap: a
  dm-verity/AEAD store hash sealed into the signed UKI.)*
- **Headless**: ships sshd + Tailscale, and unlocks remotely — the store's PIN prompt is
  reached over SSH **in the initrd** (no console needed).
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

A small **Rust TUI** (`tui/`) runs the build → sign → seal → escrow → flash pipeline
**locally**, on a trusted machine that holds your Secure Boot keys — the image is
personalised *and* self-signed, so it cannot be built generically or remotely.

See [`docs/SCOPE.md`](docs/SCOPE.md) (what nixnas is / is not),
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (the decided design), and
[`docs/REPO-LAYOUT.md`](docs/REPO-LAYOUT.md).

## Status

The full decided model boots end-to-end, built locally and validated in a QEMU/OVMF/swtpm
VM (`test/`):

- ✅ CachyOS kernel (x86-64-v3 + ThinLTO, `zfs_cachyos`) + impermanence (tmpfs root) +
  the LUKS2 **f2fs zstd:22** store, all from one disko-built image.
- ✅ **Secure Boot** via lanzaboote (operator-owned keys, signed UKIs).
- ✅ **TPM2 + PIN** store unlock (strict every-boot default), passphrase recovery keyslot,
  first-boot `nixnas-enroll-tpm2` helper.
- ✅ **Headless remote unlock** — initrd-SSH brings the NIC up and hands the passphrase to
  the boot in the initrd (validated unlocking the box entirely over the network).
- ✅ **Rollback** — bounded kept generations + the bootloader menu (guaranteed), plus
  boot-counting (lanzaboote writes/counts the entry down).
- ✅ **Self-update** — `autoUpgrade`, stage-only, never self-reboots.

Hardware spikes remaining (a real UEFI box, not the VM): the boot-counting **bless** loop
(auto-clear on a good boot; the manual menu is the fallback meanwhile), the firmware setup
password, and the TPM2-NV anti-rollback counter. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §9.

## License

[Apache-2.0](LICENSE). Copyright 2026 Julian Corbet.

The explicit patent grant matters here: the core touches TPM2, Secure Boot and
measured boot. Contributions are accepted under the same license.
