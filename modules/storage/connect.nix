# nixnas — connect your existing storage. THIN by design, unlocked POST-boot.
#
# nixnas does NOT reinvent mounting: filesystems and ZFS import are native NixOS.
# This module adds the appliance's one deliberate storage mechanism — the post-boot
# data unlock:
#
#   The OS boots fully with NO data secret: tmpfs root, /nix store, network, sshd,
#   Tailscale — all up, every data member still LOCKED (`noauto`). The operator
#   SSHes in and runs `nixnas-unlock`, which starts `nixnas-storage.target`:
#
#     1. each `storage.unlock` member opens SERIALLY via systemd-cryptsetup; the
#        FIRST passphrase entered is cached in the kernel keyring and opens the
#        rest silently — one prompt for the whole set (systemd's own password
#        cache; members are chained so the cache is always warm);
#     2. each `storage.zfsPools` pool is imported (`zpool import -d /dev/mapper`),
#        which also mounts its datasets at their `mountpoint` properties;
#     3. operator mounts/services hooked to the target come up — add
#        `"noauto" "x-systemd.wanted-by=nixnas-storage.target"` to the options of
#        `fileSystems` entries on these mappers, and gate services on the target.
#
# SECURITY MODEL: data members are passphrase-only — deliberately NOT TPM-bound and
# never keyfile-persisted. A seized disk (or the whole box) yields nothing without
# the passphrase; a disk pulled into another machine opens with the passphrase alone
# (the rescue model). The channel the passphrase is typed into is authenticated by
# the stick's persistent SSH host keys (modules/appliance/identity.nix) under the
# Secure Boot + TPM2 chain.
#
# SAFETY INVARIANT: nixnas only OPENS + IMPORTS. It never creates, `luksFormat`s, or
# destroys a device or pool — the only thing it partitions is the USB stick.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf mkMerge concatStringsSep mapAttrsToList listToAttrs nameValuePair imap0 optional optionalString;

  # Deterministic unlock order (attrNames sorts); the serial chain relies on it.
  unlockNames = lib.attrNames cfg.storage.unlock;
  unlockUnits = map (n: "systemd-cryptsetup@${n}.service") unlockNames;
  importUnits = map (p: "nixnas-import-${p}.service") cfg.storage.zfsPools;

  # HOT mode: the initrd (store/location.nix) already opened EVERY member — hot AND data —
  # with the one operator passphrase, so the mappers are present the moment stage-2 starts.
  # Here that means: stage-2 does NOT re-open the data members (no double-open), and the
  # storage target AUTO-RAISES at boot (imports + mounts follow the open mappers) — no manual
  # `nixnas-unlock`. In usb/rescue mode the members are still LOCKED at boot and the operator
  # raises the target post-boot with `nixnas-unlock` (the original THIN model).
  isHot = cfg.enable && cfg.store.location == "hot";

  # `name → /dev/mapper/name`, a STABLE mapper the operator references in fileSystems.
  # `noauto`: nothing opens at boot — nixnas-storage.target pulls these on demand.
  # `nofail`: a missing/degraded disk never fails the target (non-fatal by design).
  crypttab = concatStringsSep "\n"
    (mapAttrsToList (name: dev: "${name} ${dev} none luks,noauto,nofail") cfg.storage.unlock);

  zpool = "${config.boot.zfs.package}/bin/zpool";

  nixnas-unlock = pkgs.writeShellApplication {
    name = "nixnas-unlock";
    text = ''
      # nixnas-unlock — one passphrase opens every declared data member, imports the
      # pools, and raises nixnas-storage.target (gated mounts + services follow).
      echo ">> nixnas-unlock: raising nixnas-storage.target"
      systemctl start --no-block nixnas-storage.target

      # Surface each pending password question on THIS terminal. Members open
      # serially; after the first answer the kernel-keyring cache opens the rest.
      while systemctl list-jobs --no-legend | grep -Eq 'nixnas-storage|cryptsetup|nixnas-import'; do
        systemd-tty-ask-password-agent --query || true
        sleep 1
      done

      echo
      failed="$(systemctl list-units --failed --no-legend 'systemd-cryptsetup@*.service' 'nixnas-import-*.service' || true)"
      if [ -n "$failed" ]; then
        echo ">> some members/pools did NOT come up (non-fatal by design):"
        echo "$failed"
      fi
      ${optionalString (cfg.storage.zfsPools != [ ]) ''
        ${zpool} list 2>/dev/null || echo ">> no ZFS pools imported"
      ''}
      echo ">> nixnas-storage.target: $(systemctl is-active nixnas-storage.target || true)"
    '';
  };
in
{
  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.storage.unlock != { }) {
      environment.etc."crypttab".text = crypttab + "\n";
      environment.systemPackages = [ nixnas-unlock ];

      # Serialise the unlocks so the keyring cache is always HIT: the first member
      # prompts, every later one finds the cached passphrase and opens silently.
      systemd.services = listToAttrs (imap0
        (i: n: nameValuePair "systemd-cryptsetup@${n}" {
          overrideStrategy = "asDropin";
          after = optional (i > 0) "systemd-cryptsetup@${builtins.elemAt unlockNames (i - 1)}.service";
        })
        unlockNames);

      # The data-storage switch. HOT mode: auto-raised at boot (members already open in the
      # initrd — pull only the imports + mounts, NOT the cryptsetup units). USB/rescue mode:
      # stays inert until `nixnas-unlock` flips it, and it pulls the member unlocks too.
      systemd.targets.nixnas-storage = {
        description = "nixnas data storage (LUKS members open, ZFS pools imported, mounts up)";
        wants = (lib.optionals (!isHot) unlockUnits) ++ importUnits;
        after = (lib.optionals (!isHot) unlockUnits) ++ importUnits;
        wantedBy = lib.optionals isHot [ "multi-user.target" ];
      };
    })

    (mkIf (cfg.storage.zfsPools != [ ]) {
      # ZFS userland + kernel module — the native NixOS switch. Nothing imports at
      # BOOT: the pools appear when nixnas-storage.target runs the imports below.
      boot.supportedFilesystems.zfs = true;
      services.zfs.autoScrub.enable = lib.mkDefault true;

      systemd.services = listToAttrs (map
        (p: nameValuePair "nixnas-import-${p}" {
          description = "Import ZFS pool ${p} (nixnas data storage)";
          # HOT: mappers are open from the initrd — no cryptsetup units to wait on (they never
          # run in hot mode; ordering after them would deadlock). USB: wait for the unlocks.
          after = lib.optionals (!isHot) unlockUnits;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # Import scans the unlocked mappers; datasets self-mount at their
          # `mountpoint` properties. Idempotent: an already-imported pool is a no-op.
          script = ''
            if ${zpool} list ${p} >/dev/null 2>&1; then exit 0; fi
            exec ${zpool} import -d /dev/mapper ${p}
          '';
        })
        cfg.storage.zfsPools);
    })
  ]);
}
