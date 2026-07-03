# nixnas — matrix variant: no TPM2, plaintext initrd-SSH host key (Path B).
#
# Proves the `sealHostKey = false + hostKeyPath` fallback path evaluates correctly —
# what an operator with no TPM hardware (or who prefers IPMI-SOL-side console unlock)
# actually uses. With crypto.tpm2.enable = false:
#   * remote-unlock.nix enters PATH B: the key is embedded in the initrd at build time
#     and lands on the plaintext ESP inside the signed UKI (LAN/tailnet-only).
#   * The sealActive guard is false, so the assertion `sealActive -> secureBoot.enable`
#     is vacuously satisfied — Secure Boot is still on (the demo base enables it) but
#     the UKI stub is not needed for key delivery.
#
# `demo_initrd_host_ed25519_key` is the throwaway Path-B host key kept in the test/ssh/
# directory exactly for this purpose (same legitimacy as the demo LUKS passphrase).
# See test/ssh/README.md.
{ lib, ... }:
{
  # lib.mkForce overrides the demo base's explicit `crypto.tpm2.enable = true`.
  nixnas.crypto.tpm2.enable = lib.mkForce false;
  nixnas.boot.remoteUnlock.sealHostKey = lib.mkForce false;
  # The throwaway demo initrd host key — Path B explicit opt-in.
  nixnas.boot.remoteUnlock.hostKeyPath = ../../test/ssh/demo_initrd_host_ed25519_key;
}
