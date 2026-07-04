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
#
# generate-sb-keys.service landlock trap — CONFIRMED by direct reproduction (not just
# pattern-matched): lanzaboote's `generate-sb-keys.service` runs plain `sbctl create-keys`
# with its landlock sandbox left on. `sbctl create-keys` adds a Landlock RWDirs rule for the
# *grandparent* of `keydir` (i.e. `dirname(pkiBundle)` = `/nix/lanzaboote`) WITHOUT
# `IgnoreIfMissing()` (unlike the analogous rule sbctl builds from its own config, which does
# chain it). On a genuine first boot `/nix/lanzaboote` does not exist yet — nothing pre-creates
# it — so Landlock's `open(O_PATH)` on that path fails with ENOENT and `sbctl create-keys`
# exits 1 *before* creating any directory or writing any key. The service fails silently and
# `/nix/lanzaboote/pki/keys/db/db.key` never appears. `sbctl --disable-landlock create-keys`
# skips the landlock setup entirely and succeeds (verified: reproduced the exact
# "populating ruleset for ... open: no such file or directory" failure with plain
# `sbctl create-keys` against a not-yet-existing keydir tree, and confirmed
# `--disable-landlock` creates PK/KEK/db cleanly in the same tree). This is a genuine
# keyless-first-boot bug, not a test artifact — hence the ExecStart override below rather
# than a test-side workaround.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  # Persistent location for the PKI bundle (PK / KEK / db).  Must be under /nix
  # (the f2fs store partition) so it survives the tmpfs root on every reboot.
  pkiBundle = "/nix/lanzaboote/pki";
  # Stable operator keys when supplied via sops; autogenerate only as the keyless fallback.
  provideStableKeys = cfg.boot.secureBoot.keysSops != null;

  # ── nixnas-enroll-sb: operator-run FIRMWARE key enrollment ─────────────────────────────
  #
  # Signing (lzbt, above) is automatic; ENROLLING the keys into the board's firmware NVRAM
  # is the one manual step left after flashing: put the firmware in Setup Mode, boot the
  # stick, run `nixnas-enroll-sb`, reboot, set the firmware admin password. This tool
  # automates the sbctl choreography of that step ("kann das automatisiert geschehen?" —
  # yes, up to the physical parts).
  #
  # WHY STAGE THE PKI INTO /var/lib/sbctl: sbctl's default key database is /var/lib/sbctl
  # (proven against the pinned sbctl 0.18: `sbctl create-keys --help` → default database
  # path). The pinned lanzaboote module writes an /etc/sbctl/sbctl.conf redirecting sbctl
  # at the pkiBundle ONLY when autoGenerateKeys is active (lanzaboote.nix: `environment.
  # etc."sbctl/sbctl.conf" = mkIf (autoGenerateKeys.enable || autoEnrollKeys.enable)`) —
  # i.e. only on KEYLESS demo hosts. On a real host (stable operator keys via `keysSops`)
  # there is no conf, so a bare `sbctl enroll-keys` would look in /var/lib/sbctl and find
  # nothing. Staging the bundle there makes enrollment work identically on both host
  # classes (on keyless hosts the conf simply keeps pointing sbctl at the bundle and the
  # staged copy is inert). /var/lib is tmpfs under impermanence — the staging is
  # deliberately per-boot ephemeral; the bundle on the encrypted store stays the single
  # source of truth, and firmware NVRAM holds the enrollment result.
  #
  # WHY --disable-landlock: same sandbox trap family as the create-keys ENOENT bug in the
  # module header — sbctl's landlock ruleset builds path rules before doing the work, and
  # here it must additionally traverse /nix (read-only store) and efivarfs. Enrollment is
  # a one-shot root operation on an appliance; the sandbox buys nothing and has bitten
  # twice, so it is off for this invocation.
  #
  # WHY THIS IS NOT A systemd UNIT (deliberate — do not "fix"): enrolling writes PK/KEK/db
  # into firmware NVRAM, the one state nixnas cannot rebuild or roll back from the stick.
  #   * A boot-time unit would retry on every boot and on flaky firmware could half-enroll
  #     or hammer NVRAM; failure lands in a journal nobody is watching during first boot.
  #   * The wrong OpROM policy on a given board can make the NEXT POST fail — the operator
  #     must be standing at the machine, able to re-enter firmware setup, WHEN it happens.
  #   * Leaving Setup Mode is a security decision (it ends the enrollment window and
  #     activates enforcement) — a human commits it, not a boot side effect.
  # lanzaboote's autoEnrollKeys (systemd-boot `secure-boot-enroll force`) is skipped for
  # the same reason. Firmware writes stay operator-invoked; everything around them is
  # automated here.
  policyFlag = {
    "tpm-eventlog" = "--tpm-eventlog";
    "microsoft" = "--microsoft";
    "none" = "";
  }.${cfg.boot.secureBoot.opromPolicy};

  enrollSb = pkgs.writeShellApplication {
    name = "nixnas-enroll-sb";
    runtimeInputs = [ pkgs.sbctl pkgs.coreutils pkgs.util-linux ];
    text = ''
      pki=${pkiBundle}
      db=/var/lib/sbctl
      sm=/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c

      fail() { echo "!! $*" >&2; exit 1; }
      # efivarfs payload = 4 bytes of attributes, then the data; SetupMode's datum is one
      # byte, so read exactly the byte at offset 4 (0 = user mode, 1 = setup mode).
      setupmode() { od -An -tu1 -j4 -N1 "$sm" | tr -d '[:space:]'; }

      [ "$(id -u)" = 0 ] || fail "must run as root"
      [ -r "$pki/keys/db/db.key" ] || fail \
        "no Secure Boot PKI at $pki — on a TUI-flashed stick the keys are staged at build" \
        "time; on a keyless (demo) build they appear on first boot (generate-sb-keys)."
      [ -e "$sm" ] || fail \
        "no UEFI SetupMode variable — this system is not UEFI-booted (or efivarfs is" \
        "missing). Secure Boot enrollment needs a UEFI boot."

      if [ "$(setupmode)" != "1" ]; then
        cat >&2 <<'EOF'
      !! The firmware is NOT in Setup Mode — refusing to enroll.
         Enrollment rewrites the firmware's PK/KEK/db and is only possible while the
         platform key is cleared. To get there:
           1. reboot into firmware setup (usually Del/F2),
           2. Secure Boot menu -> "Clear/Delete Secure Boot keys" or "Reset to Setup Mode",
           3. boot this stick again and re-run nixnas-enroll-sb.
         (If Secure Boot is already ENABLED with these keys, there is nothing to do —
         check with: bootctl status)
      EOF
        exit 1
      fi

      # sbctl needs an owner GUID next to the keys. The keyless (autogenerate) path
      # creates one in the bundle, but a TUI-staged operator bundle carries only keys/ —
      # backfill it INTO THE BUNDLE (the encrypted store), not /var/lib (tmpfs), so the
      # box keeps one stable owner identity across reboots and re-enrollments.
      if [ ! -f "$pki/GUID" ]; then
        uuidgen > "$pki/GUID"
        echo ">> generated sbctl owner GUID ($(cat "$pki/GUID")) into $pki/GUID"
      fi

      # Stage the bundle into sbctl's database dir (idempotent: same source, same result;
      # 0700 — the db private key must never be group/world readable).
      install -d -m 0700 "$db"
      cp -aT "$pki/keys" "$db/keys"
      cp -aT "$pki/GUID" "$db/GUID"
      chmod -R go-rwx "$db"

      echo ">> enrolling the operator Secure Boot keys (OpROM policy: ${cfg.boot.secureBoot.opromPolicy})"
      sbctl enroll-keys --disable-landlock ${policyFlag}

      # VERIFY. Field-proven caveat (first real deployment, 2026-07-04): many boards keep
      # REPORTING SetupMode=1 until the next reboot even after a successful enrollment —
      # the efivar is latched. So a lingering 1 is a note, not a failure; sbctl's exit
      # status above is the truth (a real failure aborted this script already).
      if [ "$(setupmode)" = "0" ]; then
        echo ">> firmware left Setup Mode — keys are live."
      else
        echo ">> NOTE: SetupMode still reads 1. Many boards latch the reported value until"
        echo "   the next reboot (field-proven); sbctl succeeded above, so proceed."
      fi
      cat <<'EOF'

      Enrollment done. Next steps:
        1. reboot;
        2. verify:  bootctl status   must report  "Secure Boot: enabled (user)";
        3. set the firmware ADMIN PASSWORD — without it, an evil maid can simply
           re-enter Setup Mode and swap the keys, undoing all of this;
        4. PCR 7 CHANGED. Enrollment rewrote the Secure Boot state, so anything TPM-sealed
           to PCR 7 before now is stale:
             * the initrd-SSH host key RE-SEALS ITSELF on this next boot (nixnas-seal-hostkey
               self-heals) — expect a ONE-TIME ssh known-hosts fingerprint change, re-pin it;
             * if you enrolled a TPM2 store keyslot (nixnas-enroll-tpm2), RE-RUN it after the
               reboot to re-bind it to the new PCR 7 — until then the store opens via the
               passphrase/recovery keyslot every boot.
      EOF
    '';
  };
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

    # Work around the landlock/ENOENT trap documented above: only relevant when
    # autogenerate is actually active (the unit only exists in that case anyway,
    # since upstream gates it on `cfg.autoGenerateKeys.enable`).
    systemd.services.generate-sb-keys = lib.mkIf (!provideStableKeys) {
      serviceConfig.ExecStart = lib.mkForce "${pkgs.sbctl}/bin/sbctl create-keys --disable-landlock";
    };

    # lanzaboote uses the external boot-loader hook mechanism; systemd-boot's own
    # installer must not also run or the two will fight over the ESP.
    boot.loader.systemd-boot.enable = lib.mkForce false;

    # The firmware enrollment tool ships on STICK-RESIDENT systems (usb mode — which
    # includes the hot-mode RESCUE): enrollment happens standing at the machine, booted
    # from the stick, right after flashing. A hot-mode MAIN never needs it — its stick's
    # rescue system carries it. Deliberately NOT a systemd unit (see the header above).
    environment.systemPackages = lib.optional (cfg.store.location == "usb") enrollSb;
    system.build.sbEnroller = enrollSb;
  };
}
