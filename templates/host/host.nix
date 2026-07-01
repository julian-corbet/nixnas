# Your machine's real values + secrets live HERE, in your private repo.
# The public nixnas core never references this file.
#
# nixnas owns ONLY: boot / crypto / the USB store / kernel packaging.
# Everything else — services.k3s, hardware.amdgpu, Samba/NFS, QEMU VMs, apps —
# is plain NixOS you declare in your own modules ALONGSIDE this import.
# See docs/SCOPE.md for the exact boundary.
{ ... }:
{
  nixnas = {
    enable = true;
    hostName = "nas"; # your hostname

    # SSH public keys for root: remote LUKS unlock (initrd) + admin access (booted system).
    # At least one key is REQUIRED — password login is off.
    admin.authorizedKeys = [ "ssh-ed25519 AAAA… you@host" ];

    # initrd-SSH host key: the box's stable unlock identity across re-images. Generate it
    # ONCE and `git add` it in THIS (private) repo — flakes only see git-tracked files, and
    # it must be embedded in the initrd, so it cannot come from sops/`/run/secrets`:
    #   ssh-keygen -t ed25519 -N "" -f initrd_host_ed25519_key && git add -f initrd_host_ed25519_key
    boot.remoteUnlock.hostKeyPath = ./initrd_host_ed25519_key;

    # The USB stick nixnas partitions. This is the ONLY device nixnas ever touches.
    boot.usb.device = "/dev/disk/by-id/usb-…";

    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;

    # Your LUKS members as name → device (any FS on top — ZFS/btrfs/xfs). Each opens at
    # /dev/mapper/<name>. nixnas UNLOCKS these once with the shared passphrase; never formats.
    # You MOUNT them natively below. (A fully worked example is in examples/host.nix.)
    storage.unlock = {
      poolmember0 = "/dev/disk/by-id/ata-…-part1";  # a member of your HOT/COLD pool
      archive0    = "/dev/disk/by-id/ata-…";        # a whole-disk-LUKS archive drive, etc.
    };
    storage.zfsPools = [ "fast" "bulk" ];  # optional: import these ZFS pools (skip for non-ZFS)

    # Set to your box's CPU micro-architecture for a tuned build; default x86_64-v1 boots anywhere.
    kernel.march = "x86_64-v3";

    # The TUI sets NIXNAS_LUKS_PASSPHRASE_FILE to a transient file it shreds after the build;
    # needs `nix build --impure`.
    boot.usb.luksPassphraseFile =
      let p = builtins.getEnv "NIXNAS_LUKS_PASSPHRASE_FILE";
      in if p == "" then null else /. + p;

    tailscale.enable = true;

    # The flake this box self-updates from. Private flakes need pull auth (deploy key / netrc).
    autoUpgrade.flake = "github:you/nas-config#nas";
  };

  # ── Everything below is PLAIN NixOS — nixnas does not reinvent it ──────────────
  # Mounting is native. Mount your unlocked/imported storage wherever you like:
  #   fileSystems."/hot"  = { device = "hot/data";          fsType = "zfs"; };
  #   fileSystems."/cold" = { device = "/dev/disk/by-id/…";   fsType = "xfs";
  #                           options = [ "nofail" "noatime" ]; };   # e.g. an SMR archive drive
  #
  # Persist state off the tmpfs root onto your pools (the impermanence module):
  #   environment.persistence."/hot/state" = {
  #     directories = [ "/var/lib/rancher" "/var/lib/containerd" ];
  #   };
  #
  # And your actual workloads are just NixOS too — you bring them:
  #   services.k3s.enable = true;
  #   services.samba.enable = true;
  #   virtualisation.libvirtd.enable = true;
  #   ...

  system.stateVersion = "25.05";
}
