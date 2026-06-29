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
      disks = [ "/dev/disk/by-id/DEMO-ssd-0" "/dev/disk/by-id/DEMO-ssd-1" ];
      topology = "mirror";
    };
    storage.pools.cold = {
      name = "democold";
      disks = [
        "/dev/disk/by-id/DEMO-hdd-0"
        "/dev/disk/by-id/DEMO-hdd-1"
        "/dev/disk/by-id/DEMO-hdd-2"
      ];
      topology = "raidz1";
    };
    storage.smrDisks.archive0 = "/dev/disk/by-id/DEMO-smr-0";

    compute.k3s.enable = true;
    compute.archContainer.enable = true;
    compute.gpu.enable = true;
    compute.officeVm.enable = false; # the demo has no Office VM zvol

    tailscale.enable = true;
  };

  # Minimal NixOS scaffolding so `system.build.toplevel` evaluates standalone.
  # The real boot chain / filesystems come from the nixnas implementation modules
  # (later milestones); for now the core ships only the option API.
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
  };
  boot.loader.grub.enable = false;
  system.stateVersion = "25.05";
}
