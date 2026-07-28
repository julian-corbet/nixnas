# nixnas — the paired upgrade: the MAIN (hot) system keeps the RESCUE current on the stick.
#
# In `hot` mode two independent systems share the stick: the MAIN's /nix is on the pool, and
# a self-contained RESCUE lives on the stick (its f2fs store + a UKI on the shared ESP). The
# rescue is rarely booted, so it can't self-upgrade — the running MAIN maintains it, from a
# rescue toplevel that is either deploy-PINNED (rescue.toplevel — hub-built boxes) or built
# from the same flake autoUpgrade pulls (rescue.flakeAttr — self-upgrading boxes).
#
# WHO BUILDS/SIGNS/PLACES THE UKI — split by rescue source, not a free choice:
#   PINNED (rescue.toplevel != null, hub-built): `nixboot.extraEntries.rescue` owns build +
#     sign + atomic place + current/prev rotation now (github:julian-corbet/nixboot-corbet-ch,
#     modules/extra-entries.nix) — the SAME ukify+sbsign pipeline this file used to run inline,
#     generalised there and field-proved here first. This module still does everything nixboot
#     does NOT and cannot own: resolving which toplevel is current, getting its CLOSURE onto
#     the stick's f2fs store (TPM2 unlock, mount, pre-copy GC, `nix copy`, cblock release), and
#     the persisted marker that no-ops an unchanged rescue. Once the closure has landed on the
#     stick, this script hands off to nixboot's own built maintainer
#     (`config.system.build.extraEntryMaintainers.rescue`) for steps 2/3/5 below — one process
#     substitution, not two independently-scheduled units (see the SEQUENCING note below for
#     why that distinction is load-bearing).
#   SELF-UPGRADING (rescue.flakeAttr != null): stays on the ORIGINAL inline ukify+sbsign+place
#     pipeline, unchanged, below. `nixboot.extraEntries.<name>.toplevel` is typed
#     `lib.types.package` — a derivation nixboot's flake must already know AT THIS FLAKE'S OWN
#     EVAL TIME (see its own option doc: "NO DEFAULT — guessing one would be worse than
#     refusing to build"). A self-upgrading rescue's toplevel is instead resolved AT RUNTIME,
#     by `nix build` against whatever revision `autoUpgrade.flake` currently points at — a value
#     nixboot's declarative option surface cannot represent at all, not merely one it defaults
#     away from. Retiring this branch too would mean nixboot growing a runtime-toplevel
#     mechanism, which is out of scope for this migration — nixboot is consumed here as-is, not
#     extended. This is a stated, load-bearing boundary, not an oversight: every host actually
#     running in production today is hub-built (rescue.toplevel), per the fleet's own
#     build-on-hub doctrine (self-upgrading boxes do local `nix build`, which the doctrine
#     exists to avoid) — so this branch exists for the option's own documented persona, not for
#     a host this migration needs to prove itself against.
#
# SEQUENCING — why the stick copy and the ESP place must stay ONE script, not nixboot's own
# per-entry timer: nixboot.extraEntries wires its OWN `nixboot-extra-entry-<name>` timer+service
# per declared entry (see modules/extra-entries.nix), scheduled independently of whatever else
# touches that entry's `toplevel`. Composed that way here, its timer could fire and place a UKI
# whose `init=` path points at a closure NOT YET copied onto the stick — the ESP would then carry
# a rescue entry that fails to switch-root the moment it is ever booted. So this module does NOT
# rely on nixboot's own timer/service for the `rescue` entry at all (nixboot.enable stays off
# fleet-wide for nixnas hosts — see the flake.nix comment on why); it consumes only the two
# building blocks nixboot exposes UNCONDITIONALLY regardless of `nixboot.enable`
# (`nixboot.extraEntries.*` as plain option data, and the derivation
# `system.build.extraEntryMaintainers.rescue`), and calls that derivation itself, from inside
# ITS OWN copy-then-place script, strictly after the stick copy has succeeded. One timer
# (`nixnas-rescue-maintain`, unchanged below), one ordering guarantee.
#
# HOW IT COEXISTS ON ONE ESP (source-grounded — see docs/HOT-MODE.md):
#   lanzaboote's `lzbt install` (which the main runs) garbage-collects the ESP, but its
#   EFI/Linux GC deletes ONLY files whose name starts with `nixos-` (an explicit "shared with
#   other distros" carve-out), and it WIPES EFI/nixos entirely. So the rescue entry must be
#     (1) a SELF-CONTAINED UKI (kernel+initrd+cmdline in one PE — nothing in EFI/nixos), and
#     (2) named WITHOUT a `nixos-` prefix → `EFI/Linux/nixnas-rescue.efi`.
#   Then it survives every main update, and systemd-boot auto-discovers it as a menu entry.
#   nixboot's own signing (pinned path) and this file's own signing (self-upgrading path) both
#   use the SAME db key lanzaboote enrolled (`${pkiBundle}/keys/db/db.{key,pem}`) — nixboot's
#   `extraEntries.rescue.sign.pkiBundle` is pointed straight at `config.boot.lanzaboote.pkiBundle`
#   below, the identical fact this file's own `pkiDb` binding already names.
#
# WHAT THE MAINTAINER DOES, each run:
#   1. resolve the rescue toplevel (pinned or built),
#   2. PINNED: hand off to nixboot's maintainer for build+sign+place+rotate (see above).
#      SELF-UPGRADING: build a self-contained UKI from its kernel+initrd+cmdline (init= points
#      AT that toplevel, so no stick-side Nix profile bookkeeping is needed), sign it with the
#      db key, and place+rotate it — all inline, unchanged from before this migration.
#   3. (interleaved with the above) TPM2-unlock (systemd-cryptsetup — the token is a
#      systemd-tpm2 token plain cryptsetup cannot read) + mount the stick's rescue f2fs WITH
#      the shared compression options, `nix copy` the closure onto it, and GC the stick store
#      down to current+prev.
# It no-ops when the installed toplevel (persistent marker on /nix) is already current — for
# BOTH branches, from the SAME marker file, so a re-run after a code change with an unchanged
# rescueTop never re-places a UKI it does not need to (see the CRITICAL note below on why this
# also means the very first run after this migration lands is a guaranteed no-op, not a cutover).
#
# CRITICAL — no window with an invalid rescue UKI, INCLUDING across this migration itself: the
# no-op guard above (marker matches AND the ESP file already exists) fires BEFORE either branch
# ever touches the stick or the ESP. So the very first time this updated module runs against an
# UNCHANGED rescueTop, it does exactly nothing — the OLD-pipeline-built `nixnas-rescue.efi` that
# is already on the ESP stays there, untouched, byte-for-byte. The NEW (nixboot-built) pipeline
# only ever runs for the first time the next time rescueTop actually changes (a real rebuild
# trigger), at which point the atomic `install ... && mv -f` inside nixboot's own maintainer
# (identical shape to this file's own placement code, see modules/extra-entries.nix) guarantees
# the OLD UKI stays in place until the NEW one is fully built and signed — never removed first.
# This is a build-level guarantee, not a boot-tested one: this repo's checks (flake.nix) prove
# the wiring compiles, shellchecks, and preserves the espFileName/rotation/timer discipline (see
# `nixboot-extra-entry-rescue-equivalence` and `demo-hot-rescue-pinned-uki-maintainer`), but
# nothing here boots the real image. The first rescueTop change that actually exercises the new
# pinned path on a live host should be followed by one manual confirmation (e.g. `sbverify`
# against the placed `EFI/Linux/nixnas-rescue.efi`, or a boot to the rescue entry at a
# convenient maintenance window) — staged, not forced, exactly because a build alone cannot
# prove a UKI boots.
#
# TRIGGERS: a TIMER only, never a boot/switch dependency (the copy is a multi-minute cross-store
# write to a slow stick — making a boot target wait on it stalls boots AND deadlocks
# switch-to-configuration; learned the hard way 2026-07-05). OnBootSec runs it a few minutes
# after boot (async ESP/stick self-heal, off the critical path); a daily tick catches flake-built
# drift. Deploy-triggered updates land on that next tick, not synchronously — fine, the rescue is
# a fallback and its CURRENT stick UKI keeps booting meanwhile. It is idempotent (no-ops when the
# installed toplevel marker already matches). UNCHANGED by this migration — see the assertions
# below, which now also PROVE it structurally (never wantedBy a boot/switch target).
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  active = cfg.enable && cfg.store.location == "hot" && cfg.rescue.enable;

  pkiDb = "${config.boot.lanzaboote.pkiBundle}/keys/db";
  f2fsOpts = lib.concatStringsSep "," (import ../lib/f2fs-store-mount-opts.nix);
  sdCryptsetup = "${pkgs.systemd}/lib/systemd/systemd-cryptsetup";
  releaseCblocks = import ../lib/f2fs-release-cblocks.nix { inherit pkgs; };

  # ONE fact, two consumers (nixboot's declarative entry below, and this file's own legacy
  # inline placement code in the self-upgrading branch) — kept as a single binding so the two
  # pipelines can never independently drift onto different filenames. Must never start with
  # "nixos-" (both lanzaboote's EFI/Linux GC and stock systemd-boot's configurationLimit GC key
  # their own generation cleanup on that prefix — asserted below, not merely commented) and must
  # end in ".efi" (what both loaders' UKI auto-discovery scans EFI/Linux for).
  rescueEspFileName = "nixnas-rescue.efi";
  # The nixboot.extraEntries attribute name for the rescue entry — also the root of the
  # per-entry systemd unit name nixboot generates should its own `nixboot.enable` ever be turned
  # on for a nixnas host (it stays off here; see the SEQUENCING note above), and of the binary
  # name (`nixboot-extra-entry-rescue`) this file execs directly in the pinned branch.
  rescueEntryName = "rescue";

  maintain = pkgs.writeShellApplication {
    name = "nixnas-rescue-maintain";
    runtimeInputs = with pkgs; [
      nix coreutils util-linux cryptsetup systemd sbsigntool gnugrep gawk releaseCblocks
      diffutils  # cmp — the signed-UKI vs ESP-UKI compare for the -prev rollback rotation
                 # (self-upgrading branch only; the pinned branch's compare lives inside
                 # nixboot's own maintainer instead, with its own diffutils dependency).
    ];
    text = ''
      # `nix copy` / `nix build` / `nix store gc` are `nix …` subcommands → they need the
      # nix-command experimental feature (+ flakes for the flakeAttr build path). Enable it
      # self-containedly instead of depending on the host nix.conf — a hot MAIN may not set it,
      # and the running daemon here didn't, so `nix copy` died with "nix-command is disabled"
      # right after the (now working) store unlock (FIELD-BACKLOG #6).
      export NIX_CONFIG="experimental-features = nix-command flakes"

      # ── inputs ─────────────────────────────────────────────────────────────
      # (defaults keep the script eval-safe when built for the demo, where these are null;
      #  real use is gated by `active`, whose assertions require a rescue source.)
      flake=${lib.escapeShellArg (if cfg.autoUpgrade.flake != null then cfg.autoUpgrade.flake else "")}
      attr=${lib.escapeShellArg (if cfg.rescue.flakeAttr != null then cfg.rescue.flakeAttr else "")}
      pinnedTop=${if cfg.rescue.toplevel != null then cfg.rescue.toplevel else "\"\""}
      dbkey=${lib.escapeShellArg "${pkiDb}/db.key"}
      dbcert=${lib.escapeShellArg "${pkiDb}/db.pem"}
      esp=/boot
      espuki="$esp/EFI/Linux/${rescueEspFileName}"
      # Persistent marker (hot mode: /nix IS the pool) — the toplevel we last installed.
      # SHARED by both branches below — a re-run after this migration lands, with rescueTop
      # unchanged, no-ops on the SAME marker regardless of which pipeline built the UKI already
      # on the ESP (see the CRITICAL note at the top of this file).
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

      # ── 2. put the rescue CLOSURE on the stick f2fs store ────────────────────
      # The stick = the disk backing /boot; its 2nd partition is the rescue store (LUKS→f2fs).
      espsrc=$(findmnt -no SOURCE "$esp")                       # the real /dev node (fstab may say by-label)
      stickdisk=$(lsblk -no PKNAME "$espsrc" | head -1)         # sdX / nvme0n1
      storepart="/dev/$(lsblk -rno NAME,PARTN "/dev/$stickdisk" | awk '$2==2{print $1}' | head -1)"
      [ -b "$storepart" ] || { echo "rescue-maintain: could not find the stick rescue-store partition (disk /dev/$stickdisk)" >&2; exit 1; }

      # TPM2-unlock (non-secret store, same posture as usb mode). The keyslot is a
      # systemd-tpm2 LUKS2 token — plain `cryptsetup open` cannot read it on NixOS
      # (no external token plugin path), so use systemd's own tool.
      if [ ! -e /dev/mapper/nixnas-rescue-store ]; then
        # headless=yes is LOAD-BEARING: without a TPM2 token enrolled, systemd-cryptsetup would
        # fall back to an INTERACTIVE passphrase prompt on a service with no stdin — which hangs
        # until TimeoutStartSec (observed: a full 30-min stall, 32.5K read, that never copies).
        # headless disables every interactive query, so an un-enrolled / PCR-mismatched store
        # FAILS FAST here with the actionable message below instead of silently wedging.
        ${sdCryptsetup} attach nixnas-rescue-store "$storepart" - tpm2-device=auto,headless=yes \
          || { echo "rescue-maintain: TPM2 attach failed — the rescue store has no usable TPM2 token. Enroll it (nixnas-enroll-tpm2, or systemd-cryptenroll --tpm2-device=auto on the store partition)." >&2; exit 1; }
      fi
      mkdir -p "$mnt/nix"
      # The SHARED f2fs options (modules/lib/f2fs-store-mount-opts.nix): a bare mount would
      # write the new closure UNCOMPRESSED and blow the stick budget.
      mount -o ${lib.escapeShellArg f2fsOpts} /dev/mapper/nixnas-rescue-store "$mnt/nix"
      # ── make room BEFORE the copy (reordered 2026-07-12) ───────────────────────
      # The old order (copy → rotate roots → GC) needed old-current + old-prev + the
      # WHOLE new closure on the stick at once. Across a nixpkgs world bump the three
      # closures are ~disjoint → ~3× closure size → ENOSPC on the ~5 GiB stick (unit
      # red from 2026-07-05's world until the 07-11 bump made it structural; a failed
      # copy also strands partial paths that compound the next run). Rotate + GC FIRST:
      #   • rescue-prev ← rescue-current (the one-step rollback becomes the outgoing
      #     rescue — exactly what it would be after success anyway; old-prev unroots),
      #   • GC sweeps old-prev + any stranded partials from failed runs,
      #   • THEN copy: peak = old-current + new (2 closures, not 3).
      # A mid-copy ENOSPC stays SAFE: the ESP UKI still pins the OLD toplevel and its
      # closure stays rooted via rescue-prev → the stick remains bootable; the marker
      # (below) only advances on full success, so the next tick retries. If even
      # old-current + new cannot fit, the unit fails LOUDLY — that is a real stick
      # sizing problem for a human, never something to solve by unrooting the only
      # bootable rescue.
      roots="$mnt/nix/var/nix/gcroots"; mkdir -p "$roots"
      if [ -L "$roots/rescue-current" ] && [ "$(readlink "$roots/rescue-current")" != "$rescueTop" ]; then
        # -T is LOAD-BEARING: these roots are ABSOLUTE /nix/store symlinks (chroot-store
        # semantics — on the stick they mean the stick's own store). A plain `mv` DEREFERENCES
        # an existing destination symlink; when its target happens to exist in the HUB's store,
        # mv sees a directory and tries to move INTO it → EROFS on the hub's read-only
        # /nix/store (field 2026-07-12; it only ever worked while prev's target was dangling
        # host-side). -T replaces the symlink OBJECT, mirroring the `ln -sfn` below.
        mv -fT "$roots/rescue-current" "$roots/rescue-prev"
      fi
      nix store gc --store "$mnt" || echo "rescue-maintain: pre-copy stick GC failed (non-fatal)" >&2
      # $mnt is a chroot store root: nix copy registers the closure into $mnt/nix/store.
      nix copy --no-check-sigs --to "$mnt" "$rescueTop"
      ln -sfn "$rescueTop" "$roots/rescue-current"
      # `nix copy --to $mnt` writes into a FOREIGN store from the MAIN's own daemon — no local
      # post-build-hook ever sees these paths, so without this the stick fills as if
      # compression were off (see modules/lib/f2fs-release-cblocks.nix). After the GC'd
      # copy, so the pass only touches what current+prev actually kept.
      nixnas-f2fs-release-cblocks "$mnt/nix/store" || echo "rescue-maintain: release pass failed (non-fatal)" >&2
      sync
      umount "$mnt/nix"
      ${sdCryptsetup} detach nixnas-rescue-store

      # ── 3. build + sign + place the rescue UKI on the ESP (keep one REAL rollback) ─
      # The closure is on the stick NOW (step 2 above already completed, or this line is
      # unreachable) — this is exactly the sequencing the SEQUENCING header note requires:
      # whichever branch below builds the UKI, the init= path it bakes in already exists on
      # the stick's store by the time the UKI can ever be selected at boot.
      ${lib.optionalString (cfg.rescue.toplevel != null) ''
        # PINNED: nixboot owns build+sign+place+rotate now. $rescueTop above IS
        # cfg.rescue.toplevel (the same derivation nixboot.extraEntries.${rescueEntryName}.toplevel
        # was declared with below) — there is no runtime choice left to make here, only to hand
        # off. nixboot's own maintainer re-derives the identical cmdline/signing/rotation shape
        # this file used to build inline (see modules/extra-entries.nix in the nixboot flake).
        ${lib.getExe config.system.build.extraEntryMaintainers.${rescueEntryName}}
      ''}
      ${lib.optionalString (cfg.rescue.flakeAttr != null) ''
        # SELF-UPGRADING: nixboot.extraEntries cannot serve this — its `toplevel` option is a
        # lib.types.package fixed at nixboot's OWN flake's eval time, and $rescueTop here was
        # just resolved at RUNTIME (above, from whatever autoUpgrade.flake currently points at).
        # See this file's header for why this branch stays on the original inline pipeline.
        cmdline="init=$rescueTop/init $(cat "$rescueTop/kernel-params")"
        uki="$work/${rescueEspFileName}"
        osrel=()   # cosmetic (menu title); only pass it if the toplevel exposes it
        [ -e "$rescueTop/etc/os-release" ] && osrel=(--os-release="@$rescueTop/etc/os-release")
        ${pkgs.systemdUkify}/bin/ukify build \
          --linux="$rescueTop/kernel" \
          --initrd="$rescueTop/initrd" \
          --cmdline="$cmdline" \
          "''${osrel[@]}" \
          --output="$uki"

        signed="$work/nixnas-rescue.signed.efi"
        sbsign --key "$dbkey" --cert "$dbcert" --output "$signed" "$uki"

        mkdir -p "$esp/EFI/Linux"
        # Rotate to -prev only when the installed UKI actually differs — a re-run after a lost
        # marker must not clobber the genuine previous version with an identical copy.
        if [ -f "$espuki" ] && ! cmp -s "$signed" "$espuki"; then
          cp -f "$espuki" "$esp/EFI/Linux/nixnas-rescue-prev.efi"
        fi
        install -m0644 "$signed" "$espuki.new"
        mv -f "$espuki.new" "$espuki"                             # rename = atomic on the same fs
        sync
      ''}

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

    # nixboot's extraEntries.rescue is declared ONLY when there is an eval-time-known toplevel
    # to give it (the pinned/hub-built persona) — see this file's header for why the
    # self-upgrading persona cannot be represented here at all. Kept OUTSIDE the `active` gate
    # below deliberately: like `maintain` above, this is plain option data (and the derivation
    # it produces, `system.build.extraEntryMaintainers.rescue`), not a running service, so CI
    # can build and shellcheck it on any host that sets rescue.toplevel regardless of whether
    # store.location is actually "hot" yet. `nixboot.enable` itself is deliberately never set
    # true here (see the SEQUENCING note at the top of this file) — this reads only the two
    # building blocks nixboot exposes unconditionally: the extraEntries option tree, and the
    # per-entry maintainer derivation.
    (lib.mkIf (cfg.rescue.toplevel != null) {
      nixboot.extraEntries.${rescueEntryName} = {
        toplevel = cfg.rescue.toplevel;
        espFileName = rescueEspFileName;
        sign = {
          enable = true;
          # The BUNDLE root, not `pkiDb` above (which already has /keys/db appended for this
          # file's own direct sbsign call in the self-upgrading branch) — nixboot's own
          # `sign.pkiBundle` appends /keys/db itself (modules/extra-entries.nix, `dbKeyDir`).
          pkiBundle = config.boot.lanzaboote.pkiBundle;
        };
        # Both explicit even though they are nixboot's own defaults: this is the exact
        # current/previous shape (`nixnas-rescue.efi` / `nixnas-rescue-prev.efi`) and the exact
        # "auto-discovery only, no firmware NVRAM entry" posture the original inline pipeline
        # had — stated here so the equivalence is legible in a diff, not merely inherited.
        rotate = true;
        bootEntry.enable = false;
      };
    })

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
      # ── equivalence checks (the migration to nixboot must not weaken any of these) ──
      {
        assertion = !(lib.hasPrefix "nixos-" rescueEspFileName) && lib.hasSuffix ".efi" rescueEspFileName;
        message = "nixnas rescue-maintain: the rescue ESP filename ('${rescueEspFileName}') must end in .efi and never start with \"nixos-\" — that prefix is what lanzaboote's own EFI/Linux GC (and stock systemd-boot's configurationLimit GC) key their generation cleanup on; colliding with it means the rescue UKI vanishes on the very next switch-to-configuration.";
      }
      {
        assertion = !(lib.elem "multi-user.target" config.systemd.services.nixnas-rescue-maintain.wantedBy);
        message = "nixnas rescue-maintain: nixnas-rescue-maintain.service must never be wantedBy multi-user.target — the stick copy is a multi-minute cross-store write, and making it a boot/switch dependency is the exact 30-minute-stall incident this module's header documents. It must stay timer-only.";
      }
      {
        assertion = config.systemd.timers.nixnas-rescue-maintain.wantedBy == [ "timers.target" ];
        message = "nixnas rescue-maintain: nixnas-rescue-maintain.timer must be wantedBy exactly [ \"timers.target\" ] — anything else changes when, or whether, the rescue self-heals.";
      }
    ];

    # ASYNC BY THE TIMER — the service is NEVER a synchronous dependency of any boot/switch
    # target. This is load-bearing: the maintainer does a multi-minute closure copy onto a slow
    # USB stick, and `wantedBy = multi-user.target` on a 30-min oneshot makes systemd BLOCK the
    # target on it — which stalls every boot AND every switch-to-configuration (a `start
    # multi-user.target` at the tail of the switch waits, holding the switch lock; observed
    # 2026-07-05: ~30-min boot stalls + repeated switch deadlocks). So it is driven ONLY by the
    # timer below (OnBootSec fires it a few minutes AFTER boot, off the critical path; a daily
    # tick catches drift). It is idempotent + no-ops when the rescue is unchanged, so the async
    # boot run still self-heals a pruned ESP entry — just without holding the boot hostage.
    # Deploy-triggered updates land on the next boot/daily tick instead of synchronously (the
    # rescue is a fallback; brief staleness is fine — the CURRENT stick UKI still boots).
    # UNCHANGED by the nixboot migration — proved above, not just asserted in prose.
    systemd.services.nixnas-rescue-maintain = {
      description = "Maintain the nixnas RESCUE system on the stick (closure + signed UKI)";
      # NO wantedBy multi-user.target — see the block comment above. after/wants only order it
      # WHEN the timer runs it; they do not pull it into the boot transaction.
      after = [ "local-fs.target" "boot.mount" ];
      wants = [ "boot.mount" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe maintain;
        # Building + signing + a cross-store copy over a slow stick: give it room. Off the
        # boot/switch path (timer-only), so this long timeout blocks nothing.
        TimeoutStartSec = "30min";
      };
    };

    # The ONLY trigger: a few minutes after boot (async ESP/stick self-heal, off the critical
    # path) + a daily catch-up (matters for the flake-built source; harmless no-op for pinned).
    systemd.timers.nixnas-rescue-maintain = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "1d";
        Persistent = true;
      };
    };

    # The maintainer is a handy manual command too (nixnas-rescue-maintain).
    environment.systemPackages = [ maintain ];
    })
  ];
}
