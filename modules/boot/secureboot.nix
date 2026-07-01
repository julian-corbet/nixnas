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
# KEY LIFECYCLE — DECIDED: stable operator keys are the real-host path; autogenerate
# is only the keyless demo fallback. The toggle is the presence of `secureBoot.keysSops`.
#
# OPERATOR KEYS (real host, `keysSops` set) — the DEFAULT posture for a provisioned box.
#   The Secure Boot keyset is a STABLE IDENTITY, part of the operator's config: the TUI
#   materialises the sops-encrypted PK / KEK / db (`keysSops`) into /nix/lanzaboote/pki on
#   the BUILD machine before running disko, so the image builder VM finds real keys and lzbt
#   signs UKIs from day one. Autogenerate is OFF — the keys don't change identity per box or
#   per reflash, and they never live on the node (only on the hub, from sops).
#
# DEMO / keyless (`keysSops == null`) — the public demo and any keyless build.
#   `autoGenerateKeys.enable` activates lanzaboote's key-generation service (`sbctl
#   create-keys` into /nix/lanzaboote/pki on FIRST BOOT), then re-signs the ESP on the next
#   rebuild. It also sets `allowUnsigned = true`, so the disko image builder installs UNSIGNED
#   UKIs — which boot fine with Secure Boot disabled (the test-VM case). Signed UKIs appear
#   after the first real boot. Convenient, but the keys are NOT a stable identity — real hosts
#   supply `keysSops`.
{ config, lib, ... }:
let
  cfg = config.nixnas;
  # Persistent location for the PKI bundle (PK / KEK / db).  Must be under /nix
  # (the f2fs store partition) so it survives the tmpfs root on every reboot.
  pkiBundle = "/nix/lanzaboote/pki";
  # Stable operator keys when supplied via sops; autogenerate only as the keyless fallback.
  provideStableKeys = cfg.boot.secureBoot.keysSops != null;
in
{
  config = lib.mkIf (cfg.enable && cfg.boot.secureBoot.enable) {
    # Hand off bootloader installation to lzbt (lanzaboote's installer tool).
    boot.lanzaboote.enable = true;
    boot.lanzaboote.pkiBundle = pkiBundle;

    # Autogenerate keys on first boot ONLY when the operator did not supply a stable keyset.
    # With `keysSops` set the TUI has already placed the real PK/KEK/db into `pkiBundle` on the
    # build machine, so lzbt signs from day one and the box's SB identity is stable across
    # reflashes/updates. `allowUnsigned` follows autogenerate (needed for the keyless build).
    boot.lanzaboote.autoGenerateKeys.enable = !provideStableKeys;

    # lanzaboote uses the external boot-loader hook mechanism; systemd-boot's own
    # installer must not also run or the two will fight over the ESP.
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
}
