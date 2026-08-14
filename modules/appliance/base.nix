# nixnas — appliance basics: stable identity + ONE network stack (networkd) + Tailscale.
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

    # ── ONE network stack: systemd-networkd from initrd through stage 2 ──────────────
    # (FIELD-BACKLOG #1, first real deployment 2026-07-04.) The initrd already runs
    # networkd for the remote-unlock NIC (boot/remote-unlock.nix); stock NixOS stage 2
    # would then start dhcpcd — two DHCP stacks on one interface. Field evidence: the
    # stage-2 dhcpcd repeatedly failed its first start ("[FAILED] Failed to start DHCP
    # Client", later self-healed) while the initrd lease kept answering pings.
    # useNetworkd makes stage 2 networkd too (and nixpkgs' networkd module then sets
    # networking.dhcpcd.enable = mkDefault false — no dhcpcd at all). networkd
    # serialises per-link state (including the DHCP lease) under /run/systemd/netif,
    # which survives switch-root, so stage 2 ADOPTS the initrd's lease natively
    # instead of re-negotiating against it.
    networking.useNetworkd = mkDefault true;
    # Plug-in-and-DHCP still works, but NOT via networking.useDHCP's generic
    # translation: nixnas pins its own catch-all (below) so the behavior is owned and
    # documented by the nixnas.network.dhcp option, not by nixpkgs translation
    # defaults. The unit is the same shape nixpkgs would emit ("99-ethernet-default-
    # dhcp" in tasks/network-interfaces-systemd.nix, verified against the pinned
    # nixpkgs): Type=ether limits it to ethernet links, Kind=!* to PHYSICAL interfaces
    # (no veth/bridge/bond members — operators run k3s/containers on these boxes).
    # 99- means any operator-declared .network with a lower lexical name wins
    # per-interface. Multi-NIC guidance (bond or down) lives on the option.
    networking.useDHCP = mkDefault false;
    systemd.network.networks."99-nixnas-ethernet-dhcp" = mkIf cfg.network.dhcp {
      matchConfig = {
        Type = "ether";
        Kind = "!*"; # physical interfaces have no netdev kind
      };
      networkConfig = {
        DHCP = "yes";
        IPv6PrivacyExtensions = "kernel";
      };
    };

    # Optional tools for a USB-resident appliance. The independent nixrescue role owns recovery.
    environment.systemPackages =
      lib.optionals (cfg.store.location == "usb") cfg.store.extraPackages;

    services.tailscale = mkIf cfg.tailscale.enable ({
      enable = true;
    } // optionalAttrs (cfg.tailscale.authKeySops != null) {
      # The key file is materialised by sops-nix in the private overlay.
      authKeyFile = cfg.tailscale.authKeySops;
    });
  };
}
