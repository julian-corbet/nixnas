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
    # ./crypto         # LUKS single-passphrase fan-out, TPM2 + PIN, recovery-key escrow
    # ./storage        # fresh ZFS pools, explicit placement, SMR disks, shares
    # ./compute        # k3s, podman/quadlets, Incus Arch container, GPU, the Office VM
    # ./network        # single nftables backend, per-bridge subnets
    # ./observability  # smartd + exporters
    # ./appliance      # tailscale, hardening
  ];
}
