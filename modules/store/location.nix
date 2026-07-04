# nixnas — store location: the `hot`-mode MAIN-system boot wiring.
#
# In `hot` mode the MAIN system's /nix lives on the operator's own encrypted storage
# (`store.hot.*`), NOT the stick. This module makes the MAIN system boot from it:
#   * /nix is a fileSystems entry on the hot device, neededForBoot (mounted in stage-1
#     before switch-root, because the whole system executes out of it),
#   * the initrd opens the hot device's LUKS members with the OPERATOR'S key — interactive,
#     over initrd-SSH / console, NEVER TPM auto (the box blocks here until the operator
#     enters it; data stays sealed),
#   * ZFS is pulled into the initrd only when the hot store is a ZFS dataset.
#
# The RESCUE system (the thing actually flashed to the stick) and the disko stick image are
# a separate, usb-mode nixnas derived from this config — see modules/boot/rescue.nix. In
# `usb` mode this module is inert and disk.nix owns /nix on the stick.  See docs/HOT-MODE.md.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  hot = cfg.store.hot;
  isHot = cfg.enable && cfg.store.location == "hot";
  # The pool backing a zfs hot store — explicit, or derived from the dataset name.
  # Falls back to a dummy: attr NAMES eval eagerly even under mkIf, so this must never be
  # null (usb hosts have no hot.device; their "zfs-import--unset-" attr sits behind mkIf false).
  hotPool =
    if hot.zpool != null then hot.zpool
    else if hot.device != null then builtins.head (lib.splitString "/" hot.device)
    else "-unset-";
  unlockNames = lib.attrNames hot.unlock; # attrNames is sorted — a stable chain order
in
{
  config = lib.mkIf isHot (lib.mkMerge [
    {
      assertions = [
        {
          assertion = hot.device != null;
          message = "nixnas.store.location = \"hot\" requires nixnas.store.hot.device (where the MAIN /nix lives).";
        }
        {
          assertion = hot.unlock != { };
          message = "hot mode requires nixnas.store.hot.unlock — the LUKS members the initrd opens with YOUR key.";
        }
        {
          # The whole point: no unattended decrypt. remote-unlock (initrd-SSH) or a console
          # must be present so the operator can actually enter the key in stage-1.
          assertion = cfg.boot.remoteUnlock.enable;
          message = "hot mode enters the store key in the initrd — keep boot.remoteUnlock.enable = true (initrd-SSH), or use a console/IPMI-SOL.";
        }
      ];

      # Impermanence tmpfs root. In usb mode disko's `nodev."/"` provides this; in hot mode
      # disk.nix is off (no stick image for the main), so define the runtime root here.
      fileSystems."/" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=50%" "mode=0755" ];
      };

      # The ESP: the MAIN shares the stick's ESP with the rescue (lanzaboote installs the
      # main's UKIs; rescue-maintain drops EFI/Linux/nixnas-rescue.efi). Mount it by the label
      # disk.nix stamps on the stick ESP, so it's found regardless of device path.
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
        options = [ "umask=0077" "noatime" ];
      };

      # The MAIN system's /nix = the hot device. neededForBoot ⇒ mounted in stage-1.
      # For zfs the dataset MUST be `mountpoint=legacy` (the initrd mounts it with mount(8);
      # a property-managed mountpoint would need `zfsutil` and fights the boot ordering —
      # legacy is the root-on-ZFS convention and the shape nixnas supports).
      fileSystems."/nix" = {
        device = hot.device;
        fsType = hot.fsType;
        neededForBoot = true;
      };

      # Open the hot store's LUKS members in the INITRD with the operator's passphrase —
      # interactive, no TPM enrollment here. systemd-initrd + initrd-SSH surface the prompt;
      # the operator hands the key to the password agent. Each opens at /dev/mapper/<name>.
      boot.initrd.luks.devices = lib.mapAttrs
        (_: dev: { device = dev; })
        hot.unlock;

      # Serialise the member unlocks (same pattern as storage/connect.nix stage-2): the
      # first member prompts, systemd caches the passphrase in the kernel keyring, and
      # every later member finds it and opens silently — ONE entry for the whole set.
      # Without this all members race and queue N password-agent questions in parallel.
      boot.initrd.systemd.services = lib.listToAttrs (lib.imap0
        (i: n: lib.nameValuePair "systemd-cryptsetup@${n}" {
          overrideStrategy = "asDropin";
          after = lib.optional (i > 0) "systemd-cryptsetup@${builtins.elemAt unlockNames (i - 1)}.service";
        })
        unlockNames);
    }

    # ZFS-in-initrd only when the hot store is ZFS (a dataset). LUKS does the crypto, so ZFS
    # native-encryption credentials are NOT requested. The pool imports off /dev/mapper.
    (lib.mkIf (hot.fsType == "zfs") {
      boot.initrd.supportedFilesystems = [ "zfs" ];
      boot.zfs.requestEncryptionCredentials = lib.mkDefault false;
      boot.zfs.devNodes = lib.mkDefault "/dev/mapper";
      # Stage-2 belt-and-braces only; the INITRD import is generated from the neededForBoot
      # /nix fileSystems entry itself (the pool derives from the dataset name), not from this.
      boot.zfs.extraPools = lib.mkIf (hot.zpool != null) [ hot.zpool ];

      # THE first-boot brick guard: nixpkgs' generated initrd zfs-import-<pool> service
      # polls for the pool for only ~60s and then fails terminally — but the pool's
      # /dev/mapper members appear only after the OPERATOR enters the passphrase (a human
      # loop over initrd-SSH, easily >60s; on the very first boot there is no sealed host
      # key yet, so it is a serial-console entry). Order the import after cryptsetup.target,
      # which blocks indefinitely on the passphrase — the 60s poll then starts with all
      # mappers already present.
      boot.initrd.systemd.services."zfs-import-${hotPool}" = {
        wants = [ "cryptsetup.target" ];
        after = [ "cryptsetup.target" ];
      };
    })
  ]);
}
