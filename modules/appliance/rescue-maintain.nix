# nixnas — the paired upgrade: the MAIN (hot) system keeps the RESCUE current on the stick.
#
# In `hot` mode two independent systems share the stick: the MAIN's /nix is on the pool, and
# a self-contained RESCUE lives on the stick (its f2fs store + a UKI on the shared ESP). The
# rescue is rarely booted, so it can't self-upgrade — the running MAIN maintains it, from a
# rescue toplevel that is either deploy-PINNED (rescue.toplevel — hub-built boxes) or built
# from the same flake autoUpgrade pulls (rescue.flakeAttr — self-upgrading boxes).
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
# WHAT THE MAINTAINER DOES, each run:
#   1. resolve the rescue toplevel (pinned or built),
#   2. build a self-contained UKI from its kernel+initrd+cmdline (init= points AT that
#      toplevel, so no stick-side Nix profile bookkeeping is needed),
#   3. sign the UKI with the db key,
#   4. TPM2-unlock (systemd-cryptsetup — the token is a systemd-tpm2 token plain cryptsetup
#      cannot read) + mount the stick's rescue f2fs WITH the shared compression options,
#      `nix copy` the closure onto it, and GC the stick store down to current+prev,
#   5. atomically place the signed UKI at ESP:/EFI/Linux/nixnas-rescue.efi (rotating the
#      previous, DIFFERENT one to nixnas-rescue-prev.efi as a one-step rescue rollback).
# It no-ops when the installed toplevel (persistent marker on /nix) is already current.
#
# TRIGGERS: wantedBy multi-user.target — runs at boot (self-heals a pruned ESP entry), and
# because the script embeds the pinned toplevel path, a deploy that changes the rescue also
# changes THIS unit → switch-to-configuration restarts it (deploy-triggered maintenance).
# A daily timer catches flake-built (non-pinned) drift.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  active = cfg.enable && cfg.store.location == "hot" && cfg.rescue.enable;

  pkiDb = "${config.boot.lanzaboote.pkiBundle}/keys/db";
  f2fsOpts = lib.concatStringsSep "," (import ../lib/f2fs-store-mount-opts.nix);
  sdCryptsetup = "${pkgs.systemd}/lib/systemd/systemd-cryptsetup";

  maintain = pkgs.writeShellApplication {
    name = "nixnas-rescue-maintain";
    runtimeInputs = with pkgs; [
      nix coreutils util-linux cryptsetup systemd sbsigntool gnugrep gawk
    ];
    text = ''
      # ── inputs ─────────────────────────────────────────────────────────────
      # (defaults keep the script eval-safe when built for the demo, where these are null;
      #  real use is gated by `active`, whose assertions require a rescue source.)
      flake=${lib.escapeShellArg (if cfg.autoUpgrade.flake != null then cfg.autoUpgrade.flake else "")}
      attr=${lib.escapeShellArg (if cfg.rescue.flakeAttr != null then cfg.rescue.flakeAttr else "")}
      pinnedTop=${if cfg.rescue.toplevel != null then cfg.rescue.toplevel else "\"\""}
      dbkey=${lib.escapeShellArg "${pkiDb}/db.key"}
      dbcert=${lib.escapeShellArg "${pkiDb}/db.pem"}
      esp=/boot
      espuki="$esp/EFI/Linux/nixnas-rescue.efi"
      # Persistent marker (hot mode: /nix IS the pool) — the toplevel we last installed.
      marker=/nix/nixnas/rescue-installed
      # Mountpoint OUTSIDE the scratch dir, so cleanup can never rm through a live mount.
      mnt=/run/nixnas-rescue-maintain

      { [ -r "$dbkey" ] && [ -r "$dbcert" ]; } || { echo "rescue-maintain: db signing keys not readable at $dbkey" >&2; exit 1; }

      # ── 1. resolve the rescue toplevel ────────────────────────────────────
      # Hub-built boxes pin it at eval time (rescue.toplevel — the interpolation above makes
      # it a store reference, so every main deploy carries the rescue closure). Self-upgrading
      # boxes build it from the same flake rev autoUpgrade pulls.
      if [ -n "$pinnedTop" ]; then
        rescueTop="$pinnedTop"
        echo "rescue-maintain: using the deploy-pinned rescue toplevel $rescueTop"
      else
        echo "rescue-maintain: building $flake#nixosConfigurations.$attr …"
        rescueTop=$(nix build --no-link --print-out-paths \
          "$flake#nixosConfigurations.$attr.config.system.build.toplevel")
      fi

      if [ -f "$marker" ] && [ "$(cat "$marker")" = "$rescueTop" ] && [ -f "$espuki" ]; then
        echo "rescue-maintain: rescue unchanged ($rescueTop) — nothing to do."
        exit 0
      fi

      # ── cleanup: unmount FIRST, close the mapper, delete scratch LAST ──────
      work=$(mktemp -d /run/nixnas-rescue-work.XXXXXX)
      cleanup() {
        umount "$mnt/nix" 2>/dev/null || true
        ${sdCryptsetup} detach nixnas-rescue-store 2>/dev/null || true
        rm -rf --one-file-system "$work" "$mnt"
      }
      trap cleanup EXIT

      # ── 2. assemble a SELF-CONTAINED UKI (no EFI/nixos dependency) ───────────
      # init= pins the rescue toplevel directly, so the stick needs no Nix profile symlink.
      cmdline="init=$rescueTop/init $(cat "$rescueTop/kernel-params")"
      uki="$work/nixnas-rescue.efi"
      osrel=()   # cosmetic (menu title); only pass it if the toplevel exposes it
      [ -e "$rescueTop/etc/os-release" ] && osrel=(--os-release="@$rescueTop/etc/os-release")
      ${pkgs.systemdUkify}/bin/ukify build \
        --linux="$rescueTop/kernel" \
        --initrd="$rescueTop/initrd" \
        --cmdline="$cmdline" \
        "''${osrel[@]}" \
        --output="$uki"

      # ── 3. sign with the db key (same key lanzaboote enrolled) ───────────────
      signed="$work/nixnas-rescue.signed.efi"
      sbsign --key "$dbkey" --cert "$dbcert" --output "$signed" "$uki"

      # ── 4. put the rescue CLOSURE on the stick f2fs store ────────────────────
      # The stick = the disk backing /boot; its 2nd partition is the rescue store (LUKS→f2fs).
      espsrc=$(findmnt -no SOURCE "$esp")                       # the real /dev node (fstab may say by-label)
      stickdisk=$(lsblk -no PKNAME "$espsrc" | head -1)         # sdX / nvme0n1
      storepart="/dev/$(lsblk -rno NAME,PARTN "/dev/$stickdisk" | awk '$2==2{print $1}' | head -1)"
      [ -b "$storepart" ] || { echo "rescue-maintain: could not find the stick rescue-store partition (disk /dev/$stickdisk)" >&2; exit 1; }

      # TPM2-unlock (non-secret store, same posture as usb mode). The keyslot is a
      # systemd-tpm2 LUKS2 token — plain `cryptsetup open` cannot read it on NixOS
      # (no external token plugin path), so use systemd's own tool.
      if [ ! -e /dev/mapper/nixnas-rescue-store ]; then
        ${sdCryptsetup} attach nixnas-rescue-store "$storepart" - tpm2-device=auto \
          || { echo "rescue-maintain: TPM2 attach failed — was the rescue store enrolled (nixnas-enroll-tpm2, on the rescue)?" >&2; exit 1; }
      fi
      mkdir -p "$mnt/nix"
      # The SHARED f2fs options (modules/lib/f2fs-store-mount-opts.nix): a bare mount would
      # write the new closure UNCOMPRESSED and blow the stick budget.
      mount -o ${lib.escapeShellArg f2fsOpts} /dev/mapper/nixnas-rescue-store "$mnt/nix"
      # $mnt is a chroot store root: nix copy registers the closure into $mnt/nix/store.
      nix copy --no-check-sigs --to "$mnt" "$rescueTop"
      # GC the stick store down to current + prev (mirrors the UKI rotation below) — without
      # this the ~5 GiB stick fills after a few rescue updates.
      roots="$mnt/nix/var/nix/gcroots"; mkdir -p "$roots"
      if [ -L "$roots/rescue-current" ] && [ "$(readlink "$roots/rescue-current")" != "$rescueTop" ]; then
        mv -f "$roots/rescue-current" "$roots/rescue-prev"
      fi
      ln -sfn "$rescueTop" "$roots/rescue-current"
      nix store gc --store "$mnt" || echo "rescue-maintain: stick GC failed (non-fatal)" >&2
      sync
      umount "$mnt/nix"
      ${sdCryptsetup} detach nixnas-rescue-store

      # ── 5. atomically place the signed UKI on the ESP (keep one REAL rollback) ─
      mkdir -p "$esp/EFI/Linux"
      # Rotate to -prev only when the installed UKI actually differs — a re-run after a lost
      # marker must not clobber the genuine previous version with an identical copy.
      if [ -f "$espuki" ] && ! cmp -s "$signed" "$espuki"; then
        cp -f "$espuki" "$esp/EFI/Linux/nixnas-rescue-prev.efi"
      fi
      install -m0644 "$signed" "$espuki.new"
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
        assertion = (cfg.rescue.toplevel != null) != (cfg.rescue.flakeAttr != null);
        message = "nixnas.rescue.enable needs exactly ONE rescue source: rescue.toplevel (hub-built/deploy-rs boxes) or rescue.flakeAttr (self-upgrading boxes).";
      }
      {
        assertion = cfg.rescue.flakeAttr != null -> cfg.autoUpgrade.flake != null;
        message = "rescue.flakeAttr builds from autoUpgrade.flake — set nixnas.autoUpgrade.flake (or use rescue.toplevel).";
      }
      {
        assertion = cfg.boot.secureBoot.enable && cfg.boot.secureBoot.keysSops != null;
        message = "rescue-maintain signs the rescue UKI with lanzaboote's db key — hot mode needs stable Secure Boot keys (secureBoot.keysSops).";
      }
    ];

    # Runs at boot (ESP self-heal after the main's lzbt runs / a fresh install), and — because
    # the script text embeds the pinned rescue toplevel — every deploy that changes the rescue
    # changes this unit, so switch-to-configuration restarts it: deploy-triggered maintenance.
    systemd.services.nixnas-rescue-maintain = {
      description = "Maintain the nixnas RESCUE system on the stick (closure + signed UKI)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "boot.mount" ];
      wants = [ "boot.mount" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe maintain;
        # Building + signing + a cross-store copy: give it room, but never block boot.
        TimeoutStartSec = "30min";
      };
    };

    # Daily catch-up — matters for the flake-built (rescue.flakeAttr) source, where the
    # rescue can drift without a deploy; harmless no-op for the pinned source.
    systemd.timers.nixnas-rescue-maintain = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnUnitActiveSec = "1d";
        Persistent = true;
      };
    };

    # The maintainer is a handy manual command too (nixnas-rescue-maintain).
    environment.systemPackages = [ maintain ];
    })
  ];
}
