# nixnas — sshd for the RUNNING system (headless admin).
#
# The box has no console, so SSH is the only way in once it has booted. Key-only,
# root login by key (the appliance has no other user). Keys come from
# `nixnas.admin.authorizedKeys` — the same set used by the initrd remote-unlock
# (modules/boot/remote-unlock.nix), so one keyset covers both boot phases.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        # Root may log in, but only by key (the appliance is administered as root).
        PermitRootLogin = "prohibit-password";
      };
    };
    users.users.root.openssh.authorizedKeys.keys = cfg.admin.authorizedKeys;
  };
}
