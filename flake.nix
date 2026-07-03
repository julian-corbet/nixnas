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
    # Declarative persistence onto your pools (the impermanence module) — nixnas provides
    # the tmpfs root; you route state with `environment.persistence."/hot" = {...}`. We use
    # the community module rather than reinvent bind-mount routing.
    impermanence.url = "github:nix-community/impermanence";
  };

  outputs = { self, nixpkgs, nixpkgs-stable, nix-cachyos-kernel, disko, lanzaboote, impermanence, ... }:
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

      # Demo host — proves the public core evaluates standalone, with ZERO secrets.
      # Uses only RFC-5737 / RFC-2606 / DEMO-* placeholders.
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          self.nixosModules.nixnas
          ./hosts/demo
          ./test/verify-image.nix          # DEV self-check (f2fs compression report on the console)
          ./test/verify-tpm2.nix           # DEV self-check (TPM2+PIN enrollment against swtpm)
          ./test/verify-sealed-hostkey.nix # DEV self-check (TPM2-sealed initrd SSH host key)
          ./test/verify-recovery.nix       # DEV self-check (break-glass recovery keyslot, loopback LUKS)
          ./test/verify-writes.nix         # DEV self-check (USB stick write-isolation)
          # The CachyOS kernel set (pkgs.cachyosKernels); modules/boot/kernel.nix reads it.
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          # Build the throwaway image-builder VM from stable nixpkgs (see inputs above).
          # The host enables ZFS (boot.supportedFilesystems.zfs, for post-boot pool
          # import), so disko's make-disk-image wants the ZFS module IN THE BUILDER too —
          # under the host's package name (`zfs_cachyos`). The builder creates NO zfs
          # filesystem (nixnas only formats the f2fs store), so it just needs the attr to
          # resolve: alias `zfs_cachyos` → stable's `zfs` (builds against the builder's
          # own stable kernel; inert since no zfs partition is imaged).
          {
            disko.imageBuilder.pkgs = nixpkgs-stable.legacyPackages.x86_64-linux;
            disko.imageBuilder.kernelPackages =
              let sp = nixpkgs-stable.legacyPackages.x86_64-linux;
              # `linuxPackages.zfs` is a throw in 25.05 — use the canonical module attr
              # (sp.zfs.kernelModuleAttribute, e.g. "zfs_2_3") the nixpkgs error points to.
              in sp.linuxPackages.extend (_: _: {
                zfs_cachyos = sp.linuxPackages.${sp.zfs.kernelModuleAttribute};
              });
          }
        ];
      };

      # A hot-mode variant of the demo (store.location = "hot"): CI-builds the hot boot path
      # (modules/store/location.nix — /nix on an external operator-key-unlocked device). Shares
      # the demo's builder plumbing; drops the usb-image self-checks (verify-*), which assume
      # the f2fs stick. rescue.enable is off (keyless demo — see hosts/demo-hot.nix).
      nixosConfigurations.demo-hot = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          self.nixosModules.nixnas
          ./hosts/demo
          ./hosts/demo-hot.nix
          { nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ]; }
          {
            disko.imageBuilder.pkgs = nixpkgs-stable.legacyPackages.x86_64-linux;
            disko.imageBuilder.kernelPackages =
              let sp = nixpkgs-stable.legacyPackages.x86_64-linux;
              in sp.linuxPackages.extend (_: _: {
                zfs_cachyos = sp.linuxPackages.${sp.zfs.kernelModuleAttribute};
              });
          }
        ];
      };

      # `nix flake check` proves the demo toplevel builds without the private overlay, and
      # that its closure stays within the 8 GiB-stick budget (modules/store/budget.nix).
      checks = forAllSystems (system: {
        demo-toplevel = self.nixosConfigurations.demo.config.system.build.toplevel;
        demo-closure-budget = self.nixosConfigurations.demo.config.system.build.storeClosureBudget;
        # hot mode builds (location.nix + the hot wiring) …
        demo-hot-toplevel = self.nixosConfigurations.demo-hot.config.system.build.toplevel;
        # … and the rescue maintainer's shell passes shellcheck (writeShellApplication build).
        demo-rescue-maintainer = self.nixosConfigurations.demo.config.system.build.rescueMaintainer;
        # … and the hot installer's shell too (ships on usb systems — the rescue's install role).
        demo-hot-installer = self.nixosConfigurations.demo.config.system.build.hotInstaller;
      });

      # The personalised USB image. The TUI builds this locally for a real host; here
      # `packages.image` builds the demo image (disko, placeholder config, zero secrets).
      # `diskoImages` builds the .raw in the nix sandbox; `diskoImagesScript` runs a VM
      # (the path the TUI uses, since it can inject the LUKS key via --pre-format-files).
      packages = forAllSystems (system: {
        image = self.nixosConfigurations.demo.config.system.build.diskoImages;
        imageScript = self.nixosConfigurations.demo.config.system.build.diskoImagesScript;
        # The hub-side break-glass escrow tool (`nix run .#escrow-recovery -- enroll ...`).
        # Built per-host by the TUI; this demo build is for discovery/inspection.
        escrow-recovery = self.nixosConfigurations.demo.config.system.build.nixnasEscrowRecovery;
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
