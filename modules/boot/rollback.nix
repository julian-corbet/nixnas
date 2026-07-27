# nixnas — the structural failsafe: bootable generations + automatic rollback.
#
# Design principle: failsafe does not come from choosing the right software, but from a failed
# update being unable to knock the system off course. This module is that — nothing
# nixnas-specific, just NixOS's own mechanisms wired up:
#
#   * KEEP N GENERATIONS (`keepGenerations`) — every past system stays bootable as its own
#     signed UKI; the bootloader menu is the GUARANTEED manual rollback. Bounded by the ESP.
#   * BOOT-COUNTING (`tries`) — a new generation boots with a counter; each boot decrements
#     it and reaching `boot-complete.target` clears it. A generation that never gets that far
#     burns its tries and the bootloader falls back to the last good one — AUTOMATIC rollback,
#     no console needed (which matters: this box is headless and never self-reboots into a PIN
#     prompt). ARCHITECTURE §6, §9.1 (the boot-counting × lanzaboote loop is a hardware spike;
#     the manual menu is the fallback that always works).
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    # Depth of the bootable-generation history (== rollback menu depth). lanzaboote inherits
    # this value, so it bounds the signed UKIs on the ESP for both the SB-on and SB-off paths.
    boot.loader.systemd-boot.configurationLimit = cfg.boot.keepGenerations;

    # Write the boot counter onto new entries. This is LANZABOOTE's knob — boot-counting
    # only exists on the Secure Boot path (the lanzaboote stub renames/counts the entries);
    # without secureBoot.enable the option would be a silent no-op, so it is gated: the
    # kept-generation menu remains the (guaranteed) rollback on non-SB configs.
    #
    # VALIDATED in the VM: lanzaboote's stub DOES count down — gen-1 installs as `…+3`,
    # the first boot renames it to `…+2-1` (2 tries left, 1 done). The "mark good" half
    # (systemd-bless-boot.service, present + wired into boot-complete.target via systemd's
    # withBootloader) RAN but did NOT clear the counter in the SB-off OVMF VM: the
    # stub↔`LoaderBootCountPath`↔bless bridge is the lanzaboote×systemd hardware spike
    # (ARCHITECTURE §9.1). Consequence is bounded — a counter that hits 0 makes the entry
    # "bad", but systemd-boot still boots a bad entry as a LAST RESORT (no brick), and the
    # manual generation menu (kept by `keepGenerations`) is the GUARANTEED rollback. So the
    # structural failsafe stands; automatic boot-counting rollback awaits a real-UEFI spike.
    boot.lanzaboote.bootCounting.initialTries = lib.mkIf cfg.boot.secureBoot.enable cfg.boot.tries;
  };
}
