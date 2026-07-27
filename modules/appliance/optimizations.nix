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

    # ── Compressed RAM: no disk swap, zram at 20 % (the RAM-compression lever) ──
    swapDevices = lib.mkDefault [ ];
    zramSwap = {
      enable = lib.mkDefault true;
      algorithm = "zstd";
      memoryPercent = lib.mkDefault 20;
    };

    # ── zswap OFF whenever there is no durable swap to write back to ──
    # The CachyOS kernel nixnas ships (modules/boot/kernel.nix, the default
    # `kernel.variant`) is built with CONFIG_ZSWAP_DEFAULT_ON=y, so zswap is
    # armed before userspace exists: no cmdline parameter, nothing in any config
    # file, nothing to grep for. Paired with the two lines above -- zram as the
    # ONLY swap device -- that is actively harmful rather than merely redundant.
    #
    # zswap is a compressed cache that writes back to THE SWAP DEVICE. Here the
    # swap device is zram, i.e. RAM. So zswap compresses already-compressed
    # pages into the very resource it is caching, burning CPU for a second RAM
    # budget (max_pool_percent, 20 % by default) stacked in front of zram's own.
    # Worse, its eviction path leads nowhere: with `swapDevices = [ ]` there is
    # no durable store to shed to, so a box under real pressure can only
    # compress, never actually free. Seen on a 125 GiB deployment: enabled=Y,
    # stored_pages climbing, written_back_pages pinned at 0.
    #
    # Gated on swapDevices rather than mkDefault'd, for two reasons. It encodes
    # the actual invariant ("zswap is meaningless without a durable backing
    # store"), so a host that gives itself a real swap partition gets zswap back
    # automatically with no override to remember. And mkDefault would be an
    # outright trap here: boot.kernelParams is a list, a host defining it at
    # normal priority (as ours does, for a video= mode) would DROP a mkDefault
    # definition wholesale rather than concatenate with it. Plain assignment
    # merges; mkDefault would have silently done nothing.
    boot.kernelParams = lib.optional (config.swapDevices == [ ]) "zswap.enabled=0";

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
