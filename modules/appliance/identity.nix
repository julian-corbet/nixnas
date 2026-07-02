# nixnas — stable identity, persisted on the encrypted stick store.
#
# The tmpfs root forgets everything; the data pools unlock only POST-boot. Identity
# must live between the two: on /nix (the LUKS2+f2fs store, mounted in stage-1) at
# /nix/persist. This is what makes the "boots reachable, data still locked" state
# trustworthy:
#
#   * machine-id      — stable node identity (systemd, journal cursors, DHCP DUIDs)
#   * SSH host keys   — the operator's client PINS these; they authenticate the very
#                       channel the data passphrase is typed into (the evil-maid gate:
#                       a swapped/tampered stick cannot present them)
#   * tailscale state — the box rejoins the tailnet BEFORE any data is unlocked
#   * /var/lib/nixos  — dynamic uid/gid maps (stable file ownership across reboots —
#                       matters because service state lives on the data pools)
#
# All tiny and rarely written — kind to the stick. Heavy state (containers, app
# data) belongs on the operator's pools, gated on nixnas-storage.target.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  persist = "/nix/persist";
in
{
  config = lib.mkIf cfg.enable {
    # The bind SOURCES must exist before stage-1 mounts them; /sysroot/nix is up
    # once the sysroot store mount is in place.
    boot.initrd.systemd.services.nixnas-persist-dirs = {
      description = "Create the nixnas identity-persistence directories";
      wantedBy = [ "initrd-fs.target" ];
      after = [ "sysroot-nix.mount" ];
      before = [ "sysroot-var-lib-tailscale.mount" "sysroot-var-lib-nixos.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p \
          /sysroot${persist}/etc \
          /sysroot${persist}/ssh \
          /sysroot${persist}/var/lib/tailscale \
          /sysroot${persist}/var/lib/nixos
      '';
    };

    # Bound in stage-1 (neededForBoot) so the state is in place BEFORE stage-2
    # activation runs — /var/lib/nixos in particular is read/written by the
    # users-groups activation itself.
    fileSystems."/var/lib/nixos" = {
      device = "${persist}/var/lib/nixos";
      fsType = "none";
      options = [ "bind" ];
      neededForBoot = true;
    };
    fileSystems."/var/lib/tailscale" = {
      device = "${persist}/var/lib/tailscale";
      fsType = "none";
      options = [ "bind" ];
      neededForBoot = true;
    };

    # machine-id: generated ONCE into the store partition during activation (which
    # runs before systemd starts, so PID 1 always finds a valid, stable id) and
    # symlinked into the tmpfs /etc. NOT a bind mount: /etc does not exist yet in
    # stage-1, and NOT left to systemd: systemd-machine-id-setup would replace the
    # symlink with a fresh transient file on every boot.
    system.activationScripts.nixnas-identity = {
      deps = [ "etc" ];
      text = ''
        if [ ! -s ${persist}/etc/machine-id ]; then
          ${config.systemd.package}/bin/systemd-id128 new > ${persist}/etc/machine-id
        fi
        ln -sfn ${persist}/etc/machine-id /etc/machine-id
      '';
    };

    # The RUNNING system's SSH host key, generated on first boot straight onto the
    # store partition (sshd's own preStart handles generation). The initrd unlock
    # host key is separate (TPM2-sealed — modules/boot/remote-unlock.nix).
    services.openssh.hostKeys = [
      {
        path = "${persist}/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };
}
