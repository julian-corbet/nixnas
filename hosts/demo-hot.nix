# nixnas — a HOT-mode variant of the demo, for CI validation of the hot boot path.
#
# It flips ./hosts/demo to store.location = "hot" with placeholder (RFC-style) devices, so
# `nix build .#nixosConfigurations.demo-hot...toplevel` proves modules/store/location.nix +
# the hot wiring EVALUATE and BUILD into a valid system (the /nix-on-external-device
# fileSystems entry, the initrd operator-key LUKS unlock, no auto). It uses fsType = "ext4"
# to keep this core check off the ZFS-in-initrd path (a zfs variant is exercised on the real
# host). rescue.enable is OFF here: the keyless demo has no Secure Boot db key to sign a
# rescue UKI with, and the rescue itself is just a usb nixnas (already covered by the usb
# boot-test). See docs/HOT-MODE.md.
{ ... }:
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
  nixnas.rescue.enable = false;

  # Hot mode enters the store key in the initrd — keep remote-unlock (initrd-SSH) on.
  nixnas.boot.remoteUnlock.enable = true;
}
