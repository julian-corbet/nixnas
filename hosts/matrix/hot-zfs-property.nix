# nixnas — matrix variant: hot mode, ZFS, MIXED mount shapes.
#
# Proves the two root-on-ZFS mount shapes are wired independently and correctly, which is
# the whole reason `store.{hot,root}.zfsMountpoint` exists as an option rather than
# something the module infers.
#
# The invariant under test, from modules/store/location.nix:
#
#   // lib.optionalAttrs (root.fsType == "zfs" && root.zfsMountpoint == "property") {
#     options = [ "zfsutil" ];
#   }
#
# WHY IT MUST BE DECLARED, NOT DETECTED: a dataset's mountpoint is runtime state on an
# imported pool — no evaluation can see it. And the two shapes are mutually exclusive at
# mount(8): `-o zfsutil` against a mountpoint=legacy dataset is REFUSED outright, and a
# property-mountpoint dataset cannot be mounted without it. Guessing wrong does not
# degrade gracefully; it fails the boot.
#
# THE MIX IS DELIBERATE. Root is "property" (a real mountpoint plus canmount=noauto, so an
# imported pool is self-describing — `zfs list` shows where each dataset belongs) while
# /nix stays "legacy". Mixing is a legitimate operator choice, so the test asserts BOTH
# directions from one config: zfsutil present on "/", absent on "/nix". A variant with the
# same shape on both would pass even if the module ignored the option and applied one
# blanket rule.
#
# Note which half is load-bearing: the mount TARGET always comes from the fileSystems
# declaration, never from the dataset's mountpoint property — `zfsutil` only makes
# mount.zfs fold dataset PROPERTIES into the mount options. A "property" dataset is
# self-describing, not self-mounting.
{ lib, ... }:
{
  nixnas.store.location = "hot";
  nixnas.store.hot = {
    device = "qapool/system/nix";
    fsType = "zfs";
    zpool = "qapool";
    # Left at the "legacy" default on purpose — see the header. Stated explicitly rather
    # than relied upon, so the assertion below tests the module's behaviour and not the
    # option's default.
    zfsMountpoint = "legacy";
    unlock.qapool-luks0 = "/dev/disk/by-partlabel/qapool-luks0";
  };
  # A SIBLING dataset on the SAME pool — no unlock members of its own (the initrd already
  # opens qapool-luks0 above, and location.nix imports "qapool" exactly once for both).
  nixnas.store.root = {
    device = "qapool/system/root";
    fsType = "zfs";
    zpool = "qapool";
    zfsMountpoint = "property";
  };

  # hot mode enters the store key in the initrd — remote-unlock keeps initrd-SSH on.
  nixnas.boot.remoteUnlock.enable = true;

  # ./hosts/demo (matrixBase) sets these for the usb-mode demo — usb-mode-only concepts
  # that location.nix REFUSES to see non-empty in hot mode. Clear the inherited values.
  nixnas.persist.overlayClients = lib.mkForce [ ];
  nixnas.persist.explicitlyEphemeral = lib.mkForce [ ];
}
