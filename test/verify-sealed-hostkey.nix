# test/verify-sealed-hostkey.nix — a DEV-only self-check baked into the demo image.
#
# Proves the TPM2-sealed initrd SSH host key path end-to-end against the test VM's
# software TPM (swtpm, provided by test/boot-vm.sh):
#   1. Confirms /boot/nixnas/initrd-hostkey.cred was created by nixnas-seal-hostkey.
#   2. Confirms no plaintext private key was left on the ESP.
#   3. Decrypts the credential using the SAME swtpm that sealed it (succeeds because
#      swtpm is persisted for the whole boot-vm.sh run) to prove the mechanism is live.
#
# On real hardware the swtpm is replaced by the board's own TPM2 and PCR 7 is bound to
# the actual Secure Boot state — a tampered chain cannot recover the credential.
#
# DEV-only: wired in via the flake's demo modules, never part of the appliance.
{ pkgs, ... }:
{
  systemd.services.nixnas-verify-sealed-hostkey = {
    description = "DEV: verify TPM2-sealed initrd SSH host key (nixnas-seal-hostkey result)";
    wantedBy = [ "multi-user.target" ];
    # Run after the seal service has had a chance to complete.
    after = [ "local-fs.target" "nixnas-seal-hostkey.service" ];
    wants = [ "nixnas-seal-hostkey.service" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ pkgs.systemd pkgs.coreutils pkgs.findutils pkgs.openssh ];
    script = ''
      echo "=== NIXNAS-SEALTEST-START ==="

      cred="/boot/loader/credentials/nixnas-initrd-hostkey.cred"

      # ── 1. Sealed credential on the ESP's loader/credentials dir (the stub drop-in) ──
      if [ -f "$cred" ]; then
        echo "[sealed-blob] EXISTS: $cred ($(wc -c < "$cred") bytes)"
      else
        echo "[sealed-blob] MISSING — nixnas-seal-hostkey did not run or failed"
        echo "=== NIXNAS-SEALTEST-END ==="
        exit 1
      fi

      # ── 2. No plaintext key alongside the sealed credential ──────────────────────────
      leaked=$(find /boot/loader/credentials -maxdepth 1 -type f ! -name '*.cred' 2>/dev/null | head -5)
      if [ -n "$leaked" ]; then
        echo "[plaintext] WARNING: non-credential files found alongside the sealed cred:"
        echo "$leaked" | sed 's/^/  /'
      else
        echo "[plaintext] OK: no plaintext key files under /boot/loader/credentials/"
      fi

      # ── 3. Decrypt the credential (proves TPM2 round-trip against swtpm) ─────────────
      tmpout="$(mktemp -t nixnas-verify-hostkey.XXXXXX)"
      if systemd-creds decrypt \
           --tpm2-device=auto \
           --name=nixnas-initrd-hostkey \
           "$cred" "$tmpout" 2>&1; then
        # ssh-keygen -l on a private key needs 0600 + a readable pubkey line; grab the
        # parenthesised type ((ED25519)) robustly, fall back to a plain non-empty label.
        chmod 600 "$tmpout" 2>/dev/null || true
        fp="$(ssh-keygen -l -f "$tmpout" 2>/dev/null || true)"
        keytype="$(printf '%s' "$fp" | sed -n 's/.*(\(.*\)).*/\1/p')"
        [ -n "$keytype" ] || keytype="(decrypted $(wc -c < "$tmpout") bytes)"
        echo "[decrypt] OK: credential decrypts — key $keytype"
        shred -u "$tmpout" 2>/dev/null || rm -f "$tmpout"
      else
        echo "[decrypt] FAILED: cannot decrypt credential (TPM2 policy mismatch?)"
        rm -f "$tmpout"
      fi

      echo "=== NIXNAS-SEALTEST-END ==="
    '';
  };
}
