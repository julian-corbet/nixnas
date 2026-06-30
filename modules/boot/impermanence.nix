# nixnas — impermanence: the root filesystem is tmpfs (RAM); only /nix and the ESP persist.
#
# The tmpfs root itself is declared in ./disk.nix as a disko `nodev` device (so the image
# builder can install into it). NixOS repopulates /etc from the store on every boot, so a
# stateless tmpfs root "just works" for the OS. State that must survive a reboot
# (machine-id, SSH host keys, the sbctl PKI, TPM2 enrollment) is persisted explicitly in a
# later increment; the operator's real data lives on the separate ZFS pools, never on the stick.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    # The store holds the whole system, so it MUST be mounted in stage-1.
    # (Merges with disko's generated /nix definition.)
    fileSystems."/nix".neededForBoot = true;
  };
}
