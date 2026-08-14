# nixnas — impermanence: the USB system's root is tmpfs; only /nix and the ESP persist.
#
# The tmpfs root itself is declared in ./disk.nix as a disko `nodev` device (so the image
# builder can install into it). NixOS repopulates /etc from the store on every boot, so a
# stateless tmpfs root works for the OS. State that must survive a reboot (machine-id, SSH
# host keys, overlay-client identity, and the Secure Boot PKI) is routed onto encrypted /nix
# by appliance/identity.nix; the operator's real data lives on separate pools.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    # The store holds the whole system, so it MUST be mounted in stage-1.
    # (Merges with disko's generated /nix definition.)
    fileSystems."/nix".neededForBoot = true;

    # systemd-tmpfiles-setup.service is also present in the systemd initrd. Its oneshot state
    # can survive switch-root as "active (exited)" in the real-root manager transaction, so
    # the ordinary sysinit pull occasionally does not rerun it against the NEW tmpfs root.
    # The result is not cosmetic: /var/empty is absent and sshd refuses to start; /var/run is
    # not linked to /run and nsncd/login subsequently fail too. This is the exact race tracked
    # by systemd/systemd#38765; the live NixOS 26.11/systemd 260.2 image still reproduced it.
    #
    # A distinct stage-2-only unit cannot inherit the initrd unit's active state. Reapplying
    # only --create is idempotent and deliberately avoids a second cleanup pass. It must not
    # be ordered after the inherited systemd-tmpfiles-setup.service: that unit is ordered
    # before and conflicts with initrd-switch-root.target, so joining it back to the stage-2
    # transaction creates a cycle that makes systemd skip this pass and /run/wrappers.
    # Gate it to USB mode: a hot-mode main has an ordinary persistent root and no switch-root
    # into a freshly empty filesystem for this appliance to repair.
    systemd.services.nixnas-stage2-tmpfiles = lib.mkIf (cfg.store.location == "usb") {
      description = "Populate the nixnas tmpfs root after initrd switch-root";
      wantedBy = [ "sysinit.target" ];
      after = [ "local-fs.target" ];
      before = [ "sysinit.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/bin/systemd-tmpfiles --create --boot --exclude-prefix=/dev";
      };
    };
  };
}
