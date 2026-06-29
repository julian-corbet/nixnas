# nixnas — TPM2-backed LUKS unlock (config side).
#
# The data pools are unlocked in stage-2 (see modules/storage) with `tpm2-device=auto`
# in crypttab; this ensures the TPM2 userspace + device access is present so
# systemd-cryptsetup can honour it. The actual enrollment — `systemd-cryptenroll`
# (TPM2 + PIN), the recovery keyslot, and the Vaultwarden escrow — is a PROVISION-TIME
# action run by the TUI/hub, NOT declarative config. See docs/DESIGN.md §3.2–3.4.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf;
in
{
  config = mkIf (cfg.enable && cfg.crypto.tpm2.enable) {
    security.tpm2.enable = true;
    environment.systemPackages = [ pkgs.tpm2-tools ];
  };
}
