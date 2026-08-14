# examples/host.nix — a fully worked EXAMPLE of an operator's host config.
#
# This is what lives in YOUR OWN (private) repo — real device-ids, keys, and workloads.
# The public nixnas core never sees it. `templates/host/` is the minimal scaffold you copy;
# this file is the fleshed-out reference showing the storage patterns end to end.
# All device-ids / names here are ILLUSTRATIVE placeholders.
#
# The through-line: the USB stick only ever holds the OS (loaded into RAM) plus the box's
# small identity (machine-id, SSH host keys, and any nixnas.persist.overlayClients — the
# encrypted stick automatically persists those). EVERYTHING else — container images, databases, media,
# service state — is directed onto your POOLS, which unlock POST-boot: the box boots
# reachable with the data locked, you `ssh` in and run `nixnas-unlock`, ONE passphrase
# opens every member, the pools import, and the gated mounts + services below come up.
# nixnas only unlocks/imports; it never creates/formats/destroys anything.
{ lib, config, ... }:
{
  ## ── nixnas: the appliance mechanism (boot / crypto / store / kernel) ──────────
  nixnas = {
    enable = true;
    hostName = "nas";

    admin.authorizedKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
    boot.usb.device = "/dev/disk/by-id/usb-Your_Stick_…"; # the ONLY device nixnas partitions
    boot.secureBoot.enable = true;
    # TPM protects only the initrd-SSH identity; every LUKS volume still requires a passphrase.
    kernel.march = "x86_64-v3"; # your CPU's baseline
    tailscale.enable = true;
    persist.overlayClients = [ "tailscale" ]; # add other overlay/mesh clients (e.g. netbird) the same way
    autoUpgrade.flake = "github:you/nas-config#nas";

    # The store's LUKS passphrase is injected by the TUI at image-build time
    # (--pre-format-files); leaving this at null is the fail-closed real-host setup.

    ## ── Storage, step 1: UNLOCK your LUKS members (the one thing nixnas adds) ────
    # name → device; each opens at /dev/mapper/<name>, POST-boot, serially, with the
    # single passphrase you give `nixnas-unlock` — non-fatally. An archive drive is
    # just another entry — no special handling. Passphrase-only by design: a seized
    # disk reveals nothing, a disk in another machine opens with the passphrase alone.
    storage.unlock = {
      fast0 = "/dev/disk/by-id/ata-SSD_A-part1"; # fast pool (SSD) member
      fast1 = "/dev/disk/by-id/ata-SSD_B-part1"; # fast pool (SSD) member (mirror)
      bulk0 = "/dev/disk/by-id/ata-HDD_A-part1"; # bulk pool (HDD) member
      bulk1 = "/dev/disk/by-id/ata-HDD_B-part1"; # bulk pool (HDD) member
      archive0 = "/dev/disk/by-id/ata-HDD_ARCHIVE"; # whole-disk-LUKS XFS archive drive
    };
    # Storage, step 2: IMPORT the ZFS pools — nixnas-import-<pool> services, pulled in
    # by nixnas-storage.target. Datasets self-mount at their `mountpoint` properties on
    # import (`fast` → /fast, `bulk/media` → /bulk/media, …) — nothing to declare for them.
    storage.zfsPools = [ "fast" "bulk" ]; # the fast (SSD) + bulk (HDD) pools
  };

  ## ── Storage, step 3: MOUNT the non-ZFS pieces — native NixOS, hooked to the target ──
  # The mapper does not exist at boot (`noauto`); nixnas-storage.target pulls the mount
  # once nixnas-unlock has opened the member. Nesting under an imported pool's tree works:
  # systemd orders the mount after its parent path exists.
  fileSystems."/bulk/media/archive" = {
    device = "/dev/mapper/archive0"; # the stable mapper from storage.unlock
    fsType = "xfs";
    options = [ "noauto" "nofail" "x-systemd.wanted-by=nixnas-storage.target" "noatime" "inode64" "logbsize=256k" ];
  };

  ## ── Storage, step 4: put the WORKLOAD on the pools, NOT the stick ─────────────
  # Give heavy state a dataset whose `mountpoint` property IS the service dir (e.g.
  # `zfs set mountpoint=/var/lib/containerd fast/containerd`) — it mounts on import.
  # For state that must live under an existing dataset, bind-mount it, ordered after
  # the import (there is no .mount unit for zfs-property mounts to order against):
  fileSystems."/var/lib/rancher" = {
    device = "/fast/state/rancher";
    fsType = "none";
    options = [
      "bind"
      "noauto"
      "x-systemd.wanted-by=nixnas-storage.target"
      "x-systemd.requires=nixnas-import-fast.service"
      "x-systemd.after=nixnas-import-fast.service"
    ];
  };

  ## ── Your actual workloads — plain NixOS, GATED on the unlock. ─────────────────
  # Anything whose state sits on the pools must start with nixnas-storage.target, not
  # multi-user.target — before the unlock its data simply is not there.
  services.k3s.enable = true; # or docker/podman, nomad, …
  systemd.services.k3s = {
    wantedBy = lib.mkForce [ "nixnas-storage.target" ];
    after = [ "var-lib-rancher.mount" ];
    requires = [ "var-lib-rancher.mount" ];
  };
  # services.samba.enable = true;
  # services.nfs.server.enable = true;
  # virtualisation.libvirtd.enable = true;

  # ZFS needs a stable host id; set your own.
  networking.hostId = "0a1b2c3d";
  system.stateVersion = "25.05";
}
