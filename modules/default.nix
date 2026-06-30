# nixnas — the reusable appliance module.
#
# Importing this module gives a host the full `nixnas.*` option surface
# (see ./options.nix) and the behaviour that turns a NixOS config into a
# USB-bootable, encrypted, rollback-safe appliance image.
{ ... }:
{
  imports = [
    ./options.nix

    ./boot/disk.nix          # disko on-stick layout: ESP + f2fs-zstd store
    ./boot/image.nix         # UEFI boot chain glue (systemd-boot, serial, initrd modules)
    ./boot/impermanence.nix  # tmpfs root; only /nix + ESP persist
    # ./boot/{secureboot,rollback,remote-unlock}.nix   # next: lanzaboote, boot-counting, initrd-SSH

    ./crypto/tpm2.nix        # TPM2 device access (stage-2 unlock); enrollment is first-boot
    # ./crypto/{luks,recovery-escrow}.nix   # next: LUKS store + data-pool unlock, recovery escrow

    # ./storage/zfs-pools.nix  # IMPORT-ONLY pools — deferred from increment 1 (enabling ZFS needs
                               # networking.hostId + the CachyOS kernel); re-added with data-pool unlock.
    # ./storage/{smr-disks,shares}.nix   # next: SMR unlock+mount

    ./appliance/base.nix     # stable identity (hostName)
    # NOTE: k3s / GPU / shares / the Arch LXC / the Office VM / the apps are NOT nixnas —
    # they are plain NixOS the operator declares in their own repo alongside
    # `imports = [ nixnas ]`. See docs/SCOPE.md.
  ];
}
