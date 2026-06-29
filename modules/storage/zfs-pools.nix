# nixnas — data pool storage (IMPORT-ONLY).
#
# SAFETY INVARIANT: nixnas imports the operator's pools and unlocks their LUKS
# members. It NEVER creates, formats, `luksFormat`s, or destroys a data pool or a
# data device — the only device nixnas partitions/formats is the USB stick (see
# modules/boot). Nothing in this file ever writes a pool or a LUKS header.
#
# STATUS: first draft. The stage-2 unlock + non-fatal ZFS import ordering is the
# classic systemd+ZFS footgun and MUST be verified under a pulled-disk test on real
# hardware (see docs/DESIGN.md §3.5 and §10).
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf imap0 listToAttrs nameValuePair optionalString concatStringsSep filter;

  poolNames = filter (n: n != "") [ cfg.storage.pools.hot.name cfg.storage.pools.cold.name ];

  # Each LUKS data member across both pools, with a stable mapper name.
  poolDevices = pool:
    imap0 (i: dev: { name = "nixnas-${pool.name}-${toString i}"; device = dev; }) pool.luksDevices;
  allDevices = poolDevices cfg.storage.pools.hot ++ poolDevices cfg.storage.pools.cold;

  tpm2Opt = optionalString cfg.crypto.tpm2.enable ",tpm2-device=auto";

  # Stage-2 crypttab: unlock the data members AFTER the (verity, secret-free) OS is
  # already up, so a locked/absent pool never blocks boot. systemd-cryptsetup reuses
  # the single entered passphrase across entries (kernel keyring); with TPM2 enrolled
  # it auto-unlocks via the PIN. `nofail` keeps a missing device non-fatal.
  crypttab = concatStringsSep "\n"
    (map (d: "${d.name} ${d.device} none luks,nofail${tpm2Opt}") allDevices);
in
{
  config = mkIf cfg.enable {
    # Data LUKS unlock in stage-2 (NOT initrd — the OS root is verity, not on a pool).
    environment.etc."crypttab" = mkIf (allDevices != [ ]) { text = crypttab + "\n"; };

    boot.zfs = {
      # Import the operator's pools NON-fatally (extraPools imports non-boot pools in
      # stage-2; a degraded/absent pool leaves the box up).
      extraPools = poolNames;
      # ZFS-on-LUKS: the vdevs are the decrypted mappers.
      devNodes = "/dev/mapper";
    };

    # The pool import must wait for the crypttab unlocks. VERIFY the unit graph stays
    # non-blocking under a pulled-disk test (a `nofail` mount can still block via
    # RequiresMountsFor).
    systemd.services = listToAttrs (map
      (p: nameValuePair "zfs-import-${p}" {
        after = [ "cryptsetup.target" ];
        wants = [ "cryptsetup.target" ];
      })
      poolNames);

    # Read-mostly hygiene; never auto-creates or auto-extends anything.
    services.zfs.autoScrub.enable = lib.mkDefault true;
  };
}
