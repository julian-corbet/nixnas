# nixnas — the paired upgrade: the MAIN (hot) system keeps the RESCUE current on the stick.
#
# In `hot` mode two independent systems share the stick: the MAIN's /nix is on the pool, and
# a self-contained RESCUE lives on the stick (its f2fs store + a UKI on the shared ESP). The
# rescue is rarely booted, so it can't self-upgrade — the running MAIN maintains it, from the
# SAME flake revision autoUpgrade pulls (so its kernel/ZFS always import the live pool).
#
# HOW IT COEXISTS ON ONE ESP (source-grounded — see docs/HOT-MODE.md):
#   lanzaboote's `lzbt install` (which the main runs) garbage-collects the ESP, but its
#   EFI/Linux GC deletes ONLY files whose name starts with `nixos-` (an explicit "shared with
#   other distros" carve-out), and it WIPES EFI/nixos entirely. So the rescue entry must be
#     (1) a SELF-CONTAINED UKI (kernel+initrd+cmdline in one PE — nothing in EFI/nixos), and
#     (2) named WITHOUT a `nixos-` prefix → `EFI/Linux/nixnas-rescue.efi`.
#   Then it survives every main update, and systemd-boot auto-discovers it as a menu entry.
#   lzbt has no sign-arbitrary-file command, so we sign it out of band with the SAME db key
#   lanzaboote uses (`${pkiBundle}/keys/db/db.{key,pem}`).
#
# WHAT THE MAINTAINER DOES, each run (after autoUpgrade):
#   1. build the rescue toplevel from the flake (into the pool store),
#   2. build a self-contained UKI from its kernel+initrd+cmdline (init= points AT that
#      toplevel, so no stick-side Nix profile bookkeeping is needed),
#   3. sign the UKI with the db key,
#   4. TPM2-unlock + mount the stick's rescue f2fs and `nix copy` the rescue closure onto it
#      (the rescue's stage-2 executes from the stick store),
#   5. atomically place the signed UKI at ESP:/EFI/Linux/nixnas-rescue.efi (rotating the
#      previous one to nixnas-rescue-prev.efi as a one-step rescue rollback).
# It is a no-op when the rescue toplevel hash is unchanged — a pure main-app change writes
# nothing to the stick.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  active = cfg.enable && cfg.store.location == "hot" && cfg.rescue.enable;

  pkiDb = "${config.boot.lanzaboote.pkiBundle}/keys/db";

  maintain = pkgs.writeShellApplication {
    name = "nixnas-rescue-maintain";
    runtimeInputs = with pkgs; [
      nix coreutils util-linux cryptsetup systemd sbsigntool gnugrep
    ];
    text = ''
      # ── inputs ─────────────────────────────────────────────────────────────
      # (defaults keep the script eval-safe when built for the demo, where these are null;
      #  real use is gated by `active`, whose assertions require them non-null.)
      flake=${lib.escapeShellArg (if cfg.autoUpgrade.flake != null then cfg.autoUpgrade.flake else "")}
      attr=${lib.escapeShellArg (if cfg.rescue.flakeAttr != null then cfg.rescue.flakeAttr else "")}
      dbkey=${lib.escapeShellArg "${pkiDb}/db.key"}
      dbcert=${lib.escapeShellArg "${pkiDb}/db.pem"}
      esp=/boot
      espuki="$esp/EFI/Linux/nixnas-rescue.efi"
      marker=/var/lib/nixnas/rescue-installed   # the toplevel we last installed

      { [ -r "$dbkey" ] && [ -r "$dbcert" ]; } || { echo "rescue-maintain: db signing keys not readable at $dbkey" >&2; exit 1; }

      # ── 1. build the rescue toplevel from the SAME flake rev autoUpgrade uses ─
      echo "rescue-maintain: building $flake#nixosConfigurations.$attr …"
      rescueTop=$(nix build --no-link --print-out-paths \
        "$flake#nixosConfigurations.$attr.config.system.build.toplevel")

      if [ -f "$marker" ] && [ "$(cat "$marker")" = "$rescueTop" ] && [ -f "$espuki" ]; then
        echo "rescue-maintain: rescue unchanged ($rescueTop) — nothing to do."
        exit 0
      fi

      # ── 2. assemble a SELF-CONTAINED UKI (no EFI/nixos dependency) ───────────
      # init= pins the rescue toplevel directly, so the stick needs no Nix profile symlink.
      cmdline="init=$rescueTop/init $(cat "$rescueTop/kernel-params")"
      work=$(mktemp -d /run/nixnas-rescue.XXXXXX)
      trap 'rm -rf "$work"; [ -n "''${MNT:-}" ] && umount "$MNT" 2>/dev/null; cryptsetup close nixnas-rescue-store 2>/dev/null || true' EXIT
      uki="$work/nixnas-rescue.efi"
      ${pkgs.systemdUkify}/bin/ukify build \
        --linux="$rescueTop/kernel" \
        --initrd="$rescueTop/initrd" \
        --cmdline="$cmdline" \
        --os-release="@$rescueTop/etc/os-release" \
        --output="$uki"

      # ── 3. sign with the db key (same key lanzaboote enrolled) ───────────────
      sbsign --key "$dbkey" --cert "$dbcert" --output "$work/nixnas-rescue.signed.efi" "$uki"

      # ── 4. put the rescue CLOSURE on the stick f2fs store ────────────────────
      # The stick = the disk backing /boot; its 2nd partition is the rescue store (LUKS→f2fs).
      espsrc=$(findmnt -no SOURCE "$esp")                       # /dev/sdX1 (or /dev/disk/by-…-part1)
      stickdisk=$(lsblk -no PKNAME "$espsrc" | head -1)         # sdX
      storepart="/dev/$(lsblk -rno NAME,PARTN "/dev/$stickdisk" | awk '$2==2{print $1}' | head -1)"
      [ -b "$storepart" ] || { echo "rescue-maintain: could not find the stick rescue-store partition (disk /dev/$stickdisk)" >&2; exit 1; }

      # TPM2-unlock the (non-secret) rescue store — same posture as usb mode; no data here.
      cryptsetup open --token-only "$storepart" nixnas-rescue-store
      MNT="$work/mnt"; mkdir -p "$MNT/nix"
      mount /dev/mapper/nixnas-rescue-store "$MNT/nix"          # f2fs root IS /nix → /nix/store under it
      # $MNT is now a chroot store root: nix copy registers the closure into $MNT/nix/store.
      nix copy --no-check-sigs --to "$MNT" "$rescueTop"
      sync
      umount "$MNT/nix"; MNT=""
      cryptsetup close nixnas-rescue-store

      # ── 5. atomically place the signed UKI on the ESP (keep one rollback) ────
      mkdir -p "$esp/EFI/Linux"
      [ -f "$espuki" ] && cp -f "$espuki" "$esp/EFI/Linux/nixnas-rescue-prev.efi"
      install -m0644 "$work/nixnas-rescue.signed.efi" "$espuki.new"
      mv -f "$espuki.new" "$espuki"                             # rename = atomic on the same fs
      sync

      mkdir -p "$(dirname "$marker")"; printf '%s' "$rescueTop" > "$marker"
      echo "rescue-maintain: installed rescue $rescueTop → $espuki (+ closure on the stick)."
    '';
  };
