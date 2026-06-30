# Demo host — proves the public nixnas core evaluates standalone, with ZERO secrets.
#
# Every value is an RFC-5737 (203.0.113.0/24) / RFC-2606 (.invalid) / DEMO-*
# placeholder. This host ships in the PUBLIC repo; the real machine lives in a
# separate, private overlay (see ../../templates/host).
{ ... }:
{
  nixnas = {
    enable = true;
    hostName = "demo";

    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;
    crypto.recovery.vaultwardenUrl = "https://vault.demo.invalid";

    storage.pools.hot = {
      name = "demohot";
      luksDevices = [ "/dev/disk/by-id/DEMO-ssd-0" "/dev/disk/by-id/DEMO-ssd-1" ];
    };
    storage.pools.cold = {
      name = "democold";
      luksDevices = [
        "/dev/disk/by-id/DEMO-hdd-0"
        "/dev/disk/by-id/DEMO-hdd-1"
        "/dev/disk/by-id/DEMO-hdd-2"
      ];
    };
    storage.smrDisks.archive0 = "/dev/disk/by-id/DEMO-smr-0";

    tailscale.enable = true;
  };

  # INCREMENT 1: let the demo image be logged into in the test VM (placeholder only;
  # a real host authenticates via SSH keys / the unlock chain, not a root password).
  users.users.root.initialPassword = "nixnas";

  system.stateVersion = "25.05";
}
