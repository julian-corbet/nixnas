{
  description =
    "A private nixnas host — imports the public nixnas core, holds your real values + secrets.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Build-VM-only: disko's vmTools image builder breaks on current nixpkgs; use stable.
    # The image CONTENT is unaffected — it comes from nixpkgs (unstable) via the host config.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    # The CachyOS kernel (tuned, pre-built, binary-cached). NOT made to follow our nixpkgs.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
    nixnas = {
      url = "github:OWNER/nixnas"; # ← point at upstream or your own fork
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, nix-cachyos-kernel, disko, lanzaboote, impermanence, nixnas, sops-nix, ... }:
    let
      cfg = self.nixosConfigurations.nas;
    in
    {
      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          nixnas.nixosModules.nixnas
          sops-nix.nixosModules.sops
          ./host.nix
          # The CachyOS kernel set (pkgs.cachyosKernels); modules/boot/kernel.nix reads it.
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          # Build the throwaway image-builder VM from stable nixpkgs (avoids vmTools breakage).
          {
            disko.imageBuilder.pkgs = nixpkgs-stable.legacyPackages.x86_64-linux;
            disko.imageBuilder.kernelPackages = nixpkgs-stable.legacyPackages.x86_64-linux.linuxPackages;
          }
        ];
      };

      # `nix build .#image` builds the personalised USB image locally (the TUI invokes this).
      # `diskoImages` builds the .raw in the nix sandbox; `diskoImagesScript` runs a VM that
      # can inject the LUKS key via --pre-format-files (the path the TUI uses).
      packages.x86_64-linux = {
        image = cfg.config.system.build.diskoImages;
        imageScript = cfg.config.system.build.diskoImagesScript;
      };
    };
}
