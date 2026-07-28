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

    # nixram — the memory subsystem, and the SOLE owner of it. zram / zswap /
    # vm.* sysctls / systemd-oomd all derive from one declared RAM level
    # (`nixram.level`). nixnas used to hand-declare a slice of this
    # (zramSwap at 20%, and nothing at all about zswap, which is how a CachyOS
    # kernel's CONFIG_ZSWAP_DEFAULT_ON=y ended up silently armed in front of a
    # zram-only swap on a real 125 GiB deployment). Splitting one subsystem
    # across two owners is what produced that; nixnas now composes nixram and
    # declares no memory values of its own. Same mechanism-lives-in-its-own-flake
    # split nixnas already uses for the kernel and the boot chain.
    nixram = {
      url = "github:julian-corbet/nixram-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixboot — the boot domain (firmware handoff through switch-root), and the SOLE owner of
    # `nixboot.extraEntries`: the ukify+sbsign+place+rotate pipeline that used to live inline in
    # modules/appliance/rescue-maintain.nix, generalised there and consumed here for the
    # pinned/hub-built rescue persona only (see that file's own header for why the
    # self-upgrading persona cannot be represented by nixboot's declarative option surface, and
    # stays on the original inline pipeline). `nixboot.enable` itself is never turned on for a
    # nixnas host — nixnas keeps owning its OWN Secure Boot / lanzaboote wiring
    # (modules/boot/secureboot.nix) exactly as before; only the extraEntries option tree and its
    # unconditionally-exposed maintainer derivations are consumed. Same mechanism-lives-in-its-
    # own-flake split as nixram above.
    nixboot = {
      url = "github:julian-corbet/nixboot-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, nix-cachyos-kernel, disko, lanzaboote, impermanence, nixram, nixboot, ... }:
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
      # nixram rides along with the appliance module rather than being a separate
      # thing every consumer must remember to import: the memory subsystem is not
      # optional on an appliance that boots to a tmpfs root with no disk swap.
      # `import ./modules` and nixram's module are both PATH imports, so the
      # module system deduplicates them by key if a consumer happens to compose
      # nixram directly as well.
      nixosModules.nixnas = {
        imports = [
          (import ./modules)
          nixram.nixosModules.nixram
          # Both files of nixboot's own module (nixboot.nix + extra-entries.nix, bundled as
          # one nixosModules.nixboot) — needed even though `nixboot.enable` stays off on every
          # nixnas host, because `nixboot.extraEntries.*` (options.nix's own declarations) and
          # `system.build.extraEntryMaintainers` (unconditional passthrough) both live in that
          # same file pair. See modules/appliance/rescue-maintain.nix's header.
          nixboot.nixosModules.nixboot
        ];
      };
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

      # Hot mode + a PINNED rescue toplevel — proves the nixboot.extraEntries wiring end to end
      # in CI: `system.build.extraEntryMaintainers.rescue` must actually build (shellcheck
      # clean) from a REAL toplevel, and `nixnas-rescue-maintain` must be wired to call it (see
      # the `rescue-uki-pipeline-equivalence` check below). Reuses the demo's OWN toplevel as
      # the "rescue" toplevel purely to exercise the wiring cheaply — it is already built by the
      # demo-toplevel check above, so this adds no new closure to build — NOT a template for a
      # real host, which points rescue.toplevel at an actual minimal rescue nixosConfiguration
      # (see modules/options.nix's own rescue.toplevel doc). A separate hot-mode host (not
      # demo-hot.nix, which turns rescue off outright) so this file can set rescue.toplevel
      # without colliding with demo-hot.nix's own `rescue.enable = false`.
      nixosConfigurations.demo-hot-rescue-pinned = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          impermanence.nixosModules.impermanence
          self.nixosModules.nixnas
          ./hosts/demo
          ./hosts/demo-hot-rescue-pinned.nix
          {
            nixnas.rescue.enable = true;
            nixnas.rescue.toplevel = self.nixosConfigurations.demo.config.system.build.toplevel;
          }
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
      nixosConfigurations.matrix-persist-nested = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = matrixBase ++ [ ./hosts/matrix/persist-nested.nix ];
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
        # The pinned-rescue + nixboot wiring: the whole host evaluates+builds (exercises every
        # assertion in rescue-maintain.nix, including the espFileName/timer equivalence checks)…
        demo-hot-rescue-pinned-toplevel = self.nixosConfigurations.demo-hot-rescue-pinned.config.system.build.toplevel;
        # … and nixboot's OWN per-entry maintainer — built from a REAL toplevel — shellchecks
        # clean, proving `nixboot.extraEntries.rescue` is wired to something real, not a
        # dangling declaration.
        demo-hot-rescue-pinned-uki-maintainer = self.nixosConfigurations.demo-hot-rescue-pinned.config.system.build.extraEntryMaintainers.rescue;
        # A build-level (no VM needed) content proof that the pinned path actually calls
        # nixboot's maintainer, under the SAME ESP filename the original inline pipeline used —
        # the concrete "same ESP filename discipline" / "same rotation" equivalence check.
        rescue-uki-pipeline-equivalence =
          let pkgs = pkgsFor system; in
          pkgs.runCommand "nixnas-rescue-uki-pipeline-equivalence" { } ''
            script=${self.nixosConfigurations.demo-hot-rescue-pinned.config.system.build.rescueMaintainer}/bin/nixnas-rescue-maintain
            grep -q 'nixnas-rescue.efi' "$script" || {
              echo "FAIL: espFileName discipline — 'nixnas-rescue.efi' not found in the maintainer script" >&2
              exit 1
            }
            grep -q 'nixboot-extra-entry-rescue' "$script" || {
              echo "FAIL: the pinned branch does not invoke nixboot's built maintainer (nixboot-extra-entry-rescue) — it may have silently fallen back to (or never left) the inline pipeline" >&2
              exit 1
            }
            echo "PASS: pinned rescue-maintain hands off to nixboot-extra-entry-rescue under the nixnas-rescue.efi name" > "$out"
          '';
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
        # persist-enforce must recognize a StateDirectory nested under a bind-mounted
        # ancestor as persisted (modules/appliance/persist-enforce.nix ancestor walk) —
        # regression guard for a real production incident where a nested-persist ACME
        # state directory was wrongly flagged as non-persisted.
        matrix-persist-nested-toplevel = self.nixosConfigurations.matrix-persist-nested.config.system.build.toplevel;
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
