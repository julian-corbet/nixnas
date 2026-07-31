# nixnas — the boot-stance bridge: `nixnas.boot.*` values feed nixboot's own mechanism.
#
# THE FULL CUTOVER (docs/../knowledge/hosts/shared/nixnas-boot-convergence.md is the analysis
# this is built on). This appliance used to hand-roll THREE mechanisms nixboot
# (github:julian-corbet/nixboot-corbet-ch) now owns as a public sibling: the loader/Secure-Boot
# stance (formerly ./secureboot.nix + the loader/console half of ./image.nix), headless remote
# unlock (formerly ./remote-unlock.nix), and the rollback failsafe (formerly ./rollback.nix). All
# three files are DELETED, not coexisting — nixnas writes at PLAIN priority (100) and nixboot at
# `mkOverride 500`, so leaving both wired would have nixnas's own writes win nearly everywhere
# (the one place they didn't, `boot.loader.timeout`'s `mkDefault`, was the proof-of-priority
# canary during the port, not a design to keep). Worse, `preStart`/`extraConfig` are `types.lines`
# and CONCATENATE at any priority regardless of who wins — so a coexistence period would have run
# BOTH modules' initrd-SSH fallback scripts spliced into one shell body, with whichever module's
# `exit 0` landed first silently starving the other's logic. Neither hazard is survivable as a
# staged migration; this file IS the cutover, in one pass.
#
# This module owns ONLY the translation: reads `nixnas.boot.*` / `nixnas.crypto.tpm2.*` /
# `nixnas.admin.authorizedKeys` (still nixnas's own public option surface, UNCHANGED by this
# migration — no host, in this repo or any consumer, needs to edit a single value) and writes
# nixboot's `nixboot.*` options. `./image.nix` keeps the geometry nixboot explicitly disclaims
# (`boot.initrd.systemd.enable`, the data-pool kernel modules); `../store/location.nix` keeps the
# fileSystems/ZFS-import geometry and now feeds nixluks (a separate sibling, see that file's own
# header) instead of hand-rolling the LUKS-open chain itself.
#
# WHAT WAS PORTED VERBATIM (nixboot already carries the identical mechanism, ported FROM this
# appliance in the first place — see nixboot's own module header, which cites this repo's exact
# file:line ranges): the TPM2-sealed-credential initrd-SSH host key + its self-healing reseal
# service, the ephemeral first-boot fallback, the DA-lockout Restart="no" guard, the
# generate-sb-keys landlock/ENOENT workaround, kept-generation depth, lanzaboote boot-counting,
# console ordering. Nothing about THOSE mechanisms changed; only which module renders them did.
#
# WHAT WAS DELIBERATELY IMPROVED UPSTREAM, IN NIXBOOT ITSELF, RATHER THAN KEPT AS A SECOND
# NIXNAS-SIDE TOOL (nixboot-corbet-ch/modules/nixboot.nix's own `enrollSb`, ported this pass):
#   1. a friendly "no key material yet" precondition check before firmware enrollment (the old
#      `nixnas-enroll-sb` had this; the pre-port `nixboot-enroll-sb` only checked the OPTION was
#      set, not that the key file existed, and failed with a raw sbctl error instead).
#   2. re-reading the SetupMode efivar AFTER enrollment and reporting what firmware actually says
#      (the pre-port tool printed a static message regardless of outcome).
#   3. the firmware ADMIN PASSWORD reminder in the final output — the actual evil-maid defence
#      the whole exercise exists for (missing from the pre-port tool entirely).
# These are generic improvements to a public tool every nixboot consumer benefits from, not
# nixnas-specific behaviour — so they were fixed at the source instead of re-forked here. nixnas
# now installs nixboot's own tool (`config.system.build.nixbootEnrollSb`) under the `nixnas-
# enroll-sb` name operators already know, via the thin wrapper below.
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
  # encrypted store) so it survives the tmpfs root / reboots either way. UNCHANGED from
  # the deleted ./secureboot.nix — every consumer of this path (rescue-maintain's own
  # `pkiDb = "${config.boot.lanzaboote.pkiBundle}/keys/db"`, the enrollment tool below)
  # reads it back off `config.boot.lanzaboote.pkiBundle`, which nixboot itself now sets
  # from `nixboot.secureBoot.pkiBundle` below — so this string has exactly one home.
  pkiBundle = "/nix/lanzaboote/pki";

  # Stable operator keys when supplied via sops; autogenerate only as the keyless demo
  # fallback. Same decision `./secureboot.nix` used to make locally, restated as nixboot's
  # own explicit `keySource` enum instead of an implicit "is a key path set" inference.
  provideStableKeys = cfg.boot.secureBoot.keysSops != null;

  # ── nixnas-enroll-sb: nixboot's own tool, wrapped under the name operators already know,
  # with the one reminder nixboot cannot carry (see the header above). The three checks that
  # WERE nixnas-specific (readability precondition, SetupMode re-check, firmware-password
  # reminder) are now nixboot's own, upstream — see this file's own header. `system.build.
  # nixbootEnrollSb` is exposed UNCONDITIONALLY by nixboot (nixboot.nix: "Exposed
  # unconditionally... so nix flake check forces and shellchecks this derivation"), so it
  # resolves here regardless of `nixboot.secureBoot.enrollTool.enable` below.
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

    ## ── Loader stance (formerly ./secureboot.nix's `boot.lanzaboote.enable` +
    ## ./image.nix's `boot.loader.systemd-boot.enable`/`.efi.canTouchEfiVariables`) ──────────
    # lanzaboote only when Secure Boot is on; otherwise plain systemd-boot — the exact
    # either/or ./secureboot.nix's `mkForce false` + ./image.nix's plain `true` produced,
    # now expressed as nixboot's own single-source-of-truth enum.
    nixboot.loader.program = if cfg.boot.secureBoot.enable then "lanzaboote" else "systemd-boot";
    # Removable image → never write EFI variables (the stick boots on any box). UNCHANGED
    # from ./image.nix's `boot.loader.efi.canTouchEfiVariables = false`, on EVERY nixnas host
    # (never gated to usb/secureBoot — the same unconditional posture the old write had).
    nixboot.loader.efiVariables = "removable";
    # Menu timeout: long enough for a HUMAN to reach the generation menu (the guaranteed
    # manual rollback). UNCHANGED value from ./image.nix's `mkDefault 5` (a 1 s flash is
    # unusable). No consumer host overrides this today (grepped for a plain-priority
    # `boot.loader.timeout` definition across every nixnas host file: none), so — unlike the
    # old `mkDefault`, which existed to let a host override it — a plain value is honest here.
    nixboot.loader.timeout = 5;
    # DELIBERATE VALUE CHANGE, called out rather than silently inherited: the old code never
    # touched `boot.loader.systemd-boot.editor`, so NixOS's own default (true) stood — a
    # console operator could edit the kernel command line from the boot menu. nixboot
    # defaults this to false, with its own reasoning: "Harmless under a signed UKI... but
    # loose posture on a host whose whole point is operator-owned keys." nixnas IS exactly
    # that host, so this is adopted as an intentional hardening, not an oversight — see the
    # VERIFY BY VALUE report for the before/after.
    nixboot.loader.editor = false;

    ## ── ESP: declared facts nixboot-verify can check against, not previously stated ────────
    # Both usb-mode's own disko-formatted ESP and the hot-mode MAIN's shared `/boot` mount
    # (../store/location.nix) carry the SAME FAT label "ESP" (disko: `extraArgs = ["-n"
    # "ESP"]`; location.nix mounts `/dev/disk/by-label/ESP`) — new, not previously checked
    # anywhere; nixboot-verify's Check 2 now confirms it post-boot.
    nixboot.esp.byLabel = "ESP";
    # Closes a real gap the analysis this file is built on flagged by name: without this,
    # nixboot's own ESP-capacity warning (Check 3 / the eval-time 75%-of-capacity warning)
    # stays PERMANENTLY INERT (`capacityMiB` defaults null) even after `nixboot.enable =
    # true` — looking like a safety net that was never actually wired. `nixnas.boot.usb.
    # espSizeMiB` is the SAME fact ./disk.nix sizes the on-stick ESP partition from (usb
    # mode) — for a hot-mode MAIN sharing the rescue's stick ESP, the consuming host must
    # set this to the REAL shared-stick value (see infra's own hosts/nixnas.nix for how).
    nixboot.esp.capacityMiB = cfg.boot.usb.espSizeMiB;

    ## ── Console (formerly ./image.nix's `boot.kernelParams` console= ordering) ─────────────
    # ALWAYS managed (never null) — nixnas always wants console arbitration, on both modes,
    # unlike nixboot's own generic default (null = "don't manage", since a generic host may
    # have no console worth arbitrating at all). serialDevice/serialBaud stay at nixboot's
    # own defaults (ttyS0 / 115200), byte-identical to ./image.nix's old hardcoded values.
    nixboot.console.primary = cfg.boot.consolePrimary;

    ## ── Generations / rollback (formerly ./rollback.nix) ───────────────────────────────────
    nixboot.generations.keep = cfg.boot.keepGenerations;
    # Boot-counting only exists on the Secure Boot path (the lanzaboote stub renames/counts
    # the entries) — UNCHANGED gate from ./rollback.nix's own `lib.mkIf cfg.boot.secureBoot.
    # enable cfg.boot.tries`, restated against nixboot's `nullOr` type (null = "no counting",
    # asserted by nixboot to require `loader.program == "lanzaboote"` — always true here when
    # this is non-null, since the gate below matches the loader.program derivation above).
    nixboot.bootCounting.tries = if cfg.boot.secureBoot.enable then cfg.boot.tries else null;

    ## ── Secure Boot (formerly ./secureboot.nix) ─────────────────────────────────────────────
    nixboot.secureBoot.enable = cfg.boot.secureBoot.enable;
    nixboot.secureBoot.pkiBundle = pkiBundle;
    nixboot.secureBoot.keySource = if provideStableKeys then "stable" else "autogenerate";
    nixboot.secureBoot.opromPolicy = cfg.boot.secureBoot.opromPolicy;
    # UNCHANGED scope from ./secureboot.nix: "The firmware enrollment tool ships on
    # STICK-RESIDENT systems (usb mode — which includes the hot-mode RESCUE)... A hot-mode
    # MAIN never needs it — its stick's rescue system carries it." nixboot's own
    # `enrollTool.enable` has no such notion (it only gates on `secureBoot.enable`), so this
    # appliance states the extra condition itself rather than let a hot-mode MAIN newly
    # acquire an enrollment tool it never had and never needs (nothing to enroll: its ESP is
    # the rescue's, and the rescue is what enrolls).
    nixboot.secureBoot.enrollTool.enable = cfg.store.location == "usb";
    # tools.sbctl.enable / tools.sbsigntool.enable / secureBoot.sbctlCompat are left at
    # nixboot's own defaults (all default to `secureBoot.enable`) — a genuine, welcome
    # addition: raw `sbctl`/`sbsign`/`sbverify` on PATH and a working `sbctl status` on every
    # Secure-Boot host, which the old code never provided (only the wrapped `nixnas-enroll-
    # sb` tool existed, with sbctl as an internal runtime dependency, not on PATH itself).

    ## ── Remote unlock (formerly ./remote-unlock.nix) ───────────────────────────────────────
    nixboot.remoteUnlock.enable = cfg.boot.remoteUnlock.enable;
    # Reuses nixnas's OWN admin key list — deliberately the SAME list the running system's
    # sshd already trusts (modules/appliance/ssh.nix), never a second, independently-typed
    # list. This is what nixboot's own option doc warns a generic consumer to avoid
    # duplicating: "don't invent a second list here, that's exactly the concatenated,
    # quietly broader collision."
    nixboot.remoteUnlock.authorizedKeys = cfg.admin.authorizedKeys;
    nixboot.remoteUnlock.sealHostKey = cfg.boot.remoteUnlock.sealHostKey;
    nixboot.remoteUnlock.hostKeyPath = cfg.boot.remoteUnlock.hostKeyPath;
    # Mirrors nixnas's OWN data-unlock TPM2 enable flag (never its PCR list — see below).
    nixboot.remoteUnlock.tpm2.enable = cfg.crypto.tpm2.enable;
    # DELIBERATELY NOT mirrored: `nixboot.remoteUnlock.tpm2.pcrs` stays at ITS OWN default
    # `[ 7 ]`. The old ./remote-unlock.nix hardcoded `--tpm2-pcrs=7` for the host-key seal
    # regardless of `crypto.tpm2.pcrs` (the DATA unlock's own, possibly-extended PCR set,
    # e.g. hosts/matrix/pin-strict.nix's `[ 7 11 ]`) — the two seals are deliberately
    # decoupled (nixboot's own option doc: "nixnas's host-key seal hardcodes PCR 7
    # regardless of the data-unlock's own... PCR policy"). Mirroring `crypto.tpm2.pcrs` here
    # would silently change the host-key seal's PCR set and could turn its "reseal exactly
    # once, at SB enrollment" self-heal into "reseal on every generation" if the extra PCR
    # changes more often than PCR 7 does.

    # The firmware enrollment tool ships on STICK-RESIDENT systems only (see
    # secureBoot.enrollTool.enable's own gate above) — same host set as before.
    environment.systemPackages = lib.optional (cfg.store.location == "usb") nixnasEnrollSb;
    system.build.sbEnroller = nixnasEnrollSb;
  };
}
