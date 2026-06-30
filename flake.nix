{
  description =
    "nixnas — a declarative, RAM-resident NixOS NAS appliance: boots from USB into RAM, A/B-updated, Evil-Maid-hardened.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # The reusable, FOSS-clean appliance module. All behaviour lives here,
      # parameterised through the `nixnas.*` options (see ./modules/options.nix).
      nixosModules.nixnas = import ./modules;
      nixosModules.default = self.nixosModules.nixnas;

      # The hub/TUI build library (pure; the image is built LOCALLY, never remote).
      lib = import ./lib { inherit (nixpkgs) lib; };

      # Demo host — proves the public core evaluates standalone, with ZERO secrets.
      # Uses only RFC-5737 / RFC-2606 / DEMO-* placeholders.
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          self.nixosModules.nixnas
          ./hosts/demo
        ];
      };

      # `nix flake check` proves the demo toplevel builds without the private overlay.
      checks = forAllSystems (system: {
        demo-toplevel = self.nixosConfigurations.demo.config.system.build.toplevel;
      });

      # The personalised USB image. The TUI builds this locally for a real host; here
      # `packages.image` builds the demo image (placeholder config, zero secrets).
      packages = forAllSystems (system: {
        image = self.nixosConfigurations.demo.config.system.build.image;
      });

      # The build-hub toolchain (sign / seal / escrow run here, never on the node).
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              sbsigntool
              systemdUkify
              tpm2-tools
              cryptsetup
              squashfsTools
              sops
              age
              bitwarden-cli
              jq
            ];
          };
        });

      # Scaffold a private host overlay that consumes this core as a flake input.
      templates.host = {
        path = ./templates/host;
        description = "A private nixnas host overlay (imports nixnas as a flake input).";
      };
    };
}
