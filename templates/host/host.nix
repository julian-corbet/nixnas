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

    # initrd-SSH host key: with the defaults (secureBoot + tpm2 below, sealHostKey=true)
    # the key is generated + TPM2-SEALED on first boot — nothing to provide here. Only a
    # box WITHOUT a TPM sets `boot.remoteUnlock.sealHostKey = false` and supplies a
    # plaintext key via `boot.remoteUnlock.hostKeyPath` (generate once, `git add -f` it in
    # THIS private repo; it lands on the plaintext ESP — LAN/tailnet-only).

    # The USB stick nixnas partitions. This is the ONLY device nixnas ever touches.
    boot.usb.device = "/dev/disk/by-id/usb-…";

    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;

    # Your LUKS members as name → device (any FS on top — ZFS/btrfs/xfs). Each opens at
    # /dev/mapper/<name>, POST-boot: the box boots reachable with the data locked, then
    # `nixnas-unlock` (over SSH) opens the whole set with ONE passphrase. nixnas never
    # formats. You MOUNT them natively below. (A fully worked example: examples/host.nix.)
    storage.unlock = {
      poolmember0 = "/dev/disk/by-id/ata-…-part1";  # a member of your ZFS pool
      archive0    = "/dev/disk/by-id/ata-…";        # a whole-disk-LUKS archive drive, etc.
    };
    storage.zfsPools = [ "fast" "bulk" ];  # optional: import these ZFS pools (skip for non-ZFS)

    # Set to your box's CPU micro-architecture for a tuned build; default x86_64-v1 boots anywhere.
    kernel.march = "x86_64-v3";

    # The store's LUKS passphrase is injected by the TUI at image-build time
    # (`--pre-format-files` into the builder VM) — nothing to set here, nothing in the
    # Nix store, and a build without it fails closed.

    tailscale.enable = true;

    # The flake this box self-updates from. Private flakes need pull auth (deploy key / netrc).
    autoUpgrade.flake = "github:you/nas-config#nas";
  };

  # ── Everything below is PLAIN NixOS — nixnas does not reinvent it ──────────────
  # ZFS datasets self-mount at their `mountpoint` property when nixnas-unlock imports
  # the pool. Foreign filesystems on unlocked mappers mount natively, hooked to the
  # unlock target (the mapper doesn't exist at boot):
  #   fileSystems."/bulk/archive" = { device = "/dev/mapper/archive0"; fsType = "xfs";
  #     options = [ "noauto" "nofail" "x-systemd.wanted-by=nixnas-storage.target" "noatime" ]; };
  #
  # Heavy service state belongs on the pools, gated on the unlock (identity —
  # machine-id, SSH host keys, tailscale — is already persisted on the stick by
  # nixnas). See examples/host.nix for the bind-mount + service-gating pattern.
  #
  # And your actual workloads are just NixOS too — you bring them:
  #   services.k3s.enable = true;   # gate it on nixnas-storage.target (examples/host.nix)
  #   services.samba.enable = true;
  #   virtualisation.libvirtd.enable = true;
  #   ...

  system.stateVersion = "25.05";
}
