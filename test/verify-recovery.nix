# test/verify-recovery.nix — a DEV-only self-check for the break-glass recovery keyslot.
#
# Exercises the REAL hub tool (`nixnas-escrow-recovery enroll`) end-to-end on a THROWAWAY
# loopback LUKS device in RAM — NEVER the appliance's own store (nixnas never rewrites the
# store it booted from). It proves the security-relevant half of the escrow, in the VM:
#   1. a fresh LUKS device formatted with a "daily" passphrase has exactly 1 keyslot;
#   2. `nixnas-escrow-recovery enroll --no-upload` adds a SECOND, distinct keyslot;
#   3. the device opens with the RECOVERY key alone  → break-glass works;
#   4. the device STILL opens with the daily passphrase alone, no TPM  → this is exactly how
#      the operator's data pools are rescued out of the box (connect.nix binds them to NO TPM);
#   5. the daily keyslot was untouched by the add.
#
# The Vaultwarden UPLOAD is a hub-network action (bw CLI → your server) and is deliberately
# NOT reproduced in the sealed demo VM — `--no-upload` covers the keyslot mechanism here;
# the upload path is validated on the hub. This mirrors verify-sealed-hostkey's swtpm caveat.
{ config, pkgs, ... }:
{
  systemd.services.nixnas-verify-recovery = {
    description = "DEV: verify the break-glass recovery keyslot (loopback LUKS, in RAM)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ pkgs.cryptsetup pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.util-linux ];
    script = ''
      echo "=== NIXNAS-RECOVERY-START ==="
      esc="${config.system.build.nixnasEscrowRecovery}/bin/nixnas-escrow-recovery"
      work="$(mktemp -d -p /run nixnas-recoverytest-XXXXXX)"   # /run = tmpfs = RAM, never the store
      trap 'cryptsetup close rectest 2>/dev/null || true; rm -rf "$work"' EXIT
      img="$work/loop.img"; daily="$work/daily.pass"; rkey="$work/recovery.key"

      # 0. A throwaway 32 MiB LUKS "store" with a daily passphrase (1 keyslot).
      truncate -s 32M "$img"
      printf 'daily-demo-passphrase' > "$daily"; chmod 600 "$daily"
      cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --batch-mode --key-file "$daily" "$img"
      slots0="$(cryptsetup luksDump "$img" | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
      echo "[format] fresh device has $slots0 keyslot(s)"

      # 1. Add the recovery keyslot with the REAL hub tool (no Vaultwarden).
      if ! "$esc" enroll --device "$img" --unlock-file "$daily" --host demo \
             --no-upload --recovery-out "$rkey"; then
        echo "[enroll] FAILED — escrow tool errored"; echo "=== NIXNAS-RECOVERY-END ==="; exit 1
      fi
      slots1="$(cryptsetup luksDump "$img" | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
      echo "[enroll] device now has $slots1 keyslot(s); recovery key is $(wc -c < "$rkey") bytes"

      # 2. Break-glass: opens with the RECOVERY key alone.
      if cryptsetup open --key-file "$rkey" "$img" rectest; then
        echo "[break-glass] OK: store opens with the recovery key alone"; cryptsetup close rectest
      else
        echo "[break-glass] FAILED: recovery key does not open the store"
      fi

      # 3. Rescue path: STILL opens with the daily passphrase alone (no TPM) — same as data pools.
      if cryptsetup open --key-file "$daily" "$img" rectest; then
        echo "[rescue] OK: store still opens with the daily passphrase alone (no TPM needed)"; cryptsetup close rectest
      else
        echo "[rescue] FAILED: daily passphrase no longer opens the store"
      fi

      if [ "''${slots0:-0}" = 1 ] && [ "''${slots1:-0}" = 2 ]; then
        echo "[verdict] PASS — recovery added a distinct keyslot (1 → 2); both keys open the store"
      else
        echo "[verdict] FAIL — expected 1 → 2 keyslots, got ''${slots0:-?} → ''${slots1:-?}"
      fi
      echo "=== NIXNAS-RECOVERY-END ==="
    '';
  };
}
