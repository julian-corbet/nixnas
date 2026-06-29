# nixnas — a single nftables backend.
#
# k3s (flannel), Podman (netavark) and Incus all rewrite host firewall/forwarding
# tables; standardising on ONE nftables backend keeps them from fighting over the
# ruleset. See docs/DESIGN.md §4.1.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf;
in
{
  config = mkIf cfg.enable {
    networking.nftables.enable = true;

    # Container/cluster bridges route between subnets.
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };
}
