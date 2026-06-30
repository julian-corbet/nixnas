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
    services.journald.storage = "volatile";              # logs to RAM, never /var/log/journal
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
    #    reads come from RAM and the slow stick is untouched — copytoram done right. ──
    systemd.services.nixnas-store-preload = lib.mkIf cfg.store.preload {
      description = "Warm the booted closure into RAM (compress-)cache";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = pkgs.writeShellScript "nixnas-store-preload" ''
          ${pkgs.nix}/bin/nix-store -qR /run/current-system \
            | ${pkgs.findutils}/bin/xargs -r ${pkgs.vmtouch}/bin/vmtouch -t -q
        '';
      };
    };
  };
}
