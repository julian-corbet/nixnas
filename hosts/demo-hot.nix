# nixnas — a HOT-mode variant of the demo, for CI validation of the hot boot path.
#
# It flips ./hosts/demo to store.location = "hot" with placeholder (RFC-style) devices, so
# `nix build .#nixosConfigurations.demo-hot...toplevel` proves modules/store/location.nix +
# the hot wiring EVALUATE and BUILD into a valid system (the /nix- and /-on-external-device
# fileSystems entries, the initrd operator-key LUKS unlock, no auto). It uses fsType = "ext4"
# for BOTH the store and the root to keep this core check off the ZFS-in-initrd path (a zfs
# variant is exercised by demo-hot-zfs.nix). rescue.enable is OFF here: the keyless demo has
# no Secure Boot db key to sign a rescue UKI with, and the rescue itself is just a usb nixnas
# (already covered by the usb boot-test). See docs/HOT-MODE.md.
{ lib, ... }:
{
  nixnas.store.location = "hot";
  nixnas.store.hot = {
    device = "/dev/mapper/nixstore-demo";
    fsType = "ext4";
    # by-partlabel so the QEMU integration test (test/hot-boot-test.sh) can present matching
    # partitions regardless of the virtual disk's by-id. TWO members: the second carries no
    # filesystem — it exists to PROVE the serialised single-entry unlock (the first member
    # prompts; the second must open silently from the kernel-keyring cache; the test feeds
    # the passphrase exactly once and the boot must still complete).
    unlock = {
      nixstore-demo  = "/dev/disk/by-partlabel/nixstore-demo";
      nixstore-demo2 = "/dev/disk/by-partlabel/nixstore-demo2";
    };
  };
  # The persistent root (REQUIRED — no default; see modules/store/location.nix). A separate
  # LUKS member from the store's, by-partlabel for the same QEMU fixture reasons above.
  nixnas.store.root = {
    device = "/dev/mapper/nixroot-demo";
    fsType = "ext4";
    unlock.nixroot-demo = "/dev/disk/by-partlabel/nixroot-demo";
  };
  nixnas.rescue.enable = false;

  # Hot mode enters the store key in the initrd — keep remote-unlock (initrd-SSH) on.
  nixnas.boot.remoteUnlock.enable = true;

  # ./hosts/demo sets these for the usb-mode demo (Tier-1 identity persistence around ITS
  # tmpfs root). Hot mode's root is a real persistent filesystem — these are usb-mode-only
  # concepts and location.nix REFUSES a hot-mode host that still sets either non-empty, so
  # clear both here rather than let the inherited usb-mode values fail this build.
  nixnas.persist.overlayClients = lib.mkForce [ ];
  nixnas.persist.explicitlyEphemeral = lib.mkForce [ ];
}
