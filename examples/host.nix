# examples/host.nix — a fully worked EXAMPLE of an operator's host config.
#
# This is what lives in YOUR OWN (private) repo — real device-ids, keys, and workloads.
# The public nixnas core never sees it. `templates/host/` is the minimal scaffold you copy;
# this file is the fleshed-out reference showing the storage patterns end to end.
# All device-ids / names here are ILLUSTRATIVE placeholders.
#
# The through-line: the USB stick only ever holds the OS (loaded into RAM). EVERYTHING
# else — container images, databases, media, service state — is directed onto your POOLS.
# Nothing here writes the stick. Mounting is 100% native NixOS; nixnas only unlocks your
# LUKS members and never creates/formats/destroys anything.
{ lib, config, ... }:
{
  ## ── nixnas: the appliance mechanism (boot / crypto / store / kernel) ──────────
  nixnas = {
    enable = true;
    hostName = "nas";

    admin.authorizedKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
    boot.remoteUnlock.hostKeyPath = ./initrd_host_ed25519_key;   # generated + git-added here
    boot.usb.device = "/dev/disk/by-id/usb-Your_Stick_…";        # the ONLY device nixnas partitions
    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;
    kernel.march = "x86_64-v3";                                  # your CPU's baseline
    tailscale.enable = true;
    autoUpgrade.flake = "github:you/nas-config#nas";

    # The store passphrase = the TPM2 PIN; the TUI injects it transiently at build time.
    boot.usb.luksPassphraseFile =
      let p = builtins.getEnv "NIXNAS_LUKS_PASSPHRASE_FILE"; in if p == "" then null else /. + p;

    ## ── Storage, step 1: UNLOCK your LUKS members (the one thing nixnas adds) ────
    # name → device; each opens at /dev/mapper/<name> with the single shared passphrase,
    # non-fatally. An archive drive is just another entry — no special handling.
    storage.unlock = {
      fast0     = "/dev/disk/by-id/ata-SSD_A-part1";   # HOT pool member
      fast1     = "/dev/disk/by-id/ata-SSD_B-part1";   # HOT pool member (mirror)
      bulk0     = "/dev/disk/by-id/ata-HDD_A-part1";   # COLD pool member
      bulk1     = "/dev/disk/by-id/ata-HDD_B-part1";   # COLD pool member
      archive0  = "/dev/disk/by-id/ata-HDD_ARCHIVE";   # whole-disk-LUKS XFS archive drive
    };
    # Storage, step 2: IMPORT the ZFS pools (native boot.zfs, non-fatal).
    storage.zfsPools = [ "fast" "bulk" ];   # the SSD (HOT) + HDD (COLD) pools
  };

  ## ── Storage, step 3: MOUNT — pure native NixOS (nixnas reinvents nothing) ─────
  # ZFS datasets mount themselves at their `mountpoint` property on import: `fast` → /fast,
  # `bulk` → /bulk, `bulk/media` → /bulk/media, … Declaring the parent explicitly makes the
  # dependency graph for the nested mount below unambiguous.
  fileSystems."/bulk/media" = { device = "bulk/media"; fsType = "zfs"; };

  # The NESTED foreign filesystem: a separate whole-disk-LUKS XFS drive mounted UNDER the
  # pool tree (this is the "an xfs drive packed under /bulk/media/archive" pattern). NixOS
  # orders it after its parent path is mounted; `nofail` keeps a missing drive non-fatal.
  fileSystems."/bulk/media/archive" = {
    device  = "/dev/mapper/archive0";      # the stable mapper from storage.unlock
    fsType  = "xfs";
    options = [ "nofail" "noatime" "inode64" "logbsize=256k" ];
  };

  ## ── Storage, step 4: put the WORKLOAD on the pools, NOT the stick ─────────────
  # Container images fill fast — point the runtime's data dir at a pool dataset so they land
  # on the SSD, never the 8 GB stick. (Anything you DON'T redirect lands in RAM via the
  # tmpfs root — never the stick.) Use whatever your workload exposes: a mount here, or the
  # tool's own data-dir/data-root option, or a k8s hostPath/PVC on a dataset.
  fileSystems."/var/lib/containerd" = { device = "fast/containerd"; fsType = "zfs"; };

  # Service state that must SURVIVE reboots (not your bulk data) → a pool, declaratively,
  # via the impermanence module. This is how you persist off the ephemeral RAM root.
  environment.persistence."/fast/state" = {
    hideMounts = true;
    directories = [ "/var/lib/rancher" "/var/lib/tailscale" "/var/lib/nixos" ];
    files = [ "/etc/machine-id" "/etc/ssh/ssh_host_ed25519_key" "/etc/ssh/ssh_host_ed25519_key.pub" ];
  };

  ## ── Your actual workloads — plain NixOS. nixnas neither knows nor cares. ──────
  services.k3s.enable = true;              # or docker/podman, nomad, …
  # services.samba.enable = true;
  # services.nfs.server.enable = true;
  # virtualisation.libvirtd.enable = true;

  # ZFS needs a stable host id; set your own.
  networking.hostId = "0a1b2c3d";
  system.stateVersion = "25.05";
}
