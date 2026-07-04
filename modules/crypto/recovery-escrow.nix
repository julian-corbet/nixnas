# nixnas — break-glass recovery key: a SEPARATE high-entropy LUKS keyslot, escrowed
# to Vaultwarden. Distinct from the daily TPM2 PIN and independent of any one box's TPM
# (an AMD fTPM is wiped by a BIOS/NVRAM clear; the stick's passphrase can be forgotten).
# This is the last-resort key that opens the store when everything else is gone.
#
# WHERE IT RUNS — the HUB, never the node (see the [build on hub] doctrine):
#   The recovery key is generated, enrolled and uploaded on the BUILD/PROVISION machine,
#   against the freshly-built image (or the flashed device) BEFORE the box is handed off.
#   The Vaultwarden API credentials (`crypto.recovery.credsSops`) therefore live only on
#   the hub — they are NEVER shipped to the appliance. The box only ever RECEIVES a LUKS
#   header that already contains the recovery keyslot; it cannot mint or read the escrow.
#
#   Flow (`nixnas-escrow-recovery enroll`):
#     1. generate a 256-bit recovery key (`/dev/urandom` → base64),
#     2. `cryptsetup luksAddKey <store-part>` authorised by the daily passphrase — a new,
#        distinct keyslot (never wipes the daily/TPM2 slots),
#     3. upload {host, key} to Vaultwarden as a secure note (`bw` CLI, API-key auth),
#     4. shred every plaintext copy on the hub.
#   `--no-upload` does 1–2 + emits the key to `--recovery-out` (for offline escrow / tests);
#   the upload path is hub-network-only and is NOT exercised by the sealed demo VM.
#
# BOX SIDE (this module, when recovery is configured): a read-only `nixnas-recovery-status`
# diagnostic (how many keyslots the store carries) + an assertion that a URL implies creds.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  inherit (lib) mkIf mkMerge optionalString;

  storeDev = "/dev/disk/by-partlabel/nixnas-store";
  recoveryEnabled = cfg.crypto.recovery.vaultwardenUrl != null;

  # ── The HUB tool. A per-config package (it bakes in the store partlabel, the Vaultwarden
  # URL and — for `enroll` — the daily-passphrase source). The TUI/operator runs this on the
  # build machine; it is exposed via `system.build.nixnasEscrowRecovery`, never installed on
  # the appliance. Vaultwarden creds are passed at call time from the hub's sops, not baked in.
  escrowTool = pkgs.writeShellApplication {
    name = "nixnas-escrow-recovery";
    runtimeInputs = [ pkgs.cryptsetup pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.jq pkgs.bitwarden-cli ];
    text = ''
      set -euo pipefail
      usage() {
        cat >&2 <<'EOF'
      nixnas-escrow-recovery — HUB-side break-glass recovery keyslot + Vaultwarden escrow.

        nixnas-escrow-recovery enroll \
          --device <luks-part>          # the store LUKS partition (or a loopback for tests)
          --unlock-file <file>          # file holding the DAILY passphrase (authorises the add)
          --host <name>                 # label for the Vaultwarden item (nixnas-recovery/<name>)
          [--vaultwarden-url <url>]     # override the config default
          [--creds-file <file>]         # JSON {client_id,client_secret,master_password} (from sops)
          [--recovery-out <file>]       # also write the plaintext recovery key here (offline escrow)
          [--no-upload]                 # skip Vaultwarden (keyslot + --recovery-out only; for tests)

      Generates a 256-bit recovery key, adds it as a NEW LUKS keyslot (never wipes existing
      slots), and escrows it to Vaultwarden. Run on the BUILD machine; never on the appliance.
      EOF
        exit 2
      }

      [ "''${1:-}" = "enroll" ] || usage; shift
      DEVICE=""; UNLOCK_FILE=""; HOST=""; VW_URL="${toString (cfg.crypto.recovery.vaultwardenUrl or "")}"
      CREDS_FILE=""; RECOVERY_OUT=""; NO_UPLOAD=0
      while [ $# -gt 0 ]; do case "$1" in
        --device) DEVICE="$2"; shift 2;;
        --unlock-file) UNLOCK_FILE="$2"; shift 2;;
        --host) HOST="$2"; shift 2;;
        --vaultwarden-url) VW_URL="$2"; shift 2;;
        --creds-file) CREDS_FILE="$2"; shift 2;;
        --recovery-out) RECOVERY_OUT="$2"; shift 2;;
        --no-upload) NO_UPLOAD=1; shift;;
        *) echo "unknown arg: $1" >&2; usage;;
      esac; done
      [ -n "$DEVICE" ] && [ -n "$UNLOCK_FILE" ] && [ -n "$HOST" ] || usage
      [ -f "$UNLOCK_FILE" ] || { echo "no such --unlock-file: $UNLOCK_FILE" >&2; exit 1; }

      workdir="$(mktemp -d -t nixnas-recovery-XXXXXX)"
      keyfile="$workdir/recovery.key"
      cleanup() { find "$workdir" -type f -exec shred -u {} \; 2>/dev/null || true; rm -rf "$workdir"; }
      trap cleanup EXIT

      # 1. High-entropy recovery key (256 bits → base64, no newline).
      head -c 32 /dev/urandom | base64 -w0 > "$keyfile"

      # 2. Add it as a distinct keyslot, authorised by the daily passphrase. This NEVER
      #    touches the existing slots (daily passphrase + any TPM2 slot survive).
      echo "nixnas: adding recovery keyslot on $DEVICE (authorised by the daily passphrase)"
      cryptsetup luksAddKey --key-file "$UNLOCK_FILE" "$DEVICE" "$keyfile"

      if [ -n "$RECOVERY_OUT" ]; then
        install -m 0600 /dev/null "$RECOVERY_OUT"
        cat "$keyfile" > "$RECOVERY_OUT"
        echo "nixnas: recovery key also written to $RECOVERY_OUT (protect + shred after use)"
      fi

      # 3. Escrow to Vaultwarden (hub network path — NOT exercised by the demo VM).
      if [ "$NO_UPLOAD" = 1 ]; then
        echo "nixnas: --no-upload set — keyslot added, Vaultwarden escrow skipped."
      else
        [ -n "$VW_URL" ] || { echo "no Vaultwarden URL (config or --vaultwarden-url)" >&2; exit 1; }
        [ -n "$CREDS_FILE" ] && [ -f "$CREDS_FILE" ] || { echo "need --creds-file (sops JSON)" >&2; exit 1; }
        cid="$(jq -r .client_id "$CREDS_FILE")"; csec="$(jq -r .client_secret "$CREDS_FILE")"
        mpw="$(jq -r .master_password "$CREDS_FILE")"
        export BITWARDENCLI_APPDATA_DIR="$workdir/bw"
        bw config server "$VW_URL" >/dev/null
        BW_CLIENTID="$cid" BW_CLIENTSECRET="$csec" bw login --apikey >/dev/null
        session="$(printf '%s' "$mpw" | bw unlock --raw)"
        item="$(jq -n --arg n "nixnas-recovery/$HOST" --arg k "$(cat "$keyfile")" \
          '{type:2,name:$n,notes:("LUKS break-glass recovery key for "+$n+"\n"+$k),secureNote:{type:0}}')"
        printf '%s' "$item" | bw --session "$session" encode | bw --session "$session" create item >/dev/null
        bw --session "$session" sync >/dev/null || true
        bw logout >/dev/null 2>&1 || true
        echo "nixnas: recovery key escrowed to Vaultwarden item nixnas-recovery/$HOST"
      fi
      echo "nixnas: done. The daily passphrase + TPM2 keyslots are untouched."
    '';
  };

  # ── Box-side read-only diagnostic: how many keyslots does the store carry?
  # A fully provisioned box shows the daily passphrase slot + the recovery slot (+ a TPM2
  # slot once enrolled). One slot alone means recovery was never escrowed.
  recoveryStatus = pkgs.writeShellApplication {
    name = "nixnas-recovery-status";
    runtimeInputs = [ pkgs.cryptsetup pkgs.gnugrep pkgs.coreutils pkgs.gawk ];
    text = ''
      dev="$(cryptsetup status cryptstore 2>/dev/null | awk '/device:/ {print $2}')"
      [ -n "''${dev:-}" ] || dev="${storeDev}"
      slots="$(cryptsetup luksDump "$dev" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
      echo "nixnas: store $dev carries ''${slots:-0} LUKS keyslot(s)."
      if [ "''${slots:-0}" -lt 2 ]; then
        echo "  WARNING: fewer than 2 keyslots — no break-glass recovery key is enrolled."
        echo "  Enroll one on the HUB: nixnas-escrow-recovery enroll --device $dev ..."
      fi
    '';
  };
in
{
  config = mkIf cfg.enable (mkMerge [
    {
      # The hub tool is ALWAYS built (the TUI/operator may escrow at any time); it is a
      # build artifact, never a system package on the appliance.
      system.build.nixnasEscrowRecovery = escrowTool;
    }
    (mkIf recoveryEnabled {
      assertions = [{
        assertion = cfg.crypto.recovery.credsSops != null;
        message = ''
          nixnas.crypto.recovery.vaultwardenUrl is set but crypto.recovery.credsSops is null.
          The escrow needs Vaultwarden API credentials (client_id/client_secret/master_password)
          from a hub-side sops file to upload the recovery key. Set credsSops, or unset
          vaultwardenUrl to skip escrow (the daily passphrase keyslot is then the only recovery).
        '';
      }];
      # A read-only status helper on the box (safe: it only reads the LUKS header).
      environment.systemPackages = [ recoveryStatus ];
    })
  ]);
}
