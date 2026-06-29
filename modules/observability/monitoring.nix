# nixnas — host health/monitoring (replaces the Unraid web UI's SMART + dashboard).
#
# Runs on the HOST, not in k3s, so disk health survives the cluster being down.
# Scrape the exporters over the tailnet from your monitoring stack. See DESIGN §4.5.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf;
in
{
  config = mkIf cfg.enable {
    # SMART monitoring — the direct Unraid-SMART replacement.
    # NOTE: do not schedule long self-tests on the SMR archive disks during writes.
    services.smartd = {
      enable = true;
      autodetect = true;
    };

    # Host-level Prometheus exporters (survive k3s down).
    services.prometheus.exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" "zfs" ];
      };
      smartctl.enable = true;
    };
  };
}
