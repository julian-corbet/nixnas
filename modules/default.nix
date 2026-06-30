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
    ./boot/image.nix         # nix-native image (image.repart verityStore): verity /usr + UKI [v0]
    # ./boot/{secureboot,ab-slots,remote-unlock}.nix   # (next: signing, copytoram, A/B)
    ./crypto/tpm2.nix        # TPM2 device access (stage-2 unlock); enrollment is provision-time
    # ./crypto/{luks,recovery-escrow}.nix   # provision-time helpers (next)
    ./storage/zfs-pools.nix  # IMPORT-ONLY pools (never create/format), stage-2 LUKS unlock, non-fatal import
    # ./storage/{smr-disks,shares}.nix   # SMR unlock+mount, samba/nfs (next)
    ./appliance/base.nix     # stable identity (hostName)
    # NOTE: k3s / GPU / nftables / monitoring / shares / the Arch LXC / the Office VM /
    # the apps are NOT nixnas — they are plain NixOS the operator declares in their own
    # repo alongside `imports = [ nixnas ]`. See docs/SCOPE.md.
    # ./appliance/hardening.nix          # firmware-password expectation, read-only-root (next)
  ];
}
