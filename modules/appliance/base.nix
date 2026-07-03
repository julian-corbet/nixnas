# nixnas — appliance basics: stable identity + Tailscale.
#
# Tailscale is both the management plane and the path for stage-2 remote LUKS unlock
# (the OS boots fully into RAM with no secret, so you SSH in over the tailnet and
# answer the data-pool passphrase — see docs/ARCHITECTURE.md §6).
{ config, lib, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf mkDefault optionalAttrs;
in
{
  config = mkIf cfg.enable {
    # Stable identity — keep it across re-images so the k3s/node identity is preserved.
    networking.hostName = mkDefault cfg.hostName;

    # rescue.extraPackages: the operator's own tools on a STICK-RESIDENT system — set on the
    # hot-mode RESCUE host (a usb-mode nixnas), where they must be present exactly when the
    # pool is dead. usb-gated: a hot-mode MAIN puts tools in its (unlimited) own config.
    environment.systemPackages =
      lib.optionals (cfg.store.location == "usb") cfg.rescue.extraPackages;

    services.tailscale = mkIf cfg.tailscale.enable ({
      enable = true;
    } // optionalAttrs (cfg.tailscale.authKeySops != null) {
      # The key file is materialised by sops-nix in the private overlay.
      authKeyFile = cfg.tailscale.authKeySops;
    });
  };
}
