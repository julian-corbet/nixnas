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
    # the tmpfs root; you route state with `environment.persistence."/tank" = {...}`. We use
    # the community module rather than reinvent bind-mount routing.
    impermanence.url = "github:nix-community/impermanence";
  };

  outputs = { self, nixpkgs, nixpkgs-stable, nix-cachyos-kernel, disko, lanzaboote, impermanence, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      # Shared module list for every matrix nixosConfiguration (eval-level variants).
      # Mirrors demo-hot's builder plumbing; each matrix entry appends one variant overlay.
      matrixBase = [
        disko.nixosModules.disko
        lanzaboote.nixosModules.lanzaboote
        impermanence.nixosModules.impermanence
        self.nixosModules.nixnas
        ./hosts/demo
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

      # ZFS hot-mode variant: proves the ZFS hot boot path (LUKS vdevs, pool import in initrd).
      # Two LUKS members (qapool-luks0/luks1) form a stripe; the test feeder answers ONCE and
      # the kernel-keyring serialised unlock covers the second member. See test/hot-boot-zfs-test.sh.
      nixosConfigurations.demo-hot-zfs = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          self.nixosModules.nixnas
          ./hosts/demo
          ./hosts/demo-hot-zfs.nix
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

      # Upgrade-soak variant: N=5 generation cycles to prove lzbt keepGenerations pruning.
      # keepGenerations=3 so cycles 3-5 exercise the UKI eviction path. The 5 specialisations
      # (soak-gen-2..6) are pre-built here and nix-copied into the VM — no in-VM Nix eval.
      nixosConfigurations.demo-upgrade-soak = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          self.nixosModules.nixnas
          ./hosts/demo
          ./hosts/demo-upgrade-soak.nix
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

      # Matrix: cheap eval-level variants — one per real-operator persona.
      # Each is demo-base + the variant overlay; no image build, no QEMU needed.
      nixosConfigurations.matrix-no-tpm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/no-tpm.nix ];
      };
      nixosConfigurations.matrix-stick-4g = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/stick-4g.nix ];
      };
      nixosConfigurations.matrix-stick-16g = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/stick-16g.nix ];
      };
      nixosConfigurations.matrix-stick-32g = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/stick-32g.nix ];
      };
      nixosConfigurations.matrix-hot-ext4 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/hot-ext4.nix ];
      };
      nixosConfigurations.matrix-pin-strict = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/pin-strict.nix ];
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
        # The TUI compiles cleanly.
        tui-build = self.packages.${system}.tui;
        # ZFS hot-mode topology builds (ZFS initrd + LUKS vdevs).
        demo-hot-zfs-toplevel = self.nixosConfigurations.demo-hot-zfs.config.system.build.toplevel;
        # Soak specialisations evaluate and the host config is structurally valid.
        demo-upgrade-soak-toplevel = self.nixosConfigurations.demo-upgrade-soak.config.system.build.toplevel;
        # Matrix variant toplevels — prove all six personas evaluate and build.
        matrix-no-tpm-toplevel     = self.nixosConfigurations.matrix-no-tpm.config.system.build.toplevel;
        matrix-stick-4g-toplevel   = self.nixosConfigurations.matrix-stick-4g.config.system.build.toplevel;
        matrix-stick-16g-toplevel  = self.nixosConfigurations.matrix-stick-16g.config.system.build.toplevel;
        matrix-stick-32g-toplevel  = self.nixosConfigurations.matrix-stick-32g.config.system.build.toplevel;
        matrix-hot-ext4-toplevel   = self.nixosConfigurations.matrix-hot-ext4.config.system.build.toplevel;
        matrix-pin-strict-toplevel = self.nixosConfigurations.matrix-pin-strict.config.system.build.toplevel;
      });

      # The personalised USB image. The TUI builds this locally for a real host; here
      # `packages.image` builds the demo image (disko, placeholder config, zero secrets).
      # `diskoImages` builds the .raw in the nix sandbox; `diskoImagesScript` runs a VM
      # (the path the TUI uses, since it can inject the LUKS key via --pre-format-files).
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in {
        image = self.nixosConfigurations.demo.config.system.build.diskoImages;
        imageScript = self.nixosConfigurations.demo.config.system.build.diskoImagesScript;
        # The hub-side break-glass escrow tool (`nix run .#escrow-recovery -- enroll ...`).
        # Built per-host by the TUI; this demo build is for discovery/inspection.
        escrow-recovery = self.nixosConfigurations.demo.config.system.build.nixnasEscrowRecovery;
        # The guided TUI: `nix run .#tui` (or `nix build .#tui`).
        tui = pkgs.rustPlatform.buildRustPackage {
          pname = "nixnas-tui";
          version = (pkgs.lib.importTOML ./tui/Cargo.toml).package.version;
          src = ./tui;
          cargoLock.lockFile = ./tui/Cargo.lock;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          # The TUI shells out. `nix`/`sops`/`ssh` intentionally come from the operator's
          # OWN PATH (their flake, their keys), so we PREFIX (not replace) with only the
          # small, always-required device tools it can't assume are installed: gptfdisk
          # (sgdisk — the grow-to-fill partition extend), util-linux (blockdev/lsblk —
          # the exact byte-size read + device listing), cryptsetup + f2fs-tools (the
          # workbench grow: open the LUKS store, offline resize.f2fs, close), and
          # mkpasswd (the console-auth yescrypt hash the build injects). Without this,
          # the workbench grow degrades to a non-fatal warning and the build's auth-hash
          # step fails with an actionable message on hosts lacking the tools.
          postInstall = ''
            wrapProgram $out/bin/nixnas \
              --prefix PATH : ${pkgs.lib.makeBinPath [
                pkgs.gptfdisk
                pkgs.util-linux
                pkgs.cryptsetup
                pkgs.f2fs-tools
                pkgs.mkpasswd
              ]}
          '';
          meta = {
            description = "nixnas — guided TUI to configure, build, and flash a nixnas USB stick.";
            license = pkgs.lib.licenses.asl20;
            mainProgram = "nixnas";
          };
        };
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
