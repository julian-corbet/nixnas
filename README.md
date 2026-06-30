# nixnas

A fully declarative, RAM-resident NixOS appliance — a **distribution for the
self-hosted-NAS use-case** that brings the Unraid operating model to NixOS, built to
be adopted (and contributed to) by others, not just one machine.

- **Boots from a USB stick** and copies itself entirely into RAM (`copytoram`) — the
  stick is spared and only touched on updates.
- **Multiple signed versions, automatic rollback**: several independent signed
  read-only OS versions live on the stick; systemd-boot lists them; a version that
  fails its health check rolls back to the previous one.
- **Survives storage trouble**: the OS lives in RAM, fully independent of the data
  pools — the box boots even if a pool is degraded or missing.
- **Encrypted at rest**: every data disk is LUKS, with the filesystem directly on the
  decrypted mapper; a single passphrase unlocks everything at boot.
- **Evil-Maid hardened**: UEFI Secure Boot with *your own* keys, signed Unified Kernel
  Images, a dm-verity-protected root, a firmware setup password, and LUKS bound to
  TPM2 + PIN — a tampered boot chain can neither boot nor surrender the disk key.
- **Hands-off**: everything except the one boot passphrase is automated — build, sign,
  seal, roll out, recovery-key escrow, rollback. *If you have to think about it,
  something has gone wrong.*

## What nixnas is — and is not

nixnas is the **appliance mechanism**: it turns any `nixosConfiguration` into a
bootable, RAM-resident, encrypted, rollback-safe USB stick. The **workloads** a
particular box runs — k3s, containers, VMs, Samba/NFS, GPU — are **plain NixOS that
*you* declare**, in the same host, alongside `imports = [ nixnas.nixosModules.nixnas ]`.
nixnas builds + signs + flashes whatever closure you hand it; it does not own or know
about your k3s. See [`docs/SCOPE.md`](docs/SCOPE.md).

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

Design decided — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). v0 boots in a VM;
multi-version slots + Secure Boot signing next.

## License

[Apache-2.0](LICENSE). Copyright 2026 Julian Corbet.

The explicit patent grant matters here: the core touches TPM2, Secure Boot and
measured boot. Contributions are accepted under the same license.
