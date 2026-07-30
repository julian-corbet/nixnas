# nixnas — the CachyOS kernel (tuned), from the xddxdd/nix-cachyos-kernel flake.
#
# The host/flake applies `nix-cachyos-kernel.overlays.pinned` (which adds
# `pkgs.cachyosKernels`); this module just selects the variant from `nixnas.kernel.*`.
# ZFS (`zfs_cachyos`) is wired with the data pools in a later increment. Failsafe is
# structural (rollback + scrub/snapshot/backup), not the kernel/ZFS choice — see docs/KERNEL.md.
#
# THE f2fs KERNEL FLOOR — asserted here, not merely documented. docs/STORAGE.md §5 has long
# argued that the ZFS-driven kernel cap "puts us in the safe zone automatically" for f2fs's
# release/reserve accounting, and that argument was true, but nothing in this module tree ever
# actually checked it: a host that disabled ZFS, or overrode `boot.kernelPackages` directly,
# could silently end up on a kernel below the floor with no build-time signal at all. Now that
# the floor itself is owned by nixfs (lib/catalogue.nix, filesystems.f2fs.compression --
# `requiredKernel`, byte-for-byte the same fact nixvault enforces at runtime for its own vault),
# this module is the right place to turn "should be fine" into a real, unavoidable assertion:
# `kernelPackages` above is exactly the derivation `boot.kernelPackages` resolves to, its
# `.kernel.version` is a plain string available at EVAL time (no build needed to read it), and
# this backend genuinely owns `boot.*` — unlike nixvault, which exports to system-manager too
# and has no such surface on that backend, hence its own runtime `uname -r` check instead.
# `nixfsCatalogue` is a plain closure argument, applied by modules/default.nix at import time
# (never `_module.args` — see that file's header for why: a module-argument name is a GLOBAL
# namespace shared with anything else composed alongside this one, and nixvault's own,
# separately-pinned nixfs closed over the exact same argument name, which collided the one time
# a consumer composed both flakes together. Partial application here means this file's own
# `nixfsCatalogue` is a value baked in before the module system ever sees this as a module — it
# never enters `_module.args` at all, so there is nothing left to collide over.
{ nixfsCatalogue }:
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  f2fsRequiredKernel = nixfsCatalogue.filesystems.f2fs.compression.requiredKernel;
  # f2fs is actually used, under this recipe, whenever this host formats the stick's own store
  # with it (`usb` mode, always — modules/boot/disk.nix) or re-mounts a rescue slot with it
  # (`hot` mode with the rescue maintained — modules/appliance/rescue-maintain.nix). A `hot`-mode
  # MAIN's own /nix (modules/store/location.nix) is a separate, operator-chosen filesystem and is
  # deliberately not covered here — it never applies this compression recipe at all.
  f2fsInUse = cfg.store.location == "usb" || (cfg.store.location == "hot" && cfg.rescue.enable);
  # The flake exposes pre-built variants as attributes named
  #   linuxPackages-cachyos-<variant>[-lto][-<march>]
  # (eevdf is the default cpusched, baked into every variant).
  ltoSuffix = lib.optionalString (cfg.kernel.lto != "none") "-lto";
  marchSuffix = lib.optionalString (cfg.kernel.march != "x86_64-v1") "-${cfg.kernel.march}";
  kernelAttr = "linuxPackages-cachyos-${cfg.kernel.variant}${ltoSuffix}${marchSuffix}";
  # The lantian cache pre-builds only SOME (variant × lto × march) combos. If the requested one
  # is absent, `pkgs.cachyosKernels.${kernelAttr}` throws a cryptic "attribute missing". Fail with
  # an actionable message instead, and make clear a missing combo would force a from-source kernel
  # build on the box — which defeats nixnas's pull-from-cache design.
  kernelPackages = pkgs.cachyosKernels.${kernelAttr} or (throw ''
    nixnas.kernel: no pre-built CachyOS kernel `${kernelAttr}` in the pinned cachyosKernels set.
    The lantian binary cache pre-builds only certain (variant × lto × march) combinations; this one
    is not among them, so nixnas would have to COMPILE the kernel from source on the box — which
    defeats the "pull the kernel from the cache, never recompile" design (docs/KERNEL.md). Pick a
    cache-available march for kernel.variant=${cfg.kernel.variant} (commonly x86_64-v3 / x86_64-v4 /
    zen4; the baseline default is x86_64-v1). NOTE: `x86_64-v2` variants are flagged "no binary
    cache" upstream, and `znver3`/`native` are NOT pre-built — a Zen 3 CPU (e.g. Ryzen 5000) is
    x86_64-v3, Zen 4 is zen4.
  '');
in
{
  config = lib.mkIf cfg.enable {
    boot.kernelPackages = kernelPackages;

    # CachyOS ZFS matches the (>upstream-cap) CachyOS kernel. Set when zfs.source=cachyos;
    # only actually built once a data pool enables ZFS. Safety is structural (rollback +
    # scrub), not the source — see docs/KERNEL.md §5.
    boot.zfs.package = lib.mkIf (cfg.zfs.source == "cachyos") config.boot.kernelPackages.zfs_cachyos;

    # The running system pulls the CachyOS kernel + its updates from the maintainer's cache,
    # so autoUpgrade never recompiles it on the box.
    nix.settings.substituters = [ "https://attic.xuyh0120.win/lantian" ];
    nix.settings.trusted-public-keys = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];

    assertions = lib.optional f2fsInUse {
      assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version f2fsRequiredKernel;
      message = ''
        nixnas: the selected kernel (${config.boot.kernelPackages.kernel.version}, kernel.variant=${cfg.kernel.variant}) is older than the ${f2fsRequiredKernel} floor f2fs's compression release/reserve block accounting needs (nixfs's lib/catalogue.nix, filesystems.f2fs.compression.requiredKernel — see docs/STORAGE.md §5 for the citation trail). This host formats or mounts an f2fs volume under that recipe (store.location = "usb", or a maintained "hot"-mode rescue), so an under-floor kernel would silently mishandle the release pass. Pick a newer kernel.variant/march, or point nixnas.kernel at a kernel that already satisfies this floor.
      '';
    };
  };
}
