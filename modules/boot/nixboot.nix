# nixnas — the boot-stance bridge: `nixnas.boot.*` values feed nixboot's own mechanism.
#
# This module owns ONLY the translation: reads `nixnas.boot.*` / `nixnas.crypto.tpm2.*` /
# `nixnas.admin.authorizedKeys` (nixnas's own public option surface) and writes nixboot's
# `nixboot.*` options. `./image.nix` keeps the geometry nixboot explicitly disclaims
# (`boot.initrd.systemd.enable`, the data-pool kernel modules); `../store/location.nix` keeps the
# fileSystems/ZFS-import geometry and feeds nixluks (a separate sibling, see that file's own
# header) instead of hand-rolling the LUKS-open chain itself.
#
# `nixnas-enroll-sb` below is a thin wrapper around nixboot's own `enrollSb`
# (`config.system.build.nixbootEnrollSb`, exposed unconditionally by nixboot itself): the
# friendly "no key material yet" precondition check, the post-enrollment SetupMode re-read, and
# the firmware ADMIN PASSWORD reminder all live upstream now, as generic improvements every
# nixboot consumer benefits from, so nixnas installs nixboot's own tool under the operator-known
# `nixnas-enroll-sb` name rather than forking a second copy.
#
# WHAT NIXBOOT CANNOT CARRY, AND WHY THIS FILE STILL PRINTS IT: the reminder to re-run the DATA
# store's own TPM2 enrollment (`nixnas-enroll-tpm2`, ../crypto/tpm2.nix) after a Secure Boot
# enrollment changes PCR 7. This is correctly OUTSIDE nixboot's scope — it has no knowledge of
# nixnas's data-unlock TPM2 policy, and its own `remoteUnlock.tpm2.*` is a same-shaped MIRROR of a
# DIFFERENT seal (the initrd-SSH host key), never the data store's own policy (see nixboot's own
# `remoteUnlock.tpm2.enable` option doc for exactly why the two are decoupled). Only nixnas, which
# owns both the Secure Boot enrollment trigger AND the data-store TPM2 policy, can correctly join
# them — so the wrapper below appends this ONE nixnas-specific line after nixboot's own tool exits
# successfully, rather than teaching nixboot a concept it should not have.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;

  # Persistent location for the PKI bundle (PK / KEK / db). Must be under /nix (the LUKS-
  # encrypted store) so it survives the tmpfs root / reboots either way. Every consumer of this
  # path (rescue-maintain's own `pkiDb = "${config.boot.lanzaboote.pkiBundle}/keys/db"`, the
  # enrollment tool below) reads it back off `config.boot.lanzaboote.pkiBundle`, which nixboot
  # itself now sets from `nixboot.secureBoot.pkiBundle` below — so this string has exactly one
  # home.
  pkiBundle = "/nix/lanzaboote/pki";

  # Stable operator keys when supplied via sops; autogenerate only as the keyless demo fallback.
  provideStableKeys = cfg.boot.secureBoot.keysSops != null;

  # ── nixnas-enroll-sb: nixboot's own tool, wrapped under the name operators already know, with
  # the one reminder nixboot cannot carry (see the header above). `system.build.nixbootEnrollSb`
  # is exposed UNCONDITIONALLY by nixboot (so `nix flake check` forces and shellchecks this
  # derivation), so it resolves here regardless of `nixboot.secureBoot.enrollTool.enable` below.
  nixnasEnrollSb = pkgs.writeShellApplication {
    name = "nixnas-enroll-sb";
    text = ''
      ${lib.getExe config.system.build.nixbootEnrollSb}
      cat <<'EOF'

      nixnas: PCR 7 just changed (Secure Boot key enrollment). If you enrolled a TPM2 store
      keyslot (nixnas-enroll-tpm2), RE-RUN it now to re-bind it to the new PCR 7 — until then
      the store opens via the passphrase/recovery keyslot every boot, not the TPM2 PIN.
      EOF
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    nixboot.enable = true;

    ## ── Loader stance ───────────────────────────────────────────────────────────────────────
    # lanzaboote only when Secure Boot is on; otherwise plain systemd-boot -- expressed as
    # nixboot's own single-source-of-truth enum.
    nixboot.loader.program = if cfg.boot.secureBoot.enable then "lanzaboote" else "systemd-boot";
    # Removable image → never write EFI variables (the stick boots on any box). Unconditional on
    # every nixnas host, never gated to usb/secureBoot.
    nixboot.loader.efiVariables = "removable";
    # Menu timeout: long enough for a HUMAN to reach the generation menu (the guaranteed manual
    # rollback) -- a 1 s flash is unusable. No consumer host overrides this today (grepped for a
    # plain-priority `boot.loader.timeout` definition across every nixnas host file: none), so a
    # plain value is honest here.
    nixboot.loader.timeout = 5;
    # A console operator could otherwise edit the kernel command line from the boot menu (NixOS's
    # own default for this is true). nixboot defaults this to false, with its own reasoning:
    # "Harmless under a signed UKI... but loose posture on a host whose whole point is
    # operator-owned keys." nixnas IS exactly that host, so this is adopted as an intentional
    # hardening, not an oversight.
    nixboot.loader.editor = false;

    ## ── ESP: declared facts nixboot-verify can check against ───────────────────────────────
    # Both usb-mode's own disko-formatted ESP and the hot-mode MAIN's shared `/boot` mount
    # (../store/location.nix) carry the SAME FAT label "ESP" (disko: `extraArgs = ["-n"
    # "ESP"]`; location.nix mounts `/dev/disk/by-label/ESP`) -- nixboot-verify's Check 2 confirms
    # it post-boot.
    nixboot.esp.byLabel = "ESP";
    # Without this, nixboot's own ESP-capacity warning (Check 3 / the eval-time 75%-of-capacity
    # warning) stays PERMANENTLY INERT (`capacityMiB` defaults null) even after `nixboot.enable =
    # true` -- looking like a safety net that was never actually wired. `nixnas.boot.usb.
    # espSizeMiB` is the SAME fact ./disk.nix sizes the on-stick ESP partition from (usb
    # mode) -- for a hot-mode MAIN sharing the rescue's stick ESP, the consuming host must
    # set this to the REAL shared-stick value (see infra's own hosts/nixnas.nix for how).
    nixboot.esp.capacityMiB = cfg.boot.usb.espSizeMiB;

    ## ── Console ─────────────────────────────────────────────────────────────────────────────
    # ALWAYS managed (never null) -- nixnas always wants console arbitration, on both modes,
    # unlike nixboot's own generic default (null = "don't manage", since a generic host may
    # have no console worth arbitrating at all). serialDevice/serialBaud stay at nixboot's
    # own defaults (ttyS0 / 115200).
    nixboot.console.primary = cfg.boot.consolePrimary;

    ## ── Generations / rollback ──────────────────────────────────────────────────────────────
    nixboot.generations.keep = cfg.boot.keepGenerations;
    # Boot-counting only exists on the Secure Boot path (the lanzaboote stub renames/counts
    # the entries) -- restated against nixboot's `nullOr` type (null = "no counting",
    # asserted by nixboot to require `loader.program == "lanzaboote"` -- always true here when
    # this is non-null, since the gate below matches the loader.program derivation above).
    nixboot.bootCounting.tries = if cfg.boot.secureBoot.enable then cfg.boot.tries else null;

    ## ── Secure Boot ─────────────────────────────────────────────────────────────────────────
    nixboot.secureBoot.enable = cfg.boot.secureBoot.enable;
    nixboot.secureBoot.pkiBundle = pkiBundle;
    nixboot.secureBoot.keySource = if provideStableKeys then "stable" else "autogenerate";
    nixboot.secureBoot.opromPolicy = cfg.boot.secureBoot.opromPolicy;
    # The firmware enrollment tool ships on STICK-RESIDENT systems (usb mode -- which includes
    # the hot-mode RESCUE). A hot-mode MAIN never needs it -- its stick's rescue system carries
    # it. nixboot's own `enrollTool.enable` has no such notion (it only gates on
    # `secureBoot.enable`), so this appliance states the extra condition itself rather than let a
    # hot-mode MAIN newly acquire an enrollment tool it never had and never needs (nothing to
    # enroll: its ESP is the rescue's, and the rescue is what enrolls).
    nixboot.secureBoot.enrollTool.enable = cfg.store.location == "usb";
    # tools.sbctl.enable / tools.sbsigntool.enable / secureBoot.sbctlCompat are left at
    # nixboot's own defaults (all default to `secureBoot.enable`): raw `sbctl`/`sbsign`/`sbverify`
    # on PATH and a working `sbctl status` on every Secure-Boot host.

    ## ── Remote unlock ───────────────────────────────────────────────────────────────────────
    nixboot.remoteUnlock.enable = cfg.boot.remoteUnlock.enable;
    # Reuses nixnas's OWN admin key list -- deliberately the SAME list the running system's
    # sshd already trusts (modules/appliance/ssh.nix), never a second, independently-typed
    # list. This is what nixboot's own option doc warns a generic consumer to avoid
    # duplicating: "don't invent a second list here, that's exactly the concatenated,
    # quietly broader collision."
    nixboot.remoteUnlock.authorizedKeys = cfg.admin.authorizedKeys;
    nixboot.remoteUnlock.sealHostKey = cfg.boot.remoteUnlock.sealHostKey;
    nixboot.remoteUnlock.hostKeyPath = cfg.boot.remoteUnlock.hostKeyPath;
    # Mirrors nixnas's OWN data-unlock TPM2 enable flag (never its PCR list -- see below).
    nixboot.remoteUnlock.tpm2.enable = cfg.crypto.tpm2.enable;
    # DELIBERATELY NOT mirrored: `nixboot.remoteUnlock.tpm2.pcrs` stays at ITS OWN default
    # `[ 7 ]`, hardcoded regardless of `crypto.tpm2.pcrs` (the DATA unlock's own, possibly-
    # extended PCR set, e.g. hosts/matrix/pin-strict.nix's `[ 7 11 ]`) -- the two seals are
    # deliberately decoupled (nixboot's own option doc: "nixnas's host-key seal hardcodes PCR 7
    # regardless of the data-unlock's own... PCR policy"). Mirroring `crypto.tpm2.pcrs` here
    # would silently change the host-key seal's PCR set and could turn its "reseal exactly
    # once, at SB enrollment" self-heal into "reseal on every generation" if the extra PCR
    # changes more often than PCR 7 does.

    # The firmware enrollment tool ships on STICK-RESIDENT systems only (see
    # secureBoot.enrollTool.enable's own gate above).
    environment.systemPackages = lib.optional (cfg.store.location == "usb") nixnasEnrollSb;
    system.build.sbEnroller = nixnasEnrollSb;
  };
}
