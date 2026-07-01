# nixnas — the public option surface.
#
# Every site-specific value a host provides lives under `nixnas.*`. This file
# DECLARES the API; the implementation modules (boot/crypto/storage/…) READ it.
# It is FOSS-clean: no literals, only typed options with descriptions.
#
# SCOPE: nixnas owns boot / crypto / the USB store / kernel-packaging only.
# k3s, GPU, Samba/NFS, the Arch LXC, the Office VM, the apps are NOT nixnas —
# they are plain NixOS the operator declares in their own repo. See docs/SCOPE.md.
{ lib, ... }:
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
          type = types.nullOr types.path;
          default = null;
          description = ''
            Build-machine path to the file holding the store's LUKS passphrase, used ONCE to
            `luksFormat` the store at image-build time (it becomes the recovery keyslot; the
            TPM2+PIN keyslot is enrolled later on the real hardware). The TUI writes the
            operator's passphrase to a gitignored file and points this at it, then shreds it
            after the build. Null = the public demo passphrase `nixnas-demo`. NOTE: whatever
            this contains is briefly a world-readable store path on the BUILD machine — build
            on a trusted box. See docs/ARCHITECTURE §6.
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
        type = types.enum [ "x86_64-v1" "x86_64-v2" "x86_64-v3" "x86_64-v4" "znver3" "native" ];
        default = "x86_64-v1";
        description = ''
          Microarchitecture build target. Default `x86_64-v1` boots anywhere (the safe
          general-distro default). A host built for a known CPU sets `x86_64-v3`/`znver3`/
          `native` — safe because the image is built locally for that box.
        '';
      };
      lto = mkOption {
        type = types.enum [ "none" "thin" "full" ];
        default = "thin";
        description = "Link-time optimisation. `thin` is cheap + measurable; `full` is RAM-heavy for little gain.";
      };
      cpusched = mkOption {
        type = types.enum [ "eevdf" "bore" "bmq" "rt" "rt-bore" ];
        default = "eevdf";
        description = "CPU scheduler. `eevdf` is the server-correct baseline; `bore` favours desktop interactivity.";
      };
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
        example = literalExpression ''{ tubearchv = "/dev/disk/by-id/ata-ST5000…"; }'';
        description = ''
          LUKS members to unlock in stage-2, as `name → /dev/disk/by-id/…`. Each opens as
          `/dev/mapper/<name>` (a STABLE mapper name you then reference in `fileSystems`),
          with the SINGLE shared passphrase — the store's TPM2 PIN, reused across devices via
          the kernel keyring — NON-fatally (a missing one never blocks boot). Storage-agnostic:
          LUKS-under-ZFS / btrfs / xfs are all the same here. nixnas only OPENS these; you
          MOUNT the result with native NixOS (`fileSystems`, `boot.zfs.extraPools`) at any
          mount point, and route persistent state onto them with `environment.persistence`
          (the impermanence module). No `luksFormat`, ever.
        '';
      };
      zfsPools = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "hot" "cold" ]'';
        description = ''
          Optional convenience: ZFS pool names to import NON-fatally (`boot.zfs.extraPools`,
          with `devNodes=/dev/mapper` for ZFS-on-LUKS). Non-ZFS storage needs nothing here —
          mount it with plain `fileSystems`.
        '';
      };
    };

    ## ── Store behaviour on the slow stick ─────────────────────────────────
    store = {
      preload = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Warm the booted generation's closure into the (compress-)cache after boot, so
          runtime reads come from RAM and the slow stick is untouched — "copytoram done
          right" (compressed in RAM, self-update intact). Default on; turn off on very
          RAM-constrained boxes. See docs/OPTIMIZATIONS.md §5.
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
