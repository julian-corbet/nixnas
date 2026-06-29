{
  description =
    "nixnas — a declarative, RAM-resident NixOS NAS appliance: boots from USB into RAM, A/B-updated, Evil-Maid-hardened.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Planned inputs (wired up as the design lands):
    # disko.url      = "github:nix-community/disko";       # declarative partitioning (ESP + f2fs + LUKS)
    # sops-nix.url   = "github:Mic92/sops-nix";            # secrets (age); recovery-key escrow creds
    # lanzaboote.url = "github:nix-community/lanzaboote";  # Secure Boot / signed UKIs
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # The reusable, FOSS-clean appliance module (parameterised via options).
      # nixosModules.nixnas = import ./modules;

      # The A/B USB image builder.
      # packages = forAllSystems (system: { image = ...; });

      # Host instantiations + secrets live in a private overlay, never in the public core.
      # nixosConfigurations.<host> = ...;

      inherit forAllSystems; # placeholder to keep the let-binding live until outputs land
    };
}
