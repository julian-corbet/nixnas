# nixnas — SCOPE.md

nixnas is plain NixOS plus **exactly two capabilities, and nothing else**. This document nails what is in and what is out, so the core never re-absorbs the operator's infrastructure.

## What nixnas IS

1. **A USB-install mechanism.** It turns an evaluated `nixosConfiguration` into a bootable ~8 GB USB appliance: a RAM-resident OS (`copytoram`), **multiple** signed read-only OS versions with automatic rollback, dm-verity integrity, UEFI Secure Boot with the operator's *own* keys, and the on-stick GPT layout.
2. **A flake-native workflow.** `lib.mkImage`, the `nixnas.*` option surface, and a small Rust TUI (`tui/`) that builds + signs + seals + escrows + flashes the stick **locally** on the machine that holds the signing keys.

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
  storage.pools.hot = { name = "hot"; luksDevices = [ "/dev/disk/by-id/…" ]; };
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

Under `modules/`:

| Module | Role |
|---|---|
| `options.nix` | The `nixnas.*` public API (parameters only, no literals). |
| `boot/image.nix` | nix-native USB image (`image.repart` verity store): read-only erofs `/usr` + UKI. **v0 here.** |
| `boot/{secureboot,slots,remote-unlock}.nix` | *(next)* SB signing, copytoram, N-slot boot-counting/rollback, stage-2 unlock. |
| `crypto/tpm2.nix` | TPM2 device access for stage-2 unlock. |
| `crypto/{luks,recovery-escrow}.nix` | *(provision-time)* enrollment, recovery keyslot + Vaultwarden escrow. |
| `storage/zfs-pools.nix` | **Import-only** pool unlock + non-fatal import. |
| `storage/{smr-disks,shares}.nix` | *(next)* unlock+mount existing SMR filesystems. (`shares` belongs to the operator — see boundary note.) |
| `appliance/base.nix` | Stable host identity. |

**Option surface (`nixnas.*`):** `enable`, `hostName`, `boot.{tries,secureBoot,usb}`, `crypto.{tpm2,recovery}`, `storage.{pools,smrDisks}`, `tailscale` (the management / remote-unlock plane only).

**Boundary cleanup (load-bearing):** `modules/options.nix` *today* also declares `compute.{k3s,archContainer,gpu,officeVm}` (with `gpu.renderGid`, `k3s.tokenSops`, `officeVm.{zvol,xml}`, etc.). By this scope those are **operator infra and must move out of the nixnas option surface** into the operator's own host config. Keeping them in nixnas re-imports the very split this project rejects. `storage.{pools,smrDisks}` and `tailscale` **stay** — they are the unlock + non-fatal-import + remote-unlock *mechanism*, parameterised by operator-supplied serials.

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
  crypto.recovery.vaultwardenUrl = "https://vault.example";
  storage.pools.hot  = { name = "hot";  luksDevices = [ "/dev/disk/by-id/…" ]; };
  storage.pools.cold = { name = "cold"; luksDevices = [ "/dev/disk/by-id/…" ]; };
  tailscale.enable = true;
};
```

The whole `toplevel` closure — nixnas mechanism **plus** the operator's k3s/samba/GPU — is what nixnas bakes into the verity `/usr`. nixnas's job begins and ends at: *build + sign + flash that closure, and bring it up encrypted, RAM-resident, and rollback-safe.*
