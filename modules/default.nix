# nixnas — the reusable appliance module.
#
# Importing this module gives a host the full `nixnas.*` option surface
# (see ./options.nix) and the behaviour that turns a NixOS config into a
# USB-bootable, encrypted, rollback-safe appliance image.
#
# `nixfsCatalogue` (the f2fs compression recipe: mkfs feature bits, mount options, the kernel
# floor) is a REAL function argument here, not a module argument — flake.nix calls
# `import ./modules { nixfsCatalogue = nixfs.lib.catalogue; }` directly (not via the `imports`
# list, so this file is never handed the standard module args in its place). This module then
# partially-applies it to the three files below that actually need it (boot/kernel.nix,
# boot/disk.nix) by calling `import <file> { inherit
# nixfsCatalogue; }` before those files ever reach the module system, and leaves every other
# import a plain path exactly as before. The alternative — threading it through as
# `_module.args.nixfsCatalogue` — puts the name into the one namespace every module composed
# alongside this one shares. That is exactly the collision this shape exists to rule
# out by construction: nixvault (a sibling appliance-adjacent flake, also consuming nixfs's
# catalogue) picked the exact same argument name, and `_module.args` merges with
# `mergeOneOption`, which rejects a second definition of the same name even when the two values
# are identical — so no `inputs.follows` pin could have fixed it either; only ONE of the two
# flakes could still be setting `_module.args.nixfsCatalogue` at all. Closing over the value here
# instead means nixfsCatalogue never becomes a name in that shared namespace in the first place,
# so a sibling flake making the same choice about its own consumers cannot collide with this one,
# regardless of which argument name it happens to pick. The general rule this incident taught the
# family — a flake must never publish a fact through `_module.args` — is written down once, for
# every sibling, in nixfs's own README ("Family convention: consuming lib.catalogue ... never
# through `_module.args`").
{ nixfsCatalogue }:
{
  imports = [
    ./options.nix

    (import ./boot/disk.nix { inherit nixfsCatalogue; }) # disko on-stick layout: ESP + f2fs-zstd store
    ./boot/image.nix # early-boot geometry: initrd-systemd, USB media, data-pool modules
    ./boot/nixboot.nix # boot-stance bridge: nixnas.boot.* -> nixboot (loader/SB/remote-unlock/rollback)
    ./boot/impermanence.nix # tmpfs root; only /nix + ESP persist
    (import ./boot/kernel.nix { inherit nixfsCatalogue; }) # the tuned CachyOS kernel (nixnas.kernel.*)

    ./crypto/recovery-escrow.nix # break-glass recovery keyslot, escrowed to Vaultwarden (hub-side)

    ./storage/connect.nix # connect your storage: stage-2 LUKS unlock + optional ZFS import
    # (thin — mounting itself is native NixOS: fileSystems / boot.zfs)
    ./store/location.nix # store.location = usb | hot: the hot-mode MAIN /nix + initrd operator-key unlock
    ./store/budget.nix # the 8 GiB-stick guard: fail the build if the closure exceeds store.maxClosureBytes

    ./appliance/base.nix # stable identity (hostName) + Tailscale
    ./appliance/identity.nix # machine-id, SSH host keys, overlay-client state — persisted on the stick
    ./appliance/persist-enforce.nix # build-time gate: every StateDirectory-bearing service must be persisted or explicitlyEphemeral
    ./appliance/ssh.nix # headless admin sshd (key-only root)
    ./appliance/auth.nix # console login: root (+ optional admin user) by the ONE store passphrase
    ./appliance/auto-upgrade.nix # self-update: stage-only, never self-reboot
    ./appliance/optimizations.nix # ⬢ appliance defaults: journald→RAM, no disk swap, store.preload.
    #   The memory subsystem itself (zram/zswap/vm sysctls/oomd) is
    #   nixram's — composed in flake.nix, enabled here, values there.
    #   Each host must declare `nixram.level` once.
    ./appliance/switch.nix # `nixnas-switch`: detached (session-immune) activation + honest result report
    # NOTE: k3s / GPU / shares / the Arch LXC / the Office VM / the apps are NOT nixnas —
    # they are plain NixOS the operator declares in their own repo alongside
    # `imports = [ nixnas ]`. See docs/SCOPE.md.
  ];
}
