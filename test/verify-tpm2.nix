# test/verify-tpm2.nix — a DEV-only self-check baked into the demo image.
#
# Proves the TPM2-PIN ENROLLMENT path end-to-end against the test VM's software TPM
# (swtpm, provided by test/boot-vm.sh): it runs `systemd-cryptenroll` exactly as the
# operator's `nixnas-enroll-tpm2` helper would on first boot, but NON-interactively
# (the demo passphrase + a demo PIN via env), then dumps the LUKS header so we can SEE
# the `systemd-tpm2` token appear. The real appliance enrolls interactively, operator-run;
# this just lets the VM confirm the wiring without a human typing on the serial.
#
# DEV-only: wired in via the flake's demo modules, never part of the appliance.
{ pkgs, ... }:
{
  systemd.services.nixnas-verify-tpm2 = {
    description = "DEV: enroll TPM2+PIN against swtpm and dump the LUKS token";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "nixnas-verify.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      # The demo passphrase (disko keyslot) + demo PIN — systemd-cryptenroll reads these.
      Environment = [ "PASSWORD=nixnas-demo" "NEWPIN=nixnas-demo" ];
    };
    path = [ pkgs.systemd pkgs.cryptsetup pkgs.gnugrep pkgs.coreutils ];
    script = ''
      echo "=== NIXNAS-TPM2-START ==="
      dev="/dev/disk/by-partlabel/nixnas"
      echo "[dev] $dev"; echo -n "[tpm nodes] "; ls /dev/tpm* 2>&1 | tr '\n' ' '; echo
      if systemd-cryptenroll \
           --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes "$dev"; then
        echo "[enroll] OK"
      else
        echo "[enroll] FAILED rc=$?"
      fi
      echo "[luksDump tokens]"
      cryptsetup luksDump "$dev" | grep -iE -A6 'tokens:|systemd-tpm2' || echo "  (no tpm2 token)"
      echo "=== NIXNAS-TPM2-END ==="
    '';
  };
}
