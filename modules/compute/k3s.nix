# nixnas — native declarative k3s, the workload orchestrator.
#
# Scaffold: a single-node server with the ZFS snapshotter, the in-cluster bits
# (traefik/servicelb/local-storage) disabled in favour of the operator's own
# (MetalLB, etc.). Workloads/manifests live in the operator's GitOps repo, NOT here.
# See docs/DESIGN.md §7.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf optionals optionalAttrs;
  k = cfg.compute.k3s;
in
{
  config = mkIf (cfg.enable && k.enable) {
    services.k3s = {
      enable = true;
      role = "server";
      extraFlags = [
        "--snapshotter=zfs"
        "--disable=traefik,servicelb,local-storage"
        "--write-kubeconfig-mode=0644"
      ] ++ optionals (k.nodeName != null) [ "--node-name=${k.nodeName}" ];
    } // optionalAttrs (k.tokenSops != null) { tokenFile = k.tokenSops; };

    # k3s' ZFS snapshotter shells out to the `zfs` userspace tool.
    systemd.services.k3s.path = [ pkgs.zfs ];
  };
}
