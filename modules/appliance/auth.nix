# nixnas — product auth: console login with the ONE store passphrase.
#
# THE MODEL (decided after a locked console + locked emergency shell locked us out of a
# live box — three times in one day): NO autologin, no second secret to remember.
#   * root's console password IS the store passphrase. The TUI derives a yescrypt hash
#     from the passphrase at build time (`mkpasswd -m yescrypt --stdin`, see
#     tui/src/build.rs) and injects it as a RUNTIME file on the ENCRYPTED store:
#     /nix/nixnas/auth/passphrase.hash — never in the Nix store, and unreadable until
#     the LUKS store is open (at which point the passphrase has just been typed anyway,
#     so the hash file leaks nothing beyond what unlocking already proved).
#   * `auth.adminUser` (optional): ONE normal user in `wheel`, with the SAME hash file
#     and the admin SSH keys. sudo stays the NixOS default (wheel, WITH password).
#   * SSH stays key-only for everyone (appliance/ssh.nix: PasswordAuthentication off);
#     the passphrase opens CONSOLE sessions only.
#   * users.mutableUsers = false: /etc/shadow is regenerated from this declaration every
#     activation — no drifting runtime password state, no `passwd` surprises.
#
# FAIL-CLOSED when the hash file is MISSING (image built without the TUI step, or a
# hot-mode MAIN installed without it): NixOS's activation (update-users-groups.pl) only
# WARNS ("password file … does not exist") and writes `!` into the shadow field — the
# account is locked for password login, exactly the previous no-console-login behaviour,
# and boot proceeds normally. Verified by RUNNING that script from the pinned nixpkgs
# against a sandboxed /etc: missing file ⇒ `root:!:…`, present file ⇒ the hash. (The
# demo host's `initialPassword` also keeps working: for freshly-created users — every
# boot, on the tmpfs root — it is applied BEFORE the hashedPasswordFile branch, which on
# a missing file leaves it in place.)
#
# KNOWN LIMITATION — the initrd emergency shell stays locked. systemd's
# `boot.initrd.systemd.emergencyAccess` wants a hash at BUILD time, but our hash is a
# RUNTIME file on the (at that point still locked) encrypted store: a build-time copy
# would go stale the moment a stick is reflashed with a new passphrase, and stage-1
# cannot read the store before the unlock anyway. Deliberately NOT wired — rescue for a
# broken stage-1 is the generation menu / a second stick, not a shell.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  # The runtime hash file. Injected by the TUI build (`--post-format-files`); lives on
  # the encrypted f2fs store. The path is nixnas ABI — the TUI writes to it by name.
  passphraseHashFile = "/nix/nixnas/auth/passphrase.hash";
in
{
  config = lib.mkIf cfg.enable {
    # Declarative-only users: activation rebuilds /etc/shadow from THIS module each boot.
    users.mutableUsers = false;

    users.users = {
      # mkDefault: the public demo host overrides this with a store-path DEMO hash
      # (hosts/demo — an explicit, visible opt-in, like its demo LUKS passphrase).
      # Real hosts keep the runtime file.
      root.hashedPasswordFile = lib.mkDefault passphraseHashFile;
    }
    // lib.optionalAttrs (cfg.auth.adminUser != null) {
      ${cfg.auth.adminUser} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPasswordFile = passphraseHashFile;
        # Same keyset as root: one admin identity, two account flavours.
        openssh.authorizedKeys.keys = cfg.admin.authorizedKeys;
      };
    };

    # security.sudo is deliberately left at the NixOS default: enabled, wheel may sudo,
    # WITH password (the store passphrase, via the same hash). Nothing to configure.
  };
}
