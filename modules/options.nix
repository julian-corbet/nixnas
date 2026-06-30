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

  # A pool nixnas IMPORTS. nixnas NEVER creates, formats, or destroys data pools —
  # the operator builds them by hand. nixnas only LUKS-unlocks the members and
  # `zpool import`s by name (topology is discovered on import, never specified here).
  poolImport = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "ZFS pool name to import (e.g. `hot`, `cold`). You create the pool manually; nixnas only imports it — it never creates or formats it.";
      };
      luksDevices = mkOption {
        type = types.listOf diskById;
        default = [ ];
        description = ''
          The LUKS member devices to unlock (by stable `/dev/disk/by-id` path) before
          importing the pool. nixnas OPENS these with the single passphrase; it never
          `luksFormat`s or wipes them.
        '';
      };
    };
  };
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
        description = "systemd-boot boot-counting attempts before automatic rollback to the previous generation.";
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
        hostKeyPath = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Persistent initrd-SSH host key — the box's stable unlock identity across
            re-images. A Nix path to a BUILD-MACHINE key file (NOT /run/secrets: it is
            embedded in the initrd, which is assembled before any disk is unlocked). The TUI
            writes the operator's key and points this at it. Required when
            `boot.remoteUnlock.enable` is true. The key lands on the plaintext ESP (inside
            the signed UKI) — hence LAN/tailnet-only.
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

    ## ── Crypto: single passphrase = TPM2 PIN, recovery escrow ─────────────
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
          description = "Vaultwarden base URL the build machine escrows the LUKS recovery key to. Private literal — set in the overlay.";
        };
        credsSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (sops, build-machine) to the Vaultwarden API client id/secret used for escrow.";
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

    ## ── Storage: IMPORT-ONLY. nixnas never creates/formats/destroys data pools ──
    ## You build the pools by hand; nixnas only imports + unlocks them. The only
    ## device nixnas ever partitions/formats is the USB boot stick.
    storage = {
      pools = {
        hot = mkOption {
          type = poolImport;
          description = "The HOT pool (SSD) to import. Operator-created; nixnas imports + LUKS-unlocks it, never creates or formats it.";
        };
        cold = mkOption {
          type = poolImport;
          description = "The COLD pool (HDD) to import. Operator-created; nixnas imports + LUKS-unlocks it, never creates or formats it.";
        };
      };
      smrDisks = mkOption {
        type = types.attrsOf diskById;
        default = { };
        example = literalExpression ''{ archive0 = "/dev/disk/by-id/ata-…"; }'';
        description = ''
          Standalone whole-disk-LUKS SMR archive disks to unlock + mount, keyed by
          label → `/dev/disk/by-id` path. nixnas unlocks and mounts the EXISTING
          filesystem; it never formats them.
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
  };
}
