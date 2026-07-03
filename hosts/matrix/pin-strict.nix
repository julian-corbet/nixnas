# nixnas — matrix variant: PIN-strict TPM2 unlock, explicit + extended PCR set.
#
# Proves the full PIN-strict path evaluates correctly and the option values propagate
# into the runtime crypttab:
#   * crypto.tpm2.requirePin = true  → crypttabExtraOpts includes "tpm2-pin=yes"
#   * crypto.tpm2.pcrs = [ 7 11 ]   → the enrollment script (nixnas-enroll-tpm2) binds
#                                       to PCR 7 (Secure Boot state, the update-stable
#                                       anchor) AND PCR 11 (the measured UKI — documented
#                                       phase-2 hardening in the options description).
#
# requirePin = true is the nixnas DEFAULT but this variant states it explicitly so the
# eval test has a distinct baseline (the demo already has it; the test checks the
# crypttabExtraOpts value to prove the option thread end-to-end, not just the option).
# The PCR 11 addition makes this config distinct from the demo at the option level.
{ ... }:
{
  nixnas.crypto.tpm2.requirePin = true;
  nixnas.crypto.tpm2.pcrs       = [ 7 11 ];
}
