# nixnas — headless remote store unlock via initrd-SSH.
#
# The store is unlocked in the INITRD, but the box is headless: nobody can type the
# PIN/passphrase at the console. So we bring the NIC up inside the initrd and run an
# sshd there — you `ssh root@<box>` and hand the secret to systemd's password agent,
# then the boot proceeds. This is the PRIMARY remote-unlock channel (IPMI-SOL, where
# present, is the alternative — set `boot.remoteUnlock.enable = false`). ARCHITECTURE §6.
#
# HOST KEY — the awkward part. The initrd sshd's host key must be EMBEDDED in the initrd
# (it runs before any disk is unlocked), so it cannot come from sops/`/run/secrets`. NixOS
# copies it in via the initrd-secrets mechanism, which couples two requirements that pull
# apart:
#   * the in-initrd DESTINATION must NOT be a store path (NixOS rejects that), and
#   * the SOURCE must be a properly-tracked store path, or it is absent from the disko
#     image-builder VM and `append-initrd-secrets` fails (`cp: No such file`).
# `boot.initrd.network.ssh.hostKeys` drives BOTH from one value, so we can't satisfy both
# with it alone. We therefore give it a clean non-store destination STRING and override the
# secret's SOURCE to a `builtins.path` store path (tracked → present in the builder VM).
#
# The key ends up on the PLAINTEXT ESP (inside the signed UKI) → keep this LAN/tailnet-only.
# Login keys are `nixnas.admin.authorizedKeys` — the same set as the running system's sshd.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  # Clean, non-store destination for the host key inside the initrd.
  hostKeyDest = "/etc/ssh/nixnas_initrd_host_ed25519_key";
  # The source as its OWN tracked store path (proper context ⇒ in the build closure ⇒
  # present in the disko builder VM). Lazy: only forced when hostKeyPath is non-null.
  hostKeySource = builtins.path {
    path = cfg.boot.remoteUnlock.hostKeyPath;
    name = "nixnas-initrd-host-key";
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.boot.remoteUnlock.enable) (lib.mkMerge [
    {
      assertions = [{
        assertion = cfg.boot.remoteUnlock.hostKeyPath != null;
        message = ''
          nixnas.boot.remoteUnlock is enabled but boot.remoteUnlock.hostKeyPath is null.
          The headless box needs a persistent initrd-SSH host key embedded at build time.
          Set it to a build-machine key path, or set boot.remoteUnlock.enable = false if you
          unlock over IPMI-SOL instead.
        '';
      }];

      # Bring networking up in the initrd, then run sshd there for the unlock hand-off.
      boot.initrd.network.enable = true;
      boot.initrd.network.ssh = {
        enable = true;
        port = 22;
        authorizedKeys = cfg.admin.authorizedKeys;
      };
      # With systemd-initrd the classic udhcpc path is off; networkd handles the link, but
      # `network.enable` alone declares no .network, so the NIC would get no lease. DHCP every
      # ethernet link explicitly so the box is reachable for the unlock.
      boot.initrd.systemd.network = {
        enable = true;
        networks."10-uplink" = {
          matchConfig.Name = "en* eth*";
          networkConfig.DHCP = "yes";
        };
      };

      # The NIC drivers the initrd must load to get on the network (merges with image.nix).
      boot.initrd.availableKernelModules = [
        "virtio_net"                                   # VM testing
        "e1000e" "igb" "igc" "r8169" "tg3" "atlantic"  # common server/desktop NICs
      ];
    }

    # Host key wiring — only when supplied (else the assertion above reports cleanly).
    (lib.mkIf (cfg.boot.remoteUnlock.hostKeyPath != null) {
      # A non-store STRING destination (NixOS uses it verbatim as the in-initrd HostKey path).
      boot.initrd.network.ssh.hostKeys = [ hostKeyDest ];
      # Override the auto-derived secret SOURCE (which would be the bogus dest path) with the
      # real, tracked key — so it is copied into the initrd during the image build.
      boot.initrd.secrets.${hostKeyDest} = lib.mkForce hostKeySource;
    })
  ]);
}