in
{
  # Expose the maintainer script UNCONDITIONALLY so CI can build it (writeShellApplication
  # runs shellcheck at build time — that is the cheap guard on this complex shell). Building
  # it forces the db-key path via config.boot.lanzaboote.pkiBundle, which resolves whenever
  # Secure Boot is on (always, for any real host and the demo).
  config = lib.mkMerge [
    { system.build.rescueMaintainer = maintain; }

    (lib.mkIf active {
    assertions = [
      {
        assertion = cfg.rescue.flakeAttr != null;
        message = "nixnas.rescue.enable requires nixnas.rescue.flakeAttr (the rescue nixosConfigurations attr).";
      }
      {
        assertion = cfg.autoUpgrade.flake != null;
        message = "the rescue maintainer builds from autoUpgrade.flake — set nixnas.autoUpgrade.flake.";
      }
      {
        assertion = cfg.boot.secureBoot.enable && cfg.boot.secureBoot.keysSops != null;
        message = "rescue-maintain signs the rescue UKI with lanzaboote's db key — hot mode needs stable Secure Boot keys (secureBoot.keysSops).";
      }
    ];

    # Run after each autoUpgrade (and once at boot, to self-heal a wiped/updated ESP entry).
    systemd.services.nixnas-rescue-maintain = {
      description = "Maintain the nixnas RESCUE system on the stick (closure + signed UKI)";
      after = [ "nixos-upgrade.service" "local-fs.target" ];
      wants = [ "local-fs.target" ];
      # not wantedBy multi-user — triggered by the timer/upgrade, and by boot self-heal below
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe maintain;
        # Building + signing + a cross-store copy: give it room, but never block boot.
        TimeoutStartSec = "30min";
      };
    };

    # Self-heal: after the FIRST main install (which wipes the rescue's original lanzaboote
    # entry), and after any main lzbt run, re-place nixnas-rescue.efi on the next boot.
    systemd.timers.nixnas-rescue-maintain = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "1d";     # daily catch-up even without an autoUpgrade
        Persistent = true;
      };
    };

    # The maintainer is a handy manual command too (nixnas-rescue-maintain).
    environment.systemPackages = [ maintain ];
    })
  ];
}
