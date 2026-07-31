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
# THE LUKS-OPEN CHAIN ITSELF IS NIXLUKS'S, NOT THIS FILE'S, AS OF THE NIXBOOT/NIXLUKS
# CUTOVER: this module used to hand-roll `boot.initrd.luks.devices` + the
# `systemd-cryptsetup@` keyring-chain ordering directly (see nixluks's own
# modules/initrd.nix header for the field-proven mechanism this generalises FROM this
# exact file). It now DECLARES each member as `nixluks.volumes.<name>` (device + unlock
# order + boot-critical-vs-data timeout stance) and lets nixluks's own `modules/initrd.nix`
# render the actual `boot.initrd.luks.devices` entries and the ordering chain — nixluks
# explicitly disclaims owning WHY a volume needs to be open this early (ZFS import,
# mounting) or WHAT geometry it has, which is exactly what stays here: the fileSystems
# entries, the ZFS-in-initrd import ordering below, and the assertions.
#
# `manageUnlock = false` on every volume this file declares — deliberate, not an oversight:
# these members are ALREADY open by the time nixluks's own STAGE-2 chain (crypttab +
# `systemd-cryptsetup@` post-boot ordering) would ever run, so that chain must never also
# try to open them (a redundant, at-best-inert, at-worst-confusing second attempt). The
# SAME volumes may ALSO be declared elsewhere (e.g. a consuming host's own header-backup
# publication config) with their own `manageUnlock = false` and a `headerBackup.destination`
# — both declarations merge cleanly as long as they agree on shared fields (the module
# system merges submodule config across files the same way any NixOS option does), but such
# a consumer must NOT also declare its own `order` for these names: this file is the one
# that assigns the real, distinct per-volume order value the initrd chain depends on.
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
  # UNCHANGED sequencing from before the nixluks cutover: this is still the exact order the
  # keyring-chain prompts in, now expressed as nixluks's own `order` field (an explicit int,
  # never attribute-definition position) instead of being implicit in this list's own
  # position — see the `order` assignment below, which maps each name to its index HERE.
  allUnlockNames = lib.attrNames (bootCriticalUnlock // dataUnlock);
  # index-in-allUnlockNames -> a real, distinct `nixluks.volumes.<name>.order` value,
  # preserving the exact prompt sequence the old attrNames-derived chain produced.
  orderByName = lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n i) allUnlockNames);
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
            "hot/nixnas/root" beside "hot/nixnas/nix"; declare each one's mount shape with
            store.root.zfsMountpoint), or a /dev/mapper/<name> for LUKS+ext4/btrfs/f2fs.
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
          # must be present so the operator can actually enter the key in stage-1. Reads
          # `config.nixboot.remoteUnlock.enable` — the mechanism's OWN authoritative flag,
          # post-cutover — rather than `cfg.boot.remoteUnlock.enable` (the nixnas-facing
          # input that only ever feeds it, see ../boot/nixboot.nix): nixluks's own docs note
          # that "nixboot has no LUKS member list to attach it to", so this assertion can
          # only ever live here, where both the LUKS members and the actual remote-unlock
          # gate are visible in the same evaluated config.
          assertion = config.nixboot.remoteUnlock.enable;
          message = "hot mode enters the store key in the initrd — keep boot.remoteUnlock.enable = true (initrd-SSH), or use a console/IPMI-SOL.";
        }
        {
          # THE SILENT-GAP THIS CATCHES: `nixluks.volumes.<name>.initrdUnlock.enable = true`
          # (set below) is a plain option WRITE — nothing forces the consumer to have ALSO
          # composed `nixluks.nixosModules.initrd` (the separate NixOS-only module that reads
          # it and actually renders `boot.initrd.luks.devices`). Declared-but-uncomposed is
          # not an eval error anywhere else: the option write just sits there, inert, and the
          # very first symptom would be a MAIN that boots to an empty initrd with no /nix and
          # no way to unlock it — discovered at the worst possible time. Checking that every
          # declared name actually made it into `boot.initrd.luks.devices` turns that into a
          # loud, immediate, actionable build failure instead.
          assertion = lib.all (n: config.boot.initrd.luks.devices ? ${n}) allUnlockNames;
          message = ''
            hot mode declared LUKS members (${lib.concatStringsSep ", " allUnlockNames}) as
            nixluks.volumes.*, but boot.initrd.luks.devices does not contain all of them.
            This means whoever composes this host's module list is missing
            nixluks.nixosModules.initrd (the separate NixOS-only stage-1 companion —
            nixluks.nixosModules.nixluks / .default alone is not enough). Add it alongside
            nixluks's base module, the same way lanzaboote/disko/impermanence are composed.
          '';
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
      # this mode exists to end (docs/ARCHITECTURE.md §3). For zfs, BOTH root-on-ZFS mount
      # shapes are supported and the operator picks one with `store.root.zfsMountpoint`:
      # `mountpoint=legacy` (mounted plainly with mount(8)) or a real mountpoint property
      # plus `canmount=noauto` (mounted with `-o zfsutil`). They are mutually exclusive at
      # mount(8) — zfsutil against a legacy dataset is REFUSED, and a property dataset
      # cannot be mounted without it — and a property is runtime state no evaluation can
      # inspect, which is exactly why it has to be declared rather than detected.
      #
      # Note which half is load-bearing: the mount TARGET always comes from this
      # `fileSystems."/"` declaration, never from the dataset's mountpoint property.
      # `zfsutil` makes mount.zfs fold the dataset's PROPERTIES into the mount options
      # (atime=off → noatime); it does not choose the location. A `"property"` dataset is
      # therefore self-describing to anyone who imports the pool, not self-mounting.
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
      }
      // lib.optionalAttrs (root.fsType == "zfs" && root.zfsMountpoint == "property") {
        options = [ "zfsutil" ];
      };

      # The MAIN system's /nix = the hot device. neededForBoot ⇒ mounted in stage-1.
      # For zfs, pick the mount shape with `store.hot.zfsMountpoint` — same mechanism and
      # same mutual exclusivity as `store.root.zfsMountpoint` above. Root and /nix are
      # independent: a self-describing `"property"` root beside a `"legacy"` /nix is a
      # perfectly coherent combination, since each carries its own mount options.
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
      }
      // lib.optionalAttrs (hot.fsType == "zfs" && hot.zfsMountpoint == "property") {
        options = [ "zfsutil" ];
      };

      # ── ONE key, ALL storage — the nixnas unlock algorithm, opened by NIXLUKS in the
      # INITRD ─────────────────────────────────────────────────────────────────────────────
      # The single operator passphrase (interactive, over initrd-SSH / console, never TPM)
      # opens EVERY declared member here, so ONE entry brings up everything and there is no
      # second post-boot prompt. This file only ever DECLARES the facts (device, unlock
      # order, boot-critical-vs-data timeout stance) — nixluks's own `modules/initrd.nix`
      # renders the actual `boot.initrd.luks.devices` entries and the `systemd-cryptsetup@`
      # keyring-chain ordering from them (see this file's own header). Two classes, different
      # failure semantics, exactly as before the cutover:
      #
      #   * BOOT-CRITICAL members (store.hot.unlock ∪ store.root.unlock) — the /nix and /
      #     LUKS members. `initrdUnlock.critical = true` pins the backing-device job
      #     INFINITE (the 90 s trap of boot/disk.nix: the job would else die at
      #     DefaultDeviceTimeoutSec on slow-POST / slow spin-up). No /nix or / without
      #     these, so a failure correctly stops the boot.
      #   * DATA members (e.g. cold + SMR, from nixnas.storage.unlock) — NON-fatal.
      #     `initrdUnlock.critical = false` (the default) gets `nofail` + nixluks's own
      #     default 45 s timeout: an absent or dead archive disk is SKIPPED after the
      #     timeout instead of hanging the boot forever (the opposite of the boot-critical
      #     members). They ride the SAME passphrase via the kernel-keyring cache — no extra
      #     prompt.
      #
      # `nixluks.enable`/`raiseMode` are set HERE, unconditionally under hot mode, so this
      # module is self-sufficient on any host (this repo's own demo-hot/matrix-hot-* CI
      # fixtures included) — never relying on some OTHER file to have turned nixluks on
      # first. A consuming host that ALSO declares these same names for header-backup
      # purposes (e.g. its own publication config) sets the identical values, which merge
      # silently (same-priority, same-value); see this file's own header for the one field
      # such a consumer must NOT also set (`order`).
      nixluks.enable = true;
      nixluks.raiseMode = "preopened";
      nixluks.volumes =
        (lib.mapAttrs
          (n: dev: {
            device = dev;
            order = orderByName.${n};
            manageUnlock = false; # opened by THIS module's own initrdUnlock wiring, never nixluks's post-boot chain
            initrdUnlock.enable = true;
            initrdUnlock.critical = true;
          })
          bootCriticalUnlock)
        // (lib.mapAttrs
          (n: dev: {
            device = dev;
            order = orderByName.${n};
            manageUnlock = false;
            initrdUnlock.enable = true;
            initrdUnlock.critical = false; # nixluks's own default timeoutSec (45s) matches the old hardcoded value
          })
          dataUnlock);
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
