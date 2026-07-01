# Demo host — proves the public nixnas core evaluates standalone, with ZERO secrets.
#
# Every value is an RFC-5737 (203.0.113.0/24) / RFC-2606 (.invalid) / DEMO-*
# placeholder. This host ships in the PUBLIC repo; the real machine lives in a
# separate, private overlay (see ../../templates/host).
{ lib, ... }:
{
  nixnas = {
    enable = true;
    hostName = "demo";

    # Throwaway DEMO key (test/ssh/demo_key) — for the test VM only. A real host lists the
    # operator's own keys here; they authorise BOTH the initrd remote-unlock and admin sshd.
    admin.authorizedKeys = [ (lib.fileContents ../../test/ssh/demo_key.pub) ];
    # Throwaway DEMO initrd-SSH host key — test VM only (a real host's key is TUI-written).
    boot.remoteUnlock.hostKeyPath = ../../test/ssh/demo_initrd_host_ed25519_key;

    # Reference-box kernel tuning (a generic adopter would leave march at the x86_64-v1
    # default; we build for a known x86-64-v3 CPU). variant=latest, lto=thin, eevdf are defaults.
    kernel.march = "x86_64-v3";

    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;

    # Your LUKS members as name → device; each opens at /dev/mapper/<name> (non-fatal, so
    # these non-existent DEMO devices don't block the test boot). An SMR/XFS archive drive
    # is just another entry — no special handling. You mount the results with native
    # `fileSystems` and persist state with `environment.persistence` (see examples/host.nix).
    storage.unlock = {
      demossd0 = "/dev/disk/by-id/DEMO-ssd-0";
      demohdd0 = "/dev/disk/by-id/DEMO-hdd-0";
      demoarchv = "/dev/disk/by-id/DEMO-smr-0";
    };
    storage.zfsPools = [ "demohot" "democold" ];

    tailscale.enable = true;

    # DEMO placeholder so the demo exercises the self-update wiring (never pulled here).
    # A real host points this at its own flake; private flakes add pull auth.
    autoUpgrade.flake = "github:DEMO/nas-config#demo";
  };

  # INCREMENT 1: let the demo image be logged into in the test VM (placeholder only;
  # a real host authenticates via SSH keys / the unlock chain, not a root password).
  users.users.root.initialPassword = "nixnas";

  # ZFS (the operator's data pools) requires a stable host id; a real host sets its own.
  networking.hostId = "deadbeef";

  system.stateVersion = "25.05";
}
