# nixnas — TPM2-backed LUKS unlock for the store (config side).
#
# UNLOCK MODEL (ARCHITECTURE §6, DECIDED):
#   * The store (the LUKS f2fs `/nix` partition) is unlocked in the INITRD. We tag its
#     crypttab entry with `tpm2-device=auto` (+ `tpm2-pin=yes` when strict), so once a
#     TPM2 keyslot is enrolled, systemd-cryptsetup unseals the key from the TPM and asks
#     only for the PIN. With NO token yet enrolled (a freshly-flashed stick) it falls back
#     to the plain passphrase keyslot — so the image boots before enrollment.
#   * The single secret is the TPM2 PIN; `systemd-cryptsetup` caches it in the kernel
#     keyring and reuses it in stage-2 for the operator's data pools — one prompt unlocks
#     everything (see modules/storage; spike: keyring survives switch-root).
#
# ENROLLMENT IS FIRST-BOOT, ON THE REAL HARDWARE.
#   PCRs are hardware-specific, so a build machine cannot seal to the target TPM. The
#   image therefore ships only the passphrase keyslot (disko, build-time). On first boot
#   the operator runs `nixnas-enroll-tpm2` (provided here) which calls
#   `systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin` against the store — adding the
#   TPM2 keyslot and keeping the passphrase slot as the MANDATORY off-box recovery key
#   (an AMD fTPM is wiped by a BIOS/NVRAM clear). Strict vs PCR-only is `crypto.tpm2.requirePin`.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf optional concatMapStringsSep optionalString;

  # The store's backing partition (disko names the mapper `cryptstore`).
  storeDev = "/dev/disk/by-partlabel/disk-main-nixos";
  pcrList = concatMapStringsSep "+" toString cfg.crypto.tpm2.pcrs;

  # Operator-run, first-boot enrollment. Prompts for the existing passphrase (to authorise
  # the new keyslot) and, when strict, the new PIN. `--wipe-slot=tpm2` makes a re-run
  # idempotent (replace, never accumulate). The passphrase keyslot is left intact = recovery.
  enrollTpm2 = pkgs.writeShellApplication {
    name = "nixnas-enroll-tpm2";
    runtimeInputs = [ pkgs.systemd pkgs.cryptsetup pkgs.gnugrep pkgs.gawk ];
    text = ''
      # Resolve the live backing device from the open mapper, fall back to the partlabel.
      dev="$(cryptsetup status cryptstore 2>/dev/null | awk '/device:/ {print $2}')"
      [ -n "''${dev:-}" ] || dev="${storeDev}"
      echo "nixnas: enrolling TPM2 keyslot on $dev (PCRs ${pcrList}${optionalString cfg.crypto.tpm2.requirePin ", PIN required"})"
      systemd-cryptenroll \
        --wipe-slot=tpm2 \
        --tpm2-device=auto \
        --tpm2-pcrs=${pcrList} \
        --tpm2-with-pin=${if cfg.crypto.tpm2.requirePin then "yes" else "no"} \
        "$dev"
      echo "nixnas: done. The passphrase keyslot remains as the recovery key — keep it safe."
    '';
  };
in
{
  # TPM2 auto-unlock is a STICK-store feature (the `cryptstore` mapper disko creates in usb
  # mode). A hot-mode MAIN has no stick store and unlocks its hot store with the OPERATOR'S
  # key (never TPM) — so this is usb-mode only (it still applies to the rescue, a usb nixnas).
  config = mkIf (cfg.enable && cfg.crypto.tpm2.enable && cfg.store.location == "usb") {
    security.tpm2.enable = true;
    environment.systemPackages = [ pkgs.tpm2-tools enrollTpm2 ];

    # Initrd needs the TPM driver to talk to the chip during the store unlock.
    # (systemd-initrd's own TPM2 unsealing support is pulled in by boot.initrd.systemd.tpm2.)
    boot.initrd.availableKernelModules = [ "tpm_crb" "tpm_tis" ];

    # Tell the initrd store-unlock to try the TPM2 keyslot first (+ demand the PIN when
    # strict). Merges with disko's generated `cryptstore` device entry. Harmless before
    # enrollment: with no TPM2 token present, systemd-cryptsetup falls back to the passphrase.
    boot.initrd.luks.devices.cryptstore.crypttabExtraOpts =
      [ "tpm2-device=auto" ] ++ optional cfg.crypto.tpm2.requirePin "tpm2-pin=yes";
  };
}
