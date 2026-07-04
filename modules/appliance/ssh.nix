# nixnas — sshd for the RUNNING system (headless admin).
#
# SSH is the primary way in once the box has booted. Key-only, root login by key;
# the optional `nixnas.auth.adminUser` (appliance/auth.nix) gets the same keys.
# Keys come from `nixnas.admin.authorizedKeys` — the same set used by the initrd
# remote-unlock (modules/boot/remote-unlock.nix), so one keyset covers both boot
# phases. Console login (root/admin by the store passphrase) is auth.nix's job;
# passwords are never accepted over SSH.
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
