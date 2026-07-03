# nixnas — the public option surface.
#
# Every site-specific value a host provides lives under `nixnas.*`. This file
# DECLARES the API; the implementation modules (boot/crypto/storage/…) READ it.
# It is FOSS-clean: no literals, only typed options with descriptions.
#
# SCOPE: nixnas owns boot / crypto / the USB store / kernel-packaging only.
# k3s, GPU, Samba/NFS, the Arch LXC, the Office VM, the apps are NOT nixnas —
# they are plain NixOS the operator declares in their own repo. See docs/SCOPE.md.
{ config, lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types literalExpression;

  diskById = types.strMatching "/dev/disk/by-id/.+";
in
{
  options.nixnas = {
    enable = mkEnableOption "the nixnas appliance (USB-boot, impermanence, generations + rollback, encrypted data pools)";

    hostName = mkOption {
      type = types.str;
      example = "nas";
      description = ''
        Machine hostname. Keep it stable across re-images: node identity and
        host-pinned workloads key off it.
      '';
    };

    ## ── Boot: rollback, Secure Boot, USB layout ───────────────────────────
    boot = {
      tries = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          Boot-counting attempts a new generation gets before it is judged bad and the
          bootloader falls back to the previous one. Each boot decrements the counter;
          reaching `boot-complete.target` clears it (the generation is blessed). This is the
          AUTOMATIC failsafe layer — the manual generation menu is the guaranteed fallback.
        '';
      };
      keepGenerations = mkOption {
        type = types.ints.positive;
        default = 8;
        description = ''
          How many past generations to keep bootable (the rollback menu depth, and the
          structural failsafe). Bounded by the ESP: each kept generation is one signed UKI
          (~80 MiB), so the default 8 fits the 1 GiB `usb.espSizeMiB`. Raise both together
          for deeper history. (Measured Boot, a later increment, caps this at 8.)
        '';
      };
      secureBoot = {
        enable = mkEnableOption "UEFI Secure Boot with the operator's OWN keys via lanzaboote (Microsoft keys not enrolled)";
        keysSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (provided by sops, build-machine only) to the Secure Boot `db` signing key. Never on the node.";
        };
      };
      remoteUnlock = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            initrd-SSH for the headless store unlock (MANDATORY by default): the box has
            no console, so the in-initrd PIN/passphrase prompt is reached over SSH. The NIC
            comes up in the initrd; you `ssh root@<box>` (keys in `admin.authorizedKeys`)
            and hand the secret to the password agent. Keep it LAN/tailnet-only — the initrd
            host key sits on the plaintext ESP. Where IPMI-SOL exists, that channel can
            replace this (set false). ARCHITECTURE §6.
          '';
        };
        sealHostKey = mkOption {
          type = types.bool;
          default = true;
          description = ''
            TPM-seal the initrd-SSH host key (to PCR 7) instead of shipping it plaintext on
            the ESP. On first boot the key is generated and sealed to this box's TPM; every
            boot the initrd unseals it before sshd — a tampered boot chain (PCR mismatch)
            can't recover it, so a stolen stick can't impersonate the box's unlock prompt.
            PCR 7 (Secure Boot state) is update-stable (no reseal on kernel updates). Requires
            `crypto.tpm2.enable`. Set false to fall back to the plaintext `hostKeyPath`.
          '';
        };
        hostKeyPath = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Plaintext initrd-SSH host key (a BUILD-MACHINE Nix path), used only when
            `sealHostKey = false` (no TPM, or IPMI-SOL boxes). It is embedded in the initrd
            and lands on the plaintext ESP — hence LAN/tailnet-only. With `sealHostKey = true`
            (the default) this is ignored; the key is generated + TPM-sealed on first boot.
          '';
        };
      };
      usb = {
        device = mkOption {
          type = types.str;
          default = "/dev/vda";
          example = "/dev/disk/by-id/usb-…";
          description = ''
            The target USB device. The default `/dev/vda` is what the disko image
            builder sees inside its build VM; the TUI overrides it with the real
            stick path when flashing a physical device. This is the ONLY device
            nixnas ever partitions.
          '';
        };
        imageSizeGiB = mkOption {
          type = types.ints.positive;
          default = 8;
          description = "Total image/stick size in GiB. The ESP takes `espSizeMiB`; the f2fs store takes the rest.";
        };
        espSizeMiB = mkOption {
          type = types.ints.positive;
          default = 1024;
          description = "FAT ESP size: lanzaboote-signed systemd-boot + one signed UKI per kept generation (~8 per GiB).";
        };
        luksPassphraseFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path INSIDE the image-builder VM of the file holding the store's LUKS
            passphrase, used ONCE to `luksFormat` the store at image-build time (it becomes
            the recovery keyslot; the TPM2+PIN keyslot is enrolled later on the real
            hardware). Null (the default) means the conventional path
            `/tmp/nixnas-luks.key`, which the TUI injects into the builder VM with
            `imageScript --pre-format-files` — the passphrase never touches the Nix store,
            and a build WITHOUT the injected file FAILS (fail-closed: no silent fallback).
            The public demo host instead points this at a store-path file holding the
            published demo passphrase `nixnas-demo` — an explicit, visible opt-in.
          '';
        };
      };
    };

    ## ── Kernel: the CachyOS kernel, tuned (see docs/KERNEL.md) ─────────────
    kernel = {
      variant = mkOption {
        type = types.enum [ "latest" "lts" "server" "hardened" ];
        default = "latest";
        description = "CachyOS kernel line from the xddxdd/nix-cachyos-kernel flake.";
      };
      march = mkOption {
        type = types.enum [ "x86_64-v1" "x86_64-v2" "x86_64-v3" "x86_64-v4" "zen4" "znver3" "native" ];
        default = "x86_64-v1";
        description = ''
          Microarchitecture build target. Default `x86_64-v1` boots anywhere (the safe
          general-distro default). For a known CPU pick the highest **cache-available** level so
          the box pulls a pre-built kernel instead of recompiling: the lantian cache carries
          `x86_64-v3/-v4` and `zen4` (`x86_64-v2` variants are flagged "no binary cache"
          upstream). A Zen 3 CPU (Ryzen 5000) is `x86_64-v3`; Zen 4 is `zen4`. `znver3`/`native`
          are NOT pre-built — selecting them forces a from-source kernel build on the box
          (avoid; kernel.nix errors early if the combo is absent from the pinned set).
        '';
      };
      lto = mkOption {
        type = types.enum [ "none" "thin" "full" ];
        default = "thin";
        description = "Link-time optimisation. `thin` is cheap + measurable; `full` is RAM-heavy for little gain.";
      };
      # (No cpusched option: the pre-built cachyosKernels variants bake eevdf in; a
      # scheduler knob here would be a silent no-op. Pick via `variant` if the flake
      # ever exposes scheduler variants.)
    };

    ## ── Crypto: single passphrase = TPM2 PIN (only the stick binds to the TPM) ──
    crypto = {
      tpm2 = {
        enable = mkEnableOption "bind LUKS unlock to TPM2 + PIN (the single passphrase IS the PIN, required every boot)";
        requirePin = mkOption {
          type = types.bool;
          default = true;
          description = ''
            STRICT (default): the TPM2 unlock also needs the PIN on EVERY boot — a
            powered-off box never auto-decrypts (max evil-maid resistance), but every
            boot needs an operator to enter the PIN (headless ⇒ over the remote-unlock
            channel). The alternative (false) is TPM2 PCR-only auto-unlock: the box
            self-recovers after a power cut and only demands the recovery key on TAMPER
            (PCR mismatch), trading some resistance for unattended resilience. ARCH §6.
          '';
        };
        pcrs = mkOption {
          type = types.listOf types.ints.unsigned;
          default = [ 7 ];
          description = ''
            TPM2 PCRs the unlock policy is bound to. PCR 7 (Secure Boot state) is the
            baseline: it is stable across UKI/generation updates, so a normal update
            needs no reseal. Signed PCR 11 (the measured UKI) is added as phase-2 hardening.
          '';
        };
      };
      recovery = {
        vaultwardenUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://vault.example.com";
          description = ''
            Vaultwarden/Bitwarden base URL to escrow a SEPARATE high-entropy recovery key to
            at provision time. This key is a distinct LUKS keyslot (break-glass) — independent
            of the daily TPM2 PIN and of any specific box's TPM (an AMD fTPM is wiped by a
            BIOS/NVRAM clear). Null = no escrow (the passphrase keyslot is then the only recovery).
          '';
        };
        credsSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Build-machine sops path to the Vaultwarden API client id/secret used for the escrow upload.";
        };
      };
    };

    ## ── ZFS: which OpenZFS to use for the operator's data pools ───────────
    zfs = {
      source = mkOption {
        type = types.enum [ "cachyos" "upstream" ];
        default = "cachyos";
        description = ''
          `cachyos`: the CachyOS ZFS fork that matches `kernel.variant = latest`
          (newer than upstream's cap). `upstream`: stock `zfs_2_4`, which then pins the
          kernel at/under the OpenZFS cap. Safety is structural (rollback + scrub),
          not the source — see docs/KERNEL.md §5.
        '';
      };
    };

    ## ── Storage: connect your existing storage. THIN by design ──────────────
    ## nixnas does NOT reinvent mounting — that is native NixOS (`fileSystems`,
    ## `boot.zfs`, `boot.initrd.luks.devices`). It adds only the one fiddly bit:
    ## unlocking your LUKS members with the SINGLE shared secret, non-fatally. It
    ## NEVER creates, formats, or destroys your storage; the only device it ever
    ## partitions is the USB boot stick.
    storage = {
      unlock = mkOption {
        type = types.attrsOf diskById;
        default = { };
        example = literalExpression ''{ archive0 = "/dev/disk/by-id/ata-…"; }'';
        description = ''
          LUKS data members to unlock POST-boot, as `name → /dev/disk/by-id/…`. Each opens
          as `/dev/mapper/<name>` (a STABLE mapper name you then reference in
          `fileSystems`). Members are `noauto`: the OS boots fully with no data secret, and
          the operator runs `nixnas-unlock` (over SSH/Tailscale), which raises
          `nixnas-storage.target` — members open SERIALLY with ONE passphrase (systemd's
          kernel-keyring cache covers the rest), NON-fatally (a missing disk never fails
          the set). Data members are passphrase-only by design: never TPM-bound, never
          keyfile-persisted — a seized disk yields nothing, and a disk pulled into another
          machine opens with the passphrase alone. Storage-agnostic: LUKS-under-ZFS /
          btrfs / xfs are all the same here. nixnas only OPENS these; you MOUNT the result
          with native NixOS `fileSystems` (add `"noauto"
          "x-systemd.wanted-by=nixnas-storage.target"` to their options) and gate
          dependent services on `nixnas-storage.target`. No `luksFormat`, ever.
        '';
      };
      zfsPools = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "hot" "cold" ]'';
        description = ''
          Optional convenience: ZFS pool names to import as part of the post-boot unlock.
          Each pool gets a `nixnas-import-<pool>` service (ordered after the LUKS unlocks,
          scanning `/dev/mapper`) pulled in by `nixnas-storage.target`; datasets self-mount
          at their `mountpoint` properties. Also enables ZFS support in the image
          (`boot.supportedFilesystems.zfs`). Non-ZFS storage needs nothing here — mount it
          with plain `fileSystems` hooked to the same target.
        '';
      };
    };

    ## ── Store location: OS /nix on the stick (usb) or on the operator's hot storage (hot) ──
    store = {
      location = mkOption {
        type = types.enum [ "usb" "hot" ];
        default = "usb";
        description = ''
          Where the OS's `/nix` store lives (see docs/HOT-MODE.md):
            "usb" (default): the whole OS store is on the USB stick (LUKS2+f2fs). Small
              appliances, max resilience — the OS boots from the stick even with the data
              pool down. The stick is the size ceiling.
            "hot": the MAIN system's `/nix` lives on the operator's own encrypted storage
              (`store.hot.*`, e.g. a ZFS dataset on an SSD pool — unlimited, install anything
              system-wide). The stick holds only the ESP + a self-contained RESCUE system
              (`rescue.*`). The operator ENTERS THEIR KEY in the initrd to unlock it (never
              auto/TPM). Hub-class boxes. NOT a composed store — two independent systems.
        '';
      };
      hot = {
        device = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot/system/nix";
          description = ''
            `hot` mode: the `fileSystems."/nix".device` for the MAIN system — the store that
            holds the full OS closure. A ZFS dataset name (with `fsType = "zfs"`), or a
            `/dev/mapper/<name>` for LUKS+ext4/btrfs/f2fs. Mounted by the initrd (neededForBoot)
            after `store.hot.unlock` opens the encryption.
          '';
        };
        fsType = mkOption {
          type = types.str;
          default = "zfs";
          example = "ext4";
          description = "Filesystem of `store.hot.device` (zfs/ext4/btrfs/f2fs/…). `zfs` pulls ZFS into the initrd; others don't.";
        };
        unlock = mkOption {
          type = types.attrsOf (types.strMatching "/dev/disk/by-[a-z]+/.+");
          default = { };
          example = literalExpression ''{ hot0 = "/dev/disk/by-id/ata-…"; }'';
          description = ''
            The LUKS members the INITRD must open (with the OPERATOR'S key — never TPM auto) to
            reach the hot store, as `name → /dev/disk/by-id/…` (opens at `/dev/mapper/<name>`).
            The operator enters the passphrase over initrd-SSH / console; the box blocks here
            until they do (data stays sealed). Same shape as `storage.unlock`, but in stage-1.
          '';
        };
        zpool = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot";
          description = "For `fsType = \"zfs\"`: the pool the initrd imports (via /dev/mapper) before mounting `store.hot.device`.";
        };
      };
      preload = mkOption {
        type = types.bool;
        default = config.nixnas.store.location == "usb";
        defaultText = literalExpression ''store.location == "usb"'';
        description = ''
          Warm the booted generation's closure into the (compress-)cache after boot, so
          runtime reads come from RAM and the slow stick is untouched — "copytoram done
          right" (compressed in RAM, self-update intact). Defaults ON in `usb` mode; OFF in
          `hot` mode, where /nix is already on the fast pool so warming it into RAM only
          wastes memory. Turn off on very RAM-constrained boxes. See docs/OPTIMIZATIONS.md §5.
        '';
      };
      maxClosureBytes = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = literalExpression "5 * 1024 * 1024 * 1024"; # ~5 GiB uncompressed
        description = ''
          Build-time BUDGET for the host's toplevel closure, in uncompressed bytes. When set,
          `system.build.storeClosureBudget` FAILS the build if the closure exceeds it — wire
          that attribute into your flake `checks` so CI (and every rebuild) enforces it.

          Why ONE number bounds everything: the on-stick f2fs store holds this closure per
          kept generation (compressed ~2.3× by zstd), and `store.preload` warms it into RAM.
          So a single budget caps BOTH the USB fit (`usb.imageSizeGiB` minus the ESP, across
          `boot.keepGenerations`) AND the preload RAM. A lean base+k3s+container-runtime host
          is ~4 GiB uncompressed (~1.8 GiB compressed / ~1.8 GiB RAM); heavy things — dev
          toolchains, agents, container images, data — belong in build pods / containers on
          your pool, NEVER the host OS. The budget makes "it stays lean" structural: an
          accidental fat package fails the build instead of silently overflowing the stick.
        '';
      };
      persistLogs = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Persist the journal to the USB stick instead of RAM. DEFAULT OFF — normally logs
          are volatile (RAM) so the stick takes ~no writes. Turn this on only TEMPORARILY, to
          debug a problem whose evidence must survive a reboot/crash (e.g. an unlock or boot
          failure, where the data pools aren't up yet). It writes the stick, so turn it back
          off when done.
        '';
      };
    };

    ## ── Rescue system (hot mode only): the self-contained system on the stick ──
    rescue = {
      enable = mkOption {
        type = types.bool;
        default = config.nixnas.store.location == "hot";
        description = ''
          Whether the MAIN (hot) system maintains a RESCUE system on the stick (builds it,
          copies its closure to the stick store, and keeps its signed UKI on the ESP current
          — see modules/appliance/rescue-maintain.nix). Defaults on in `hot` mode; there is no
          rescue in `usb` mode (the whole OS already lives on the stick).
        '';
      };
      flakeAttr = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "nixnas-rescue";
        description = ''
          The `nixosConfigurations.<attr>` name of the RESCUE system — a SECOND, minimal
          `usb`-mode nixnas (sharing this host's appliance identity: kernel/pin, admin keys,
          Secure Boot keys). The MAIN system's maintainer builds it from the SAME flake ref as
          `autoUpgrade.flake` (i.e. the LATEST pulled revision, so it never goes stale after a
          main update) at `<flake>#nixosConfigurations.<attr>.config.system.build.toplevel`, and
          from the same nixpkgs pin (load-bearing — the rescue's ZFS/kernel must always import
          the live pool). Required when `rescue.enable`.
        '';
      };
      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = literalExpression "[ pkgs.claude-code pkgs.git ]";
        description = ''
          Packages to include in the `hot`-mode RESCUE system (the small self-contained
          system on the stick that boots when the pool is down). The rescue always carries
          the repair essentials (zfs, cryptsetup, tpm2, sshd, a shell); this adds the
          operator's own tools — e.g. an AI CLI you want available EXACTLY when you are
          debugging a broken pool. They ride the stick's f2fs store and update via autoUpgrade
          when they change (kept within the stick budget). Ignored in `usb` mode.
        '';
      };
    };

    ## ── Appliance plumbing ────────────────────────────────────────────────
    admin = {
      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "ssh-ed25519 AAAA… you@host" ]'';
        description = ''
          SSH public keys that may log in as root — for BOTH the running system (headless
          admin once booted) and the initrd (remote store unlock). The box is headless and
          key-only: password login is off, so at least one key is required for any access.
        '';
      };
    };

    tailscale = {
      enable = mkEnableOption "Tailscale — headless management plane + remote LUKS unlock path";
      authKeySops = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path (sops) to the Tailscale auth key.";
      };
    };

    ## ── Self-update (autoUpgrade) ─────────────────────────────────────────
    autoUpgrade = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let the box self-update from `autoUpgrade.flake` (no effect until that is set).
          It STAGES a new generation for the next boot — it never reboots itself (see
          `flake`). Updating the appliance = committing to the operator's flake.
        '';
      };
      flake = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "github:you/nas-config#nas";
        description = ''
          The operator's flake (their config that `imports = [ nixnas ]`). Null = no
          self-update. Private flakes need pull auth the operator supplies (deploy key /
          netrc); that, and update-on-the-8 GiB-target, is the autoUpgrade spike (ARCH §9.2).
        '';
      };
      schedule = mkOption {
        type = types.str;
        default = "04:40";
        description = "systemd `OnCalendar` schedule for the self-update check.";
      };
    };
  };
}
