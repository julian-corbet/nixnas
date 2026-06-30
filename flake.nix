{
  description =
    "nixnas — a declarative NixOS NAS appliance: USB-boot, impermanence, generations + rollback, encrypted, Evil-Maid-hardened.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Build-VM-only: disko's vmTools image builder breaks on current nixpkgs (the new
    # vmTools wants kernel.target, which disko's aggregateModules kernel lacks). We run
    # the throwaway image-builder VM from a stable nixpkgs (older vmTools). The image
    # CONTENT is unaffected — it comes from `nixpkgs` (unstable) via the host config.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    # The CachyOS kernel (tuned, pre-built, binary-cached). `release` branch = pre-built
    # variants; the `pinned` overlay (applied below) keeps cache hits. NOT made to follow
    # our nixpkgs — the pinned kernels are built against its own lock, which is what the
    # lantian cache was built for. See docs/KERNEL.md.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, nix-cachyos-kernel, disko, lanzaboote, ... }:
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
          lanzaboote.nixosModules.lanzaboote
          self.nixosModules.nixnas
          ./hosts/demo
          ./test/verify-image.nix   # DEV self-check (f2fs compression report on the console)
          ./test/verify-tpm2.nix    # DEV self-check (TPM2+PIN enrollment against swtpm)
          ./test/verify-writes.nix  # DEV self-check (USB stick write-isolation)
          # The CachyOS kernel set (pkgs.cachyosKernels); modules/boot/kernel.nix reads it.
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          # Build the throwaway image-builder VM from stable nixpkgs (see inputs above).
          {
            disko.imageBuilder.pkgs = nixpkgs-stable.legacyPackages.x86_64-linux;
            disko.imageBuilder.kernelPackages = nixpkgs-stable.legacyPackages.x86_64-linux.linuxPackages;
          }
        ];
      };

      # `nix flake check` proves the demo toplevel builds without the private overlay.
      checks = forAllSystems (system: {
        demo-toplevel = self.nixosConfigurations.demo.config.system.build.toplevel;
      });

      # The personalised USB image. The TUI builds this locally for a real host; here
      # `packages.image` builds the demo image (disko, placeholder config, zero secrets).
      # `diskoImages` builds the .raw in the nix sandbox; `diskoImagesScript` runs a VM
      # (the path the TUI uses, since it can inject the LUKS key via --pre-format-files).
      packages = forAllSystems (system: {
        image = self.nixosConfigurations.demo.config.system.build.diskoImages;
        imageScript = self.nixosConfigurations.demo.config.system.build.diskoImagesScript;
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
