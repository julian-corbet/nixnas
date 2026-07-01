# nixnas — SCOPE.md

nixnas is plain NixOS plus **exactly two capabilities, and nothing else**. This document nails what is in and what is out, so the core never re-absorbs the operator's infrastructure.

## What nixnas IS

1. **A USB-install mechanism.** It turns an evaluated `nixosConfiguration` into a bootable ~8 GB USB appliance: a RAM-resident OS via **impermanence** (tmpfs root; only `/nix` + the ESP persist — not `copytoram`), **multiple** signed generations with rollback, the LUKS2 f2fs-zstd on-stick store, and UEFI Secure Boot (lanzaboote) with the operator's *own* keys. *(dm-verity store integrity is roadmap.)*
2. **A flake-native workflow.** `lib.mkImage`, the `nixnas.*` option surface, and a small Rust TUI (`tui/`) that builds + flashes the stick **locally** on the machine that holds the signing keys (it injects the LUKS passphrase at build time and shreds it).

Plus the generic capability those two imply:

3. **An encrypted, robust, RAM-booted appliance.** Single-passphrase LUKS unlock that *is* the TPM2 PIN, recovery-key escrow, and **non-fatal import** of the operator's already-built encrypted data pools.

A host becomes a nixnas appliance by importing one module and supplying parameters:

```nix
imports = [ nixnas.nixosModules.nixnas ];
nixnas = {
  enable = true;
  hostName = "nas";
  boot.secureBoot.enable = true;
  crypto.tpm2.enable = true;
  storage.unlock = { hot0 = "/dev/disk/by-id/…"; };   # LUKS members; mount natively (fileSystems)
  storage.zfsPools = [ "hot" ];                        # optional: import this ZFS pool
};
```

## What nixnas is NOT

Everything that makes a *particular* box useful is **plain NixOS the operator declares in their own repo** (e.g. `infra`), in the same host alongside `imports = [ nixnas ]`:

- **Compute** — k3s, containerd, podman/quadlets, the Arch/Incus system container, the Office VM (`virtualisation.libvirtd`/NixVirt), GPU passthrough + ROCm (`hardware.amdgpu`).
- **Sharing/serving** — `services.samba`, `services.nfs`, every application workload.
- **Policy/observability** — the nftables firewall, Tailscale ACLs / app-mesh, monitoring (cockpit/netdata/prometheus), GitOps/Argo.
- **The specific storage** — which disks, which datasets, pool *creation/formatting*, HOT/COLD tiering.

nixnas **builds + flashes whatever declarative config the operator supplies**; it does not own, import, or know about k3s/GPU/shares/apps. It **never creates, formats, or destroys data pools** — it only LUKS-unlocks and imports pools the operator built by hand. The only device nixnas ever partitions is the USB stick. The operator's k3s/samba/etc. ride *inside* the verity image nixnas bakes (which is exactly why the image is multi-GB, not tiny) — but they are the operator's config, not nixnas's responsibility.

## The precise nixnas module list

Under `modules/` (all built + VM-validated unless noted):

| Module | Role |
|---|---|
| `options.nix` | The `nixnas.*` public API (parameters only, no literals). |
| `boot/disk.nix` | disko GPT on the stick: ESP + LUKS2 **f2fs zstd:22** store; tmpfs root. |
| `boot/image.nix` | UEFI + systemd-initrd glue, serial console, the initrd modules. |
| `boot/impermanence.nix` | tmpfs root — only `/nix` + the ESP persist. |
| `boot/kernel.nix` | the CachyOS kernel (`pkgs.cachyosKernels`) + `zfs_cachyos` + lantian cache. |
| `boot/secureboot.nix` | **lanzaboote** Secure Boot: operator-owned PK/KEK/db, signed UKIs. |
| `boot/remote-unlock.nix` | headless store unlock — initrd-SSH; host key TPM-sealed by default. |
| `boot/rollback.nix` | kept generations (`configurationLimit`) + lanzaboote boot-counting. |
| `crypto/tpm2.nix` | TPM2+PIN store unlock (crypttab) + first-boot `nixnas-enroll-tpm2`. |
| `crypto/recovery-escrow.nix` | break-glass recovery keyslot escrowed to Vaultwarden (hub tool + box status). |
| `storage/connect.nix` | Stage-2 LUKS unlock (`storage.unlock`) + optional non-fatal ZFS import. Mounting is native. |
| `appliance/base.nix` | Stable host identity + Tailscale. |
| `appliance/ssh.nix` | Headless admin sshd (key-only root). |
| `appliance/auto-upgrade.nix` | Self-update: stage-only, never self-reboot. |
| `appliance/optimizations.nix` | Appliance defaults: zram, journald→RAM, no swap, store.preload. |

**Option surface (`nixnas.*`):** `enable`, `hostName`, `admin.authorizedKeys`, `boot.{tries,keepGenerations,secureBoot,remoteUnlock,usb}`, `kernel.*`, `crypto.{tpm2,recovery}`, `zfs.source`, `store.{preload,persistLogs}`, `storage.{unlock,zfsPools}`, `tailscale`, `autoUpgrade`. Mounting itself is native NixOS (`fileSystems`, `boot.zfs`), not a nixnas option.

**Thin by construction.** The option surface carries NO `compute.*` (k3s/GPU/VMs) — those were deliberately kept out. nixnas owns boot / crypto / the USB store / kernel packaging only; everything else is the operator's plain NixOS alongside the import (see "What nixnas is NOT").

## The nixnas ↔ operator boundary (concrete)

The operator's `host.nix`:

```nix
imports = [
  nixnas.nixosModules.nixnas   # the appliance MECHANISM
  ./k3s.nix                    # services.k3s            — operator's
  ./gpu.nix                    # hardware.amdgpu + ROCm  — operator's
  ./shares.nix                 # services.samba / nfs    — operator's
  ./office-vm.nix              # virtualisation.libvirtd — operator's
];

nixnas = {
  enable = true;
  hostName = "nas";
  boot.secureBoot = { enable = true; keysSops = ./secrets/sb-db.key; };
  crypto.tpm2.enable = true;
  storage.unlock   = { hot0 = "/dev/disk/by-id/…"; cold0 = "/dev/disk/by-id/…"; };
  storage.zfsPools = [ "hot" "cold" ];
  tailscale.enable = true;
};
# … plus native fileSystems for the mounts, and your workloads as plain NixOS.
```

The whole `toplevel` closure — nixnas mechanism **plus** the operator's k3s/samba/GPU — is what nixnas bakes into the LUKS f2fs `/nix` store as generation 1. nixnas's job begins and ends at: *build + sign + flash that closure, and bring it up encrypted, RAM-resident (impermanence), and rollback-safe.*
