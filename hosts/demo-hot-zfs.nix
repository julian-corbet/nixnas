# nixnas — a ZFS HOT-mode variant of the demo, for CI validation of the ZFS hot boot path.
#
# Like demo-hot.nix but with fsType = "zfs", zpool "qapool", and device "qapool/system/nix".
# The test disk carries TWO LUKS members (single passphrase entry proof) forming a striped
# ZFS pool: qapool-luks0 prompts in the initrd; qapool-luks1 opens silently from the
# kernel-keyring cache — the test feeder in test/hot-boot-zfs-test.sh answers EXACTLY ONCE.
#
# After both members are unlocked the initrd imports qapool from /dev/mapper (location.nix
# orders zfs-import-qapool after cryptsetup.target, so the import never races the decrypt),
# then mounts qapool/system/nix (mountpoint=legacy) at /nix and switch-roots into the full
# system. ZFS native-encryption is NOT used (LUKS does the crypto); that is the supported
# hot-mode contract: one passphrase, one prompt, ZFS sees plaintext block devices.
#
# rescue.enable is OFF: the keyless demo has no Secure Boot db key to sign a rescue UKI with,
# and the rescue story is already covered by test/seal-2boot-test.sh. See docs/HOT-MODE.md.
{ ... }:
{
  nixnas.store.location = "hot";
  nixnas.store.hot = {
    device = "qapool/system/nix";
    fsType = "zfs";
    zpool = "qapool";
    # TWO LUKS members — both carry pool data (a stripe; this is a CI test pool, not a
    # production mirror). The single passphrase entry proof: the initrd serialises the
    # unlock (location.nix drop-ins), so luks0 prompts once and the kernel keyring covers
    # luks1 — the test feeder must NOT need to answer a second time.
    unlock = {
      qapool-luks0 = "/dev/disk/by-partlabel/qapool-luks0";
      qapool-luks1 = "/dev/disk/by-partlabel/qapool-luks1";
    };
  };
  nixnas.rescue.enable = false;

  # Hot mode enters the store key in the initrd — keep remote-unlock (initrd-SSH) on.
  nixnas.boot.remoteUnlock.enable = true;
}
