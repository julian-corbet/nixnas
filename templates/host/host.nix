# Your machine's real values + secrets live HERE, in your private repo.
# The public nixnas core never references this file.
{ ... }:
{
  nixnas = {
    enable = true;
    hostName = "nas"; # your hostname

    boot.secureBoot.enable = true;
    crypto.tpm2.enable = true;
    # crypto.recovery.vaultwardenUrl = "https://vault.example.invalid";
    # crypto.recovery.credsSops      = config.sops.secrets."vaultwarden-escrow".path;

    storage.pools.hot = {
      name = "hot"; # your HOT (SSD) pool — you create it by hand; nixnas only imports it
      luksDevices = [ "/dev/disk/by-id/ata-…" ];
    };
    storage.pools.cold = {
      name = "cold"; # your COLD (HDD) pool — operator-created; nixnas imports only
      luksDevices = [ "/dev/disk/by-id/ata-…" ];
    };

    compute.k3s.enable = true;
    compute.officeVm = {
      enable = true;
      zvol = "/dev/zvol/hot/vm/office";
      # xml = ./office.xml;
    };
  };

  system.stateVersion = "25.05";
}
