# nixnas — the CachyOS kernel (tuned), from the xddxdd/nix-cachyos-kernel flake.
#
# The host/flake applies `nix-cachyos-kernel.overlays.pinned` (which adds
# `pkgs.cachyosKernels`); this module just selects the variant from `nixnas.kernel.*`.
# ZFS (`zfs_cachyos`) is wired with the data pools in a later increment. Failsafe is
# structural (rollback + scrub/snapshot/backup), not the kernel/ZFS choice — see docs/KERNEL.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  # The flake exposes pre-built variants as attributes named
  #   linuxPackages-cachyos-<variant>[-lto][-<march>]
  # (eevdf is the default cpusched, baked into every variant).
  ltoSuffix = lib.optionalString (cfg.kernel.lto != "none") "-lto";
  marchSuffix = lib.optionalString (cfg.kernel.march != "x86_64-v1") "-${cfg.kernel.march}";
  kernelAttr = "linuxPackages-cachyos-${cfg.kernel.variant}${ltoSuffix}${marchSuffix}";
in
{
  config = lib.mkIf cfg.enable {
    boot.kernelPackages = pkgs.cachyosKernels.${kernelAttr};

    # The running system pulls the CachyOS kernel + its updates from the maintainer's cache,
    # so autoUpgrade never recompiles it on the box.
    nix.settings.substituters = [ "https://attic.xuyh0120.win/lantian" ];
    nix.settings.trusted-public-keys = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
  };
}
