# nixnas — store location: the `hot`-mode MAIN-system boot wiring.
#
# In `hot` mode the MAIN system's /nix AND / (root) live on the operator's own encrypted
# storage (`store.hot.*` / `store.root.*`), NOT the stick. This module makes the MAIN
# system boot from it:
#   * /nix and / are each a fileSystems entry on their own device, mounted in stage-1
#     before switch-root (the whole system executes out of /nix; / is an ORDINARY
#     persistent root — no tmpfs, no impermanence: see docs/ARCHITECTURE.md §3),
#   * the initrd opens every declared LUKS member (hot ∪ root ∪ data) with the OPERATOR'S
#     key — interactive, over initrd-SSH / console, NEVER TPM auto (the box blocks here
#     until the operator enters it; data stays sealed),
#   * ZFS is pulled into the initrd when EITHER the hot store or the root is a ZFS dataset.
#
# The RESCUE system (the thing actually flashed to the stick) and the disko stick image are
# a separate, usb-mode nixnas derived from this config — see modules/boot/rescue.nix. In
# `usb` mode this module is inert and disk.nix owns / (tmpfs) + /nix on the stick — a
# rescue has no state worth keeping, which is exactly why impermanence stays right there
# and is wrong here. See docs/HOT-MODE.md.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  hot = cfg.store.hot;
  root = cfg.store.root;
  isHot = cfg.enable && cfg.store.location == "hot";
  # The pool backing a zfs store — explicit, or derived from the dataset name. Falls back
  # to a dummy: attr NAMES eval eagerly even under mkIf, so this must never be null (usb
  # hosts have no hot/root.device; their "zfs-import--unset-" attr sits behind mkIf false).
  poolOf = device: zpool:
    if zpool != null then zpool
    else if device != null then builtins.head (lib.splitString "/" device)
    else "-unset-";
  hotPool = poolOf hot.device hot.zpool;
  rootPool = poolOf root.device root.zpool;
  # Every distinct pool that actually needs importing in the initrd — hot and root may
  # share one pool (the common case: sibling datasets) or name two; either way each
  # distinct name gets exactly ONE zfs-import service below.
  zfsPoolsNeeded = lib.unique (
    lib.optional (hot.fsType == "zfs") hotPool
    ++ lib.optional (root.fsType == "zfs") rootPool
  );
  # The nixnas unlock algorithm: the ONE operator key opens EVERY declared member in the
  # initrd. Hot-store and root members are boot-critical; data members (e.g. cold + SMR,
  # from storage.unlock) ride the SAME single passphrase (kernel-keyring cache) but are non-fatal.
  bootCriticalUnlock = hot.unlock // root.unlock; # /nix ∪ / — no /nix or / without these
  dataUnlock = cfg.storage.unlock; # e.g. cold + SMR — declared in infra, opened here
  dataPools = cfg.storage.zfsPools; # non-root pools imported in the initrd too
  # attrNames is sorted — a stable chain order across the whole set (hot ∪ root ∪ data).
  allUnlockNames = lib.attrNames (bootCriticalUnlock // dataUnlock);
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
          assertion = root.device != null;
          message = ''
            nixnas.store.location = "hot" requires nixnas.store.root.device — the MAIN's
            PERSISTENT root filesystem. There is no tmpfs-root fallback: a main accumulates
            operational state (this is exactly the failure class an ephemeral root produces
            — see docs/ARCHITECTURE.md §3), so root MUST be a real device on your own
            encrypted storage, same as store.hot.device. A ZFS dataset name (with
            store.root.fsType = "zfs", typically a sibling of store.hot.device, e.g.
            "hot/nixnas/root" beside "hot/nixnas/nix", both mountpoint=legacy), or a
            /dev/mapper/<name> for LUKS+ext4/btrfs/f2fs.
          '';
        }
        {
          assertion = hot.unlock != { };
          message = "hot mode requires nixnas.store.hot.unlock — the LUKS members the initrd opens with YOUR key.";
        }
        {
          # persist.* exists ONLY to route identity around a tmpfs root (usb mode). A
          # hot-mode host has a real, persistent root, so these are inert no-ops there —
          # modules/appliance/identity.nix and persist-enforce.nix both gate on
          # store.location == "usb" and never even evaluate here. Refuse rather than let an
          # operator believe either option is still doing something.
          assertion = cfg.persist.overlayClients == [ ] && cfg.persist.explicitlyEphemeral == [ ];
          message = ''
            nixnas.store.location = "hot" has a REAL persistent root (docs/ARCHITECTURE.md
            §3) — nixnas.persist.overlayClients and nixnas.persist.explicitlyEphemeral are
            usb-mode-only concepts (routing identity around a tmpfs root) and have NO EFFECT
            here: every service's /var/lib state already survives a reboot on your
            persistent root, the same as any ordinary NixOS box. Remove both from this
            host's config.
          '';
        }
        {
          # The whole point: no unattended decrypt. remote-unlock (initrd-SSH) or a console
          # must be present so the operator can actually enter the key in stage-1.
          assertion = cfg.boot.remoteUnlock.enable;
          message = "hot mode enters the store key in the initrd — keep boot.remoteUnlock.enable = true (initrd-SSH), or use a console/IPMI-SOL.";
        }
      ];

      # The ESP: the MAIN shares the stick's ESP with the rescue (lanzaboote installs the
      # main's UKIs; rescue-maintain drops EFI/Linux/nixnas-rescue.efi). Mount it by the label
      # disk.nix stamps on the stick ESP, so it's found regardless of device path.
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
        options = [ "umask=0077" "noatime" ];
      };

      # The MAIN system's ORDINARY, PERSISTENT root. No tmpfs, no impermanence — a main
      # accumulates state (users, rendered config, every service's /var/lib) across its
      # whole operational life, and losing that silently on reboot is exactly the failure
      # this mode exists to end (docs/ARCHITECTURE.md §3). For zfs the dataset MUST be
      # `mountpoint=legacy` (mounted with mount(8) in the initrd; a property-managed
      # mountpoint needs `zfsutil` and fights the boot ordering) — the same contract as
      # `store.hot.device`, typically its sibling dataset.
      #
      # FIELD-BACKLOG #2 (see boot/disk.nix for the full proven mechanism): the operator-
      # key wait must be INFINITE, exactly as for /nix below — an unanswered prompt must
      # never 90s-timeout into a locked emergency shell. `x-systemd.device-timeout=0` pins
      # the backing-device job infinite for a DEVICE-backed root (ext4/btrfs/f2fs on
      # /dev/mapper/…); a ZFS root has no device unit at all, so the wait is already owned
      # by the zfs-import service ordered after cryptsetup.target below and the option
      # would be an inert no-op there.
      fileSystems."/" = {
        device = root.device;
        fsType = root.fsType;
      }
      # null-guard FIRST: forcing root.device here would preempt the module's curated
      # "requires nixnas.store.root.device" assertion with a raw coercion error.
      // lib.optionalAttrs (root.device != null && lib.hasPrefix "/dev/" root.device) {
        options = [ "x-systemd.device-timeout=0" ];
      };

      # The MAIN system's /nix = the hot device. neededForBoot ⇒ mounted in stage-1.
      # For zfs the dataset MUST be `mountpoint=legacy` (the initrd mounts it with mount(8);
      # a property-managed mountpoint would need `zfsutil` and fights the boot ordering —
      # legacy is the root-on-ZFS convention and the shape nixnas supports).
      #
      # FIELD-BACKLOG #2 (see boot/disk.nix for the full proven mechanism): the operator-
      # key wait must be INFINITE — an unanswered prompt must never 90s-timeout into a
      # locked emergency shell. For a DEVICE-backed /nix (ext4/btrfs/f2fs on /dev/mapper/…)
      # the killer is the mount's device job: JobRunningTimeoutSec falls back to
      # DefaultDeviceTimeoutSec (90 s) while the mapper only appears after the passphrase.
      # `x-systemd.device-timeout=0` makes the fstab generator pin that job infinite.
      # A ZFS /nix has NO device unit (the source is a dataset name, not a /dev path) —
      # there the wait is already owned by the zfs-import service ordered after
      # cryptsetup.target below, so the option would be an inert no-op and is skipped.
      fileSystems."/nix" = {
        device = hot.device;
        fsType = hot.fsType;
        neededForBoot = true;
      }
      # null-guard FIRST: forcing hot.device here would preempt the module's curated
      # "requires nixnas.store.hot.device" assertion with a raw coercion error.
      // lib.optionalAttrs (hot.device != null && lib.hasPrefix "/dev/" hot.device) {
        options = [ "x-systemd.device-timeout=0" ];
      };

      # ── ONE key, ALL storage — the nixnas unlock algorithm, run in the INITRD ──────────
      # The single operator passphrase (interactive, over initrd-SSH / console, never TPM)
      # opens EVERY declared member here, so ONE entry brings up everything and there is no
      # second post-boot prompt. Two classes, different failure semantics:
      #
      #   * BOOT-CRITICAL members (store.hot.unlock ∪ store.root.unlock) — the /nix and /
      #     LUKS members. x-systemd.device-timeout=0 pins the backing-device job INFINITE
      #     (the 90 s trap of boot/disk.nix: the job would else die at
      #     DefaultDeviceTimeoutSec on slow-POST / slow spin-up). No /nix or / without
      #     these, so a failure correctly stops the boot.
      #   * DATA members (e.g. cold + SMR, from nixnas.storage.unlock) — NON-fatal. `nofail`
      #     + a FINITE device timeout: an absent or dead archive disk is SKIPPED after the
      #     timeout instead of hanging the boot forever (the opposite of the boot-critical
      #     members). They ride the SAME passphrase via the kernel-keyring cache — no extra
      #     prompt.
      boot.initrd.luks.devices =
        (lib.mapAttrs
          (_: dev: {
            device = dev;
            crypttabExtraOpts = [ "x-systemd.device-timeout=0" ];
          })
          bootCriticalUnlock)
        // (lib.mapAttrs
          (_: dev: {
            device = dev;
            # 45 s: generous enough for cold-boot HDD/SMR enumeration + spin-up, still FINITE
            # so a genuinely dead/absent archive disk is skipped (nofail) rather than hanging
            # the boot forever the way the boot-critical members (device-timeout=0) deliberately do.
            crypttabExtraOpts = [ "nofail" "x-systemd.device-timeout=45s" ];
          })
          dataUnlock);

      # Serialise ALL member unlocks (hot ∪ data) into one keyring chain: the first member
      # prompts, systemd caches the passphrase in the kernel keyring, and every later member
      # (hot or data) finds it and opens silently — ONE entry for the whole set. Without the
      # chain all members race and queue N password-agent questions in parallel.
      boot.initrd.systemd.services = lib.listToAttrs (lib.imap0
        (i: n: lib.nameValuePair "systemd-cryptsetup@${n}" {
          overrideStrategy = "asDropin";
          after = lib.optional (i > 0) "systemd-cryptsetup@${builtins.elemAt allUnlockNames (i - 1)}.service";
        })
        allUnlockNames);
    }

    # ZFS-in-initrd when EITHER the hot store or the root is ZFS (a dataset). LUKS does the
    # crypto, so ZFS native-encryption credentials are NOT requested. Pools import off
    # /dev/mapper — one zfs-import service per DISTINCT pool name (zfsPoolsNeeded), so
    # hot and root sharing one pool (the common case: sibling datasets) get exactly one.
    (lib.mkIf (hot.fsType == "zfs" || root.fsType == "zfs") {
      boot.initrd.supportedFilesystems = [ "zfs" ];
      boot.zfs.requestEncryptionCredentials = lib.mkDefault false;
      boot.zfs.devNodes = lib.mkDefault "/dev/mapper";
      # Stage-2 belt-and-braces only; the INITRD import is generated from the neededForBoot
      # /nix / the root fileSystems entries themselves (the pool derives from the dataset
      # name), not from this.
      boot.zfs.extraPools = lib.unique (
        lib.optional (hot.fsType == "zfs" && hot.zpool != null) hot.zpool
        ++ lib.optional (root.fsType == "zfs" && root.zpool != null) root.zpool
      );

      # THE first-boot brick guard: nixpkgs' generated initrd zfs-import-<pool> service
      # polls for the pool for only ~60s and then fails terminally — but the pool's
      # /dev/mapper members appear only after the OPERATOR enters the passphrase (a human
      # loop over initrd-SSH, easily >60s; on the very first boot there is no sealed host
      # key yet, so it is a serial-console entry). Order the import after cryptsetup.target,
      # which blocks indefinitely on the passphrase — the 60s poll then starts with all
      # mappers already present.
      boot.initrd.systemd.services = lib.genAttrs
        (map (p: "zfs-import-${p}") zfsPoolsNeeded)
        (_: {
          wants = [ "cryptsetup.target" ];
          after = [ "cryptsetup.target" ];
        });
    })
  ]);
}
