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
    ./boot/kernel.nix        # the tuned CachyOS kernel (nixnas.kernel.*)
    ./boot/secureboot.nix    # UEFI Secure Boot via lanzaboote (operator-owned keys)
    ./boot/remote-unlock.nix # headless store unlock: initrd-SSH (NIC up in initrd)
    ./boot/rollback.nix      # structural failsafe: kept generations + boot-counting

    ./crypto/tpm2.nix        # TPM2+PIN store unlock (only the stick); first-boot enrollment
    ./crypto/recovery-escrow.nix   # break-glass recovery keyslot, escrowed to Vaultwarden (hub-side)

    ./storage/connect.nix    # connect your storage: stage-2 LUKS unlock + optional ZFS import
                             # (thin — mounting itself is native NixOS: fileSystems / boot.zfs)
    ./store/budget.nix       # the 8 GiB-stick guard: fail the build if the closure exceeds store.maxClosureBytes

    ./appliance/base.nix          # stable identity (hostName) + Tailscale
    ./appliance/identity.nix      # machine-id, SSH host keys, tailscale state — persisted on the stick
    ./appliance/ssh.nix           # headless admin sshd (key-only root)
    ./appliance/auto-upgrade.nix  # self-update: stage-only, never self-reboot
    ./appliance/optimizations.nix # ⬢ appliance defaults: zram, journald→RAM, no swap, store.preload
    # NOTE: k3s / GPU / shares / the Arch LXC / the Office VM / the apps are NOT nixnas —
    # they are plain NixOS the operator declares in their own repo alongside
    # `imports = [ nixnas ]`. See docs/SCOPE.md.
  ];
}
