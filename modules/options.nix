# nixnas — the public option surface.
#
# Every site-specific value a host provides lives under `nixnas.*`. This file
# DECLARES the API; the implementation modules (boot/crypto/storage/compute/…)
# READ it. It is FOSS-clean: no literals, only typed options with descriptions.
{ lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types literalExpression;

  diskById = types.strMatching "/dev/disk/by-id/.+";

  poolType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "ZFS pool name (e.g. the HOT pool `hot`, the COLD pool `cold`).";
      };
      disks = mkOption {
        type = types.listOf diskById;
        description = ''
          Member disks by stable `/dev/disk/by-id` path. LUKS-under-ZFS: each disk
          is a LUKS2 device and ZFS sits directly on the decrypted mapper.
        '';
      };
      topology = mkOption {
        type = types.enum [ "single" "mirror" "raidz1" "raidz2" "raidz3" ];
        default = "mirror";
        description = "vdev topology across `disks`.";
      };
    };
  };
in
{
  options.nixnas = {
    enable = mkEnableOption "the nixnas appliance (RAM-root OS, A/B updates, encrypted data pools, k3s)";

    hostName = mkOption {
      type = types.str;
      example = "nas";
      description = ''
        Machine hostname. Keep it stable across re-images: the k3s/k8s node
        identity and node-pinned workloads key off it.
      '';
    };

    ## ── Boot: A/B slots, Secure Boot, USB layout ──────────────────────────
    boot = {
      tries = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "Boot-counting attempts per A/B slot before automatic rollback to the other slot.";
      };
      secureBoot = {
        enable = mkEnableOption "UEFI Secure Boot with the operator's OWN keys (Microsoft keys not enrolled)";
        keysSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (provided by sops, hub-side only) to the Secure Boot `db` signing key. Never on the node.";
        };
      };
      usb = {
        espSizeMiB = mkOption {
          type = types.ints.positive;
          default = 1280;
          description = "FAT ESP size: signed systemd-boot + the two signed A/B UKIs.";
        };
        storeSizeMiB = mkOption {
          type = types.ints.positive;
          default = 5632;
          description = "f2fs store size: the two `squashfs` + dm-verity hash image pairs.";
        };
      };
    };

    ## ── Crypto: single passphrase = TPM2 PIN, recovery escrow ─────────────
    crypto = {
      tpm2 = {
        enable = mkEnableOption "bind LUKS unlock to TPM2 + PIN (the single passphrase IS the PIN)";
        pcrs = mkOption {
          type = types.listOf types.ints.unsigned;
          default = [ 7 ];
          description = ''
            TPM2 PCRs the unlock policy is bound to. PCR 7 (Secure Boot state) is
            the baseline: it is stable across A/B UKI updates, so a normal update
            needs no reseal. Signed PCR 11 (the measured UKI) is added as phase-2
            hardening.
          '';
        };
      };
      recovery = {
        vaultwardenUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Vaultwarden base URL the hub escrows the LUKS recovery key to. Private literal — set in the overlay.";
        };
        credsSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (sops, hub-side) to the Vaultwarden API client id/secret used for escrow.";
        };
      };
    };

    ## ── Storage: two fresh pools, explicit per-dataset placement ──────────
    storage = {
      pools = {
        hot = mkOption {
          type = poolType;
          description = "The HOT pool — SSD, fast (typically a mirror). Dataset placement here is the operator's explicit choice.";
        };
        cold = mkOption {
          type = poolType;
          description = "The COLD pool — HDD, capacity (typically raidz). Dataset placement here is the operator's explicit choice.";
        };
      };
      smrDisks = mkOption {
        type = types.attrsOf diskById;
        default = { };
        example = literalExpression ''{ archive0 = "/dev/disk/by-id/ata-…"; }'';
        description = "Standalone whole-disk-LUKS SMR archive disks, keyed by label → by-id path. xfs/btrfs sits directly on the decrypted mapper.";
      };
      specialVdev = {
        enable = mkEnableOption "a redundant ZFS `special` vdev on the COLD pool (metadata + small blocks on SSD — speed without file motion)";
        disks = mkOption {
          type = types.listOf diskById;
          default = [ ];
          description = "Mirror members for the `special` vdev (use ≥2 — a `special` vdev loss is a dataset loss).";
        };
      };
    };

    ## ── Compute: k3s + podman/quadlets + Arch (Incus) + the Office VM ──────
    compute = {
      k3s = {
        enable = mkEnableOption "native declarative k3s — the workload orchestrator";
        nodeName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "k8s node name. Pin it to preserve cluster identity across re-images. Null ⇒ use `hostName`.";
        };
        tokenSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (sops) to the persisted k3s server token (lives on an encrypted dataset).";
        };
      };
      archContainer = {
        enable = mkEnableOption "an Arch Linux system container via Incus (mutable pet userland + GPU desktop)";
      };
      gpu = {
        enable = mkEnableOption "AMD GPU (amdgpu + ROCm) shared into the Arch container and k3s pods";
        renderGid = mkOption {
          type = types.ints.unsigned;
          default = 303;
          description = "Fixed numeric GID for the `render` group — must match in every consumer (the #1 cause of `/dev/kfd` permission-denied).";
        };
      };
      officeVm = {
        enable = mkEnableOption "the Office VM — the ONLY libvirt domain on nixnas (all other VMs are retired)";
        zvol = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Path to the Office VM's backing zvol in the zvol folder (e.g. `/dev/zvol/<pool>/vm/office`). Private literal.";
        };
        xml = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "libvirt domain XML for the Office VM (consumed via NixVirt).";
        };
      };
    };

    ## ── Appliance plumbing ────────────────────────────────────────────────
    tailscale = {
      enable = mkEnableOption "Tailscale — management plane + stage-2 remote LUKS unlock over the tailnet";
      authKeySops = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path (sops) to the Tailscale auth key.";
      };
    };
  };
}
