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
    ./store/location.nix     # store.location = usb | hot: the hot-mode MAIN /nix + initrd operator-key unlock
    ./store/budget.nix       # the 8 GiB-stick guard: fail the build if the closure exceeds store.maxClosureBytes

    ./appliance/base.nix          # stable identity (hostName) + Tailscale
    ./appliance/identity.nix      # machine-id, SSH host keys, overlay-client state — persisted on the stick
    ./appliance/persist-enforce.nix # build-time gate: every StateDirectory-bearing service must be persisted or explicitlyEphemeral
    ./appliance/ssh.nix           # headless admin sshd (key-only root)
    ./appliance/auth.nix          # console login: root (+ optional admin user) by the ONE store passphrase
    ./appliance/auto-upgrade.nix  # self-update: stage-only, never self-reboot
    ./appliance/rescue-maintain.nix # hot mode: the main keeps the stick's RESCUE current (closure + signed UKI)
    ./appliance/install-hot.nix     # `nixnas-install-hot` on usb systems: install a hot-mode MAIN from the rescue
    ./appliance/optimizations.nix # ⬢ appliance defaults: journald→RAM, no disk swap, store.preload.
                                  #   The memory subsystem itself (zram/zswap/vm sysctls/oomd) is
                                  #   nixram's — composed in flake.nix, enabled here, values there.
                                  #   Each host must declare `nixram.level` once.
    ./appliance/switch.nix        # `nixnas-switch`: detached (session-immune) activation + honest result report
    # NOTE: k3s / GPU / shares / the Arch LXC / the Office VM / the apps are NOT nixnas —
    # they are plain NixOS the operator declares in their own repo alongside
    # `imports = [ nixnas ]`. See docs/SCOPE.md.
  ];
}
