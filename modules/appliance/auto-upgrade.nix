# nixnas — self-update (autoUpgrade), the "no babysitting" half of the failsafe model.
#
# After flashing, the box is autonomous: it pulls the operator's flake and rebuilds
# itself. nothing nixnas-specific — stock `system.autoUpgrade`, with two appliance rules:
#
#   * allowReboot = false — the box must NEVER reboot itself. It is headless and the PIN is
#     required every boot, so a self-initiated reboot would strand it at an unlock prompt no
#     one is at. (ARCHITECTURE §6.)
#   * operation = "boot" — STAGE the new generation for the next boot; never switch it live.
#     It activates on the next operator-initiated, PIN-unlocked reboot, and if it misbehaves
#     the rollback layer (modules/boot/rollback.nix) catches it. Pairs with the kept-generation
#     menu: build-then-stage-then-verify, not build-and-pray.
#
# Only active once the operator points `autoUpgrade.flake` at their config.
#
# OWNERSHIP STATUS: this remains the current, functional implementation.
# Nixdeploy is now the sole delivery specialist, so the trigger, staging and
# resulting activation/rollback/health outcome are marked for migration there.
# Nixnas continues to own the appliance configuration being built, not the
# decision or schedule that delivers it.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf (cfg.enable && cfg.autoUpgrade.enable && cfg.autoUpgrade.flake != null) {
    system.autoUpgrade = {
      enable = true;
      flake = cfg.autoUpgrade.flake;
      operation = "boot";      # stage for next boot; never switch the running system
      allowReboot = false;     # never self-reboot into a headless PIN prompt
      dates = cfg.autoUpgrade.schedule;
      flags = [ "--accept-flake-config" ];
    };
  };
}
