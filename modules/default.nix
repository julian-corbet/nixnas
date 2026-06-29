# nixnas — the reusable appliance module.
#
# Importing this module gives a host the full `nixnas.*` option surface
# (see ./options.nix). The behaviour modules (boot/crypto/storage/compute/…)
# are wired in incrementally; this milestone ships the public API + a demo so the
# core is reviewable and evaluates standalone, before the boot chain is implemented.
{ ... }:
{
  imports = [
    ./options.nix

    # Implementation modules — added in subsequent milestones:
    # ./boot           # ram-root (copytoram + verity), signed UKIs, A/B + rollback, remote-unlock
    ./crypto/tpm2.nix        # TPM2 device access (stage-2 unlock); enrollment is provision-time
    # ./crypto/{luks,recovery-escrow}.nix   # provision-time helpers (next)
    ./storage/zfs-pools.nix  # IMPORT-ONLY pools (never create/format), stage-2 LUKS unlock, non-fatal import
    # ./storage/{smr-disks,shares}.nix   # SMR unlock+mount, samba/nfs (next)
    ./compute/gpu.nix        # amdgpu + ROCm, render-GID pinning
    ./compute/k3s.nix        # native declarative k3s (server scaffold)
    # ./compute/{podman,arch-container,libvirt}.nix   # (next)
    ./network/nftables.nix   # single nftables backend, ip_forward
    ./observability/monitoring.nix   # smartd + host-level prometheus exporters
    ./appliance/base.nix     # stable identity (hostName) + Tailscale
    # ./appliance/hardening.nix          # firmware-password expectation, read-only-root (next)
  ];
}
