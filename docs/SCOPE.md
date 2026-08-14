# nixnas — SCOPE.md

nixnas is the appliance/storage-geometry and runtime layer for a USB-shaped
NixOS system. This document separates that stable ownership from delivery and
boot mechanisms that now have dedicated owners.

## What nixnas IS

1. **An appliance payload and storage geometry.** It turns an evaluated
   `nixosConfiguration` into the declared USB disk payload: impermanent root,
   encrypted persistent store, and appliance runtime.
2. **Payload production.** Its flake and TUI can produce the appliance payload
   while keeping injected key material out of the Nix store. Nixboot supplies
   the booted kernel/initrd and boot-medium artifact. The TUI still composes
   and flashes the result today; selecting and writing a deployment target is
   an existing overlap to remove in favor of nixdeploy.

Plus the generic capability those two imply:

3. **An encrypted, robust, RAM-booted runtime.** A passphrase-only OS store and
   data members, recovery tooling, and non-fatal connection of
   the operator's already-built encrypted data pools.

Nixboot owns loader selection, UKIs, Secure Boot integration, boot-generation
retention/counting and boot verification. Nixdeploy is the sole owner of build
and update triggers, publication, activation/rollback/health outcomes, primary
and nixrescue materialisation, and any remote image upload/register/reimage.

A host becomes a nixnas appliance by importing one module and supplying parameters:

```nix
imports = [ nixnas.nixosModules.nixnas ];
nixnas = {
  enable = true;
  hostName = "nas";
  boot.secureBoot.enable = true;
  storage.unlock = { tank0 = "/dev/disk/by-id/…"; };   # LUKS members; mount natively (fileSystems)
  storage.zfsPools = [ "hot" ];                        # optional: import this ZFS pool
};
```

## What nixnas is NOT

Everything that makes a *particular* box useful is **plain NixOS the operator declares in their own repo** (e.g. `infra`), in the same host alongside `imports = [ nixnas ]`:

- **Compute** — k3s, containerd, podman/quadlets, the Arch/Incus system container, the Office VM (`virtualisation.libvirtd`/NixVirt), GPU passthrough + ROCm (`hardware.amdgpu`).
- **Sharing/serving** — `services.samba`, `services.nfs`, every application workload.
- **Policy/observability** — the nftables firewall, Tailscale ACLs / app-mesh, monitoring (cockpit/netdata/prometheus), GitOps/Argo.
- **The specific storage** — which disks, which datasets, pool *creation/formatting*, HOT/COLD tiering.

nixnas **builds + flashes whatever declarative config the operator supplies**; it does not own, import, or know about k3s/GPU/shares/apps. It **never creates, formats, or destroys data pools** — it only LUKS-unlocks and imports pools the operator built by hand. The only device nixnas ever partitions is the USB stick. The operator's k3s/samba/etc. ride *inside* the image nixnas bakes (which is exactly why the image is multi-GB, not tiny) — but they are the operator's config, not nixnas's responsibility.

## The precise nixnas module list

Under `modules/` (all built + VM-validated unless noted):

| Module | Role |
|---|---|
| `options.nix` | The `nixnas.*` public API (parameters only, no literals). |
| `boot/disk.nix` | disko GPT on the stick: ESP + LUKS2 **f2fs zstd:22** store; tmpfs root. |
| `boot/image.nix` | Early-boot geometry the appliance must supply; boot stance is delegated to nixboot. |
| `boot/nixboot.nix` | Bridge from appliance facts to nixboot's boot-owned option surface. |
| `boot/impermanence.nix` | tmpfs root — only `/nix` + the ESP persist. |
| `boot/kernel.nix` | Current appliance-local kernel selection; its requirements remain nixnas facts while selection/packaging of the booted kernel migrates to nixboot. |
| `crypto/recovery-escrow.nix` | break-glass recovery keyslot escrowed to Vaultwarden (hub tool + box status). |
| `storage/connect.nix` | POST-boot data unlock: `nixnas-unlock` + `nixnas-storage.target` (serial one-passphrase LUKS opens, per-pool ZFS import). Mounting is native. |
| `appliance/base.nix` | Stable host identity + Tailscale. |
| `appliance/identity.nix` | **`usb` mode only.** machine-id, the running SSH host key, `persist.overlayClients` (tailscale, netbird, …) state — persisted on the encrypted stick (`/nix/persist`). Inert in `hot` mode: its MAIN has an ordinary persistent root, so nothing needs routing around a tmpfs one. |
| `appliance/persist-enforce.nix` | **`usb` mode only.** Build-time gate: every `StateDirectory`-bearing systemd service must be persisted (any `fileSystems` entry) or listed in `persist.explicitlyEphemeral` — else the build fails. Inert in `hot` mode (nothing to enforce against a real root). |
| `appliance/ssh.nix` | Headless admin sshd (key-only root). |
| `appliance/auto-upgrade.nix` | Deprecated self-update trigger overlap; functional until removed in favor of nixdeploy. |
| `appliance/switch.nix` | Current activation wrapper; functional, marked for migration to nixdeploy outcomes. |
| `appliance/optimizations.nix` | Appliance defaults: journald→RAM, no disk swap, store.preload. Composes **nixram** for the memory subsystem (zram/zswap/vm sysctls/oomd) — each host declares `nixram.level`. |

**Option surface (`nixnas.*`):** `enable`, `hostName`, `admin.authorizedKeys`, `boot.{tries,keepGenerations,secureBoot,remoteUnlock,usb}`, `kernel.*`, `crypto.recovery`, `zfs.source`, `store.{preload,persistLogs,extraPackages}`, `storage.{unlock,zfsPools}`, `persist.{overlayClients,explicitlyEphemeral}`, `tailscale`, `autoUpgrade`. Mounting itself is native NixOS (`fileSystems`, `boot.zfs`), not a nixnas option.

**Thin by construction.** The option surface carries NO `compute.*`
(k3s/GPU/VMs). Nixnas owns appliance/storage geometry, crypto integration,
the USB store and runtime only. Nixboot owns the booted kernel/initrd and the
rest of boot; nixdeploy
owns delivery. Everything else is the operator's plain NixOS.

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
  storage.unlock   = { tank0 = "/dev/disk/by-id/…"; bulk0 = "/dev/disk/by-id/…"; };
  storage.zfsPools = [ "hot" "bulk" ];
  tailscale.enable = true;
  persist.overlayClients = [ "tailscale" ];
};
# … plus native fileSystems for the mounts, and your workloads as plain NixOS.
```

The whole `toplevel` closure — nixnas mechanism **plus** the operator's
workloads — is the primary artifact. Nixnas produces and configures it;
nixboot supplies its boot representation; nixdeploy materialises and updates
the primary and nixrescue roles and reports their outcomes.
