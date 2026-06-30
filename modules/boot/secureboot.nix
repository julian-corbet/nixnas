# nixnas — UEFI Secure Boot via lanzaboote (operator-owned keys).
#
# lanzaboote replaces the plain systemd-boot installer: its `lzbt install` hook
# signs UKIs with the operator's db key before writing them to the ESP.  The ESP
# itself still contains the stock systemd-boot EFI binary (also signed by lzbt);
# the difference is that every kernel image is wrapped in a signed UKI.
#
# PKI BUNDLE — location: /nix/lanzaboote/pki
#   /nix is the LUKS-encrypted f2fs partition (the only thing that persists
#   across reboots besides the ESP).  Placing the bundle there means the keys
#   survive reboots and are inside the threat model (unlocking /nix already
#   requires the passphrase / TPM2 PIN, so the signing keys are equally
#   protected to the OS store they protect).
#
# DEMO-IMAGE KEY LIFECYCLE
#   The demo image ships with NO keys baked in.  `autoGenerateKeys.enable`
#   activates lanzaboote's `generate-sb-keys` service which runs `sbctl
#   create-keys` into /nix/lanzaboote/pki on FIRST BOOT, then re-signs the ESP
#   on the next `nixos-rebuild switch`.
#
#   During the disko image build (nixos-install inside a throw-away VM) lzbt
#   runs as the external bootloader installer.  Because the keys do not exist at
#   that point, and because autoGenerateKeys implies `allowUnsigned = true`, lzbt
#   installs UNSIGNED UKIs — which boot fine on any box running with Secure Boot
#   disabled (the test-VM case).  Signed UKIs appear after the first real boot.
#
# OPERATOR KEYS (real host)
#   The TUI supplies the operator's own PK / KEK / db keyset; it writes them
#   into /nix/lanzaboote/pki on the build machine before running disko, so the
#   image builder VM finds real keys and lzbt produces properly signed UKIs from
#   day one.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  # Persistent location for the PKI bundle (PK / KEK / db).  Must be under /nix
  # (the f2fs store partition) so it survives the tmpfs root on every reboot.
  pkiBundle = "/nix/lanzaboote/pki";
in
{
  config = lib.mkIf (cfg.enable && cfg.boot.secureBoot.enable) {
    # Hand off bootloader installation to lzbt (lanzaboote's installer tool).
    boot.lanzaboote.enable = true;
    boot.lanzaboote.pkiBundle = pkiBundle;

    # Generate keys on first boot into /nix/lanzaboote/pki if they are absent.
    # This also sets allowUnsigned = true by default, which lets the disko image
    # builder install without keys present in the build VM.
    boot.lanzaboote.autoGenerateKeys.enable = true;

    # lanzaboote uses the external boot-loader hook mechanism; systemd-boot's own
    # installer must not also run or the two will fight over the ESP.
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
}
