# nixnas — appliance optimisations (the ⬢ nixnas-default subset of docs/OPTIMIZATIONS.md).
#
# Priorities: (1) spare the stick — kill avoidable writes, (2) compressed RAM so the
# appliance fits boxes far below 128 GB. Operator-policy items (◯: GC retention, the hub
# substituter, the boot `quiet` cmdline) are left to the host config; the `quiet`/loglevel
# kernel params in particular are deferred so boot output stays observable during dev.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
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
