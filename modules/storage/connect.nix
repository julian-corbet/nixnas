# nixnas — connect your existing storage. THIN by design.
#
# nixnas does NOT reinvent mounting: filesystems, ZFS import, and initrd LUKS are all
# native NixOS. This module adds only the one fiddly, footgun-prone piece — unlocking
# your LUKS data members in STAGE-2 with the SINGLE shared passphrase (the store's TPM2
# PIN, cached in the kernel keyring and reused across devices), NON-fatally so a missing
# or degraded disk never blocks boot. You then MOUNT the result with plain `fileSystems`
# / `boot.zfs.extraPools` at `/hot`, `/cold`, or any name, and persist state onto it with
# `environment.persistence` (the impermanence module).
#
# SAFETY INVARIANT: nixnas only OPENS + IMPORTS. It never creates, `luksFormat`s, or
# destroys a device or pool — the only thing it partitions is the USB stick.
#
# The data members are deliberately NOT TPM-bound (no `tpm2-device` here): only the stick
# store binds to this box's TPM. A data disk pulled into another machine opens with the
# passphrase alone — the rescue model. (Spike: keyring reuse across the initrd→stage-2
# switch-root — see docs/ARCHITECTURE.md §6, §9.)
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf concatStringsSep mapAttrsToList listToAttrs nameValuePair;
  # `name → /dev/mapper/name`, so the operator references a STABLE mapper in fileSystems.
  crypttab = concatStringsSep "\n"
    (mapAttrsToList (name: dev: "${name} ${dev} none luks,nofail") cfg.storage.unlock);
in
{
  config = mkIf cfg.enable (lib.mkMerge [
    # Stage-2 LUKS unlock: shared passphrase reused via the kernel keyring, non-fatal.
    (mkIf (cfg.storage.unlock != { }) {
      environment.etc."crypttab".text = crypttab + "\n";
    })

    # Optional ZFS convenience: import the named pools non-fatally (ZFS-on-LUKS mappers).
    (mkIf (cfg.storage.zfsPools != [ ]) {
      boot.zfs.extraPools = cfg.storage.zfsPools;
      boot.zfs.devNodes = lib.mkDefault "/dev/mapper";
      services.zfs.autoScrub.enable = lib.mkDefault true;
      # The import must wait for the crypttab unlocks; keep it non-blocking (verify under a
      # pulled-disk test — a `nofail` mount can still block via RequiresMountsFor).
      systemd.services = listToAttrs (map
        (p: nameValuePair "zfs-import-${p}" {
          after = [ "cryptsetup.target" ];
          wants = [ "cryptsetup.target" ];
        })
        cfg.storage.zfsPools);
    })
  ]);
}
