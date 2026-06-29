# nixnas — AMD GPU (amdgpu + ROCm), shared into the Arch container and k3s pods.
#
# The render GID is pinned to a fixed number and reused EVERYWHERE — containers map
# by number, and a mismatch is the #1 cause of `/dev/kfd` permission-denied. See
# docs/DESIGN.md §4.4.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf;
in
{
  config = mkIf (cfg.enable && cfg.compute.gpu.enable) {
    boot.initrd.kernelModules = [ "amdgpu" ];

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Fixed render GID — must match in the Arch container and every k3s GPU pod.
    users.groups.render.gid = cfg.compute.gpu.renderGid;
  };
}
