# nixnas — appliance optimisations (the ⬢ nixnas-default subset of docs/OPTIMIZATIONS.md).
#
# Priorities: (1) spare the stick — kill avoidable writes, (2) compressed RAM so the
# appliance fits boxes far below 128 GB. Operator-policy items (◯: GC retention, the hub
# substituter, the boot `quiet` cmdline) are left to the host config; the `quiet`/loglevel
# kernel params in particular are deferred so boot output stays observable during dev.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  releaseCblocks = import ../lib/f2fs-release-cblocks.nix { inherit pkgs; };
in
{
  config = lib.mkIf cfg.enable {
    # ── f2fs compression release pass, ongoing case (modules/lib/f2fs-release-cblocks.nix):
    #    LOCAL builds (auto-upgrade's `nixos-rebuild`) run on this box's OWN nix-daemon, so
    #    Nix's post-build-hook fires per new output — no full-store rescan needed here, unlike
    #    the image-build (disk.nix) and rescue-maintain (foreign-store `nix copy`) call sites,
    #    which this hook can never see. usb-mode only: a hot-mode MAIN's /nix is never f2fs.
    nix.extraOptions = lib.mkIf (cfg.store.location == "usb") ''
      post-build-hook = ${pkgs.writeShellScript "nixnas-release-post-build-hook" ''
        #!/bin/sh
        # shellcheck disable=SC2086
        # $OUT_PATHS is Nix's own space-separated list (store paths never contain spaces) —
        # unquoted expansion is the documented, intentional way to consume it.
        exec ${releaseCblocks}/bin/nixnas-f2fs-release-cblocks $OUT_PATHS
      ''}
    '';
    # ── Kill avoidable stick writes (only /nix + ESP persist; root is tmpfs) ──
    # Logs → RAM by default. `store.persistLogs` (temporary debug) instead keeps the journal
    # on the stick's store so it survives a reboot/crash — writes the stick, hence off by default.
    services.journald.storage = if cfg.store.persistLogs then "persistent" else "volatile";
    systemd.tmpfiles.rules = lib.mkIf cfg.store.persistLogs [ "d /nix/nixnas/journal 0700 root root - -" ];
    fileSystems."/var/log/journal" = lib.mkIf cfg.store.persistLogs {
      device = "/nix/nixnas/journal"; fsType = "none"; options = [ "bind" ]; neededForBoot = true;
    };
    systemd.coredump.settings.Coredump.Storage = "none";   # don't spool coredumps
    boot.tmp.useTmpfs = true;                            # /tmp in RAM
    documentation.enable = lib.mkDefault false;          # smaller closure → fewer bytes per update
    documentation.nixos.enable = lib.mkDefault false;
    systemd.services.systemd-networkd-wait-online.enable = lib.mkDefault false;  # no boot stall on link-up

    # ── No disk swap. The memory subsystem itself belongs to nixram ──────────
    # `swapDevices` stays here because "this appliance has no disk swap" is a
    # STORAGE-LAYOUT decision -- the stick is precious and /nix is the only
    # persistent filesystem -- which is squarely nixnas's domain.
    #
    # Everything DOWNSTREAM of that decision is not: which compression medium,
    # how it is sized, the vm.* sysctls that tune reclaim against it, the oomd
    # thresholds that fire when it is exhausted. A subsystem split across two
    # owners has gaps exactly where neither is looking -- that split is how
    # the kernel's own CONFIG_ZSWAP_DEFAULT_ON=y once left zswap silently
    # armed in front of a zram-only swap on a live 125 GiB deployment, with
    # nothing in any config file to point at. nixram owns all of it now;
    # nixnas declares no memory values at all.
    swapDevices = lib.mkDefault [ ];

    nixram = {
      enable = lib.mkDefault true;

      # zram, not zswap -- forced by `swapDevices` above, not a preference.
      # zswap is a cache in FRONT of a durable swap device; with none, it has
      # nowhere to evict to and merely compresses into the same RAM it caches.
      # nixram's `zram` mode also actively DISABLES zswap (zswap.enabled=0 plus
      # a switch-time runtime write), which is what closes the kernel-default
      # hole described above.
      mode = lib.mkDefault "zram";

      # `level` is deliberately NOT defaulted, and cannot be: nix evaluation
      # cannot read the target machine's /proc/meminfo, and nixram refuses to
      # guess rather than silently tune a 128 GiB box as if it were 4 GiB.
      # Every nixnas host must declare it once:
      #
      #     nix run github:julian-corbet/nixram-corbet-ch#detect-level
      #     nixram.level = "...";   # paste the printed line
      #
      # An operator who skips it gets nixram's own assertion, naming that
      # command -- a build failure, never a silently-wrong tuning.
    };

    # ── store.preload: warm the booted closure into the (compress-)cache, so runtime
    #    reads come from RAM and the slow stick is untouched — copytoram done right.
    #    Field-proven (first real deployment, 2026-07-04): right after boot/switch on a
    #    ~5 MB/s stick, this closure read starved interactive use — SSH accepted
    #    connections but shells took >30 s to exec, exactly when an operator needs the
    #    box responsive. Warming is a background optimization and must NEVER compete
    #    with the operator: idle IO class + idle CPU policy + Nice=19 (the nice value
    #    is belt-and-braces — it only matters if the policy ever falls back to
    #    SCHED_OTHER; under SCHED_IDLE it is moot). ──
    systemd.services.nixnas-store-preload = lib.mkIf cfg.store.preload {
      description = "Warm the booted closure into RAM (compress-)cache";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Strictly-background scheduling: only use disk/CPU when nobody else wants them.
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
        ExecStart = pkgs.writeShellScript "nixnas-store-preload" ''
          ${pkgs.nix}/bin/nix-store -qR /run/current-system \
            | ${pkgs.findutils}/bin/xargs -r ${pkgs.vmtouch}/bin/vmtouch -t -q
        '';
      };
    };
  };
}
