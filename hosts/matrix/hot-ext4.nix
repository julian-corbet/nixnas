# nixnas — matrix variant: hot mode, LUKS+ext4, no ZFS anywhere.
#
# Proves that store.hot.fsType = "ext4" keeps ZFS entirely out of the initrd.
# The critical invariant is in modules/store/location.nix:
#
#   (lib.mkIf (hot.fsType == "zfs") {
#     boot.initrd.supportedFilesystems = [ "zfs" ];
#     ...
#   })
#
# When fsType = "ext4" that block is inactive, so boot.initrd.supportedFilesystems
# carries no "zfs" entry and no ZFS kernel modules are pulled into the initrd closure.
# The test script (test/matrix-eval-test.sh) asserts this via `nix eval`.
#
# Single LUKS member with a stable by-partlabel path — the simplest possible unlock
# config (one member, no serialisation needed).  rescue.enable = false matches the
# hot-boot CI posture (the keyless demo cannot sign a rescue UKI).
#
# store.root ALSO stays ext4 here (not zfs) — the invariant under test is that fsType =
# "ext4" on BOTH the store and the root keeps ZFS out of the initrd entirely; a zfs root
# would defeat the very thing this variant exists to prove.
{ lib, ... }:
{
  nixnas.store.location = "hot";
  nixnas.store.hot = {
    device  = "/dev/mapper/nixstore-matrix";
    fsType  = "ext4";
    unlock.nixstore-matrix = "/dev/disk/by-partlabel/nixstore-matrix";
  };
  nixnas.store.root = {
    device  = "/dev/mapper/nixroot-matrix";
    fsType  = "ext4";
    unlock.nixroot-matrix = "/dev/disk/by-partlabel/nixroot-matrix";
  };
  nixnas.rescue.enable = false;
  # hot mode enters the store key in the initrd — remote-unlock keeps initrd-SSH on.
  nixnas.boot.remoteUnlock.enable = true;

  # ./hosts/demo (matrixBase) sets these for the usb-mode demo — usb-mode-only concepts
  # that location.nix REFUSES to see non-empty in hot mode. Clear the inherited values.
  nixnas.persist.overlayClients = lib.mkForce [ ];
  nixnas.persist.explicitlyEphemeral = lib.mkForce [ ];
}
