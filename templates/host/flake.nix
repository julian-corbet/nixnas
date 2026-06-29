{
  description =
    "A private nixnas host — imports the public nixnas core, holds your real values + secrets.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixnas.url = "github:OWNER/nixnas"; # ← point at upstream or your own fork
    nixnas.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixnas, sops-nix, ... }: {
    nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixnas.nixosModules.nixnas
        sops-nix.nixosModules.sops
        ./host.nix
      ];
    };
  };
}
