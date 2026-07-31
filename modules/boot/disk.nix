# nixnas — the on-stick disk layout (disko).
#
# Two partitions, sized from `nixnas.boot.usb.*`:
#   ESP   (FAT)  — lanzaboote-signed systemd-boot + the signed UKIs
#   nixos (f2fs) — the NixOS store, zstd:22-compressed (gen-1 is written THROUGH this
#                  compressed mount by disko's installer, so it lands compressed).
# Plus a tmpfs root (impermanence) declared as a disko `nodev` device, so the image
# builder has a "/" to install into and generates `fileSystems."/" = tmpfs` for runtime.
#
# disko's image builder (`system.build.diskoImages`) partitions + mkfs + mounts +
# runs the installer in a throwaway VM, then drops the `.raw`. The store is the only
# device nixnas ever formats — the operator's data pools are import-only.
#
# The store is LUKS2-encrypted (single passphrase = the future TPM2 PIN). `passwordFile`
# (not settings.keyFile) gives an INTERACTIVE runtime unlock prompt — correct here, because a
# keyfile would live INSIDE the encrypted store and so be unavailable at unlock time.
#
# PASSPHRASE DELIVERY (fail-closed): a real host leaves `boot.usb.luksPassphraseFile` at null,
# which resolves to the conventional in-VM path /tmp/nixnas-luks.key — the TUI injects the
# operator's passphrase there with `imageScript --pre-format-files`, so it never touches the
# Nix store. A build WITHOUT the injected file fails at `luksFormat` (no silent fallback).
# Only the public demo host opts into a store-path demo passphrase, explicitly.
# `nixfsCatalogue` is a plain closure argument, applied by modules/default.nix at import time
# (never `_module.args` — a module-argument name is a GLOBAL namespace shared with anything else
# composed alongside this one; nixvault's own, separately-pinned nixfs closes over the exact same
# argument name, which would collide the moment a consumer composed both flakes together. Partial
# application means this file's own `nixfsCatalogue` is baked in before the module system ever
# sees this as a module — it never enters `_module.args`, so there is nothing left to collide over.
{ nixfsCatalogue }:
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  # THE f2fs compression recipe -- ONE, canonical copy, owned by nixfs (the filesystem domain)
  # and consumed here as plain data, never vendored. See nixfs's lib/catalogue.nix
  # (filesystems.f2fs.compression) for the per-flag rationale; `nixfsCatalogue` reaches this
  # module as a plain, partially-applied argument (see the header above), not a config read,
  # because a recipe is a constant, not a per-host fact. SHARED with rescue-maintain (hot mode
  # re-mounts this store with the identical mount options) — one source, so the compression
  # config cannot drift.
  f2fsRecipe = nixfsCatalogue.filesystems.f2fs.compression;
in
{
  # The on-stick disko layout applies to STICK-RESIDENT systems only — `usb` mode (the
  # appliance itself) AND the `hot`-mode RESCUE (which is a minimal usb-mode nixnas). A
  # `hot`-mode MAIN config's /nix is the hot device (modules/store/location.nix), so it
  # gets NO stick image here. See docs/HOT-MODE.md.
  config = lib.mkIf (cfg.enable && cfg.store.location == "usb") {
    # The builder VM's RAM. disko's 1 GiB default OOM-hangs SILENTLY mid-build once the
    # closure copy starts (diagnosed from a real hung build's session log). 2 GiB is the
    # nixnas ceiling BY DESIGN — the image must be buildable on modest machines; if 2 GiB
    # ever proves insufficient, that is a builder bug to fix (write-through tuning), never
    # a reason to demand more host RAM. (`--build-memory` / build_memory_mib still override.)
    disko.memSize = lib.mkDefault 2048;

    # ── FIELD-BACKLOG #2: the store-unlock wait must be INFINITE ─────────────────────────
    # Field-proven lockout (first real deployment, 2026-07-04): a slow-POST server (~15
    # min) plus an unanswered LUKS prompt → after ~90 s the boot fell into emergency mode,
    # and on a fresh image the emergency shell is LOCKED (no root credential yet) — total
    # lockout, recovered only via the "press Enter → jobs retry → fresh prompt" trick.
    #
    # The REAL mechanism (verified by RUNNING systemd's own generators against these exact
    # crypttab/fstab shapes, not from docs alone):
    #   * systemd-cryptsetup@cryptstore.service itself NEVER times out — the crypttab
    #     generator emits `TimeoutSec=infinity` into the service, and the crypttab
    #     `timeout=` option (the password-query timeout) already defaults to "wait
    #     forever". Neither is the knob, neither is the problem.
    #   * The 90 s killers are DEVICE JOBS. Per systemd.unit(5), a device unit's
    #     JobRunningTimeoutSec falls back to DefaultDeviceTimeoutSec (90 s) INDEPENDENTLY
    #     of JobTimeoutSec — so although the cryptsetup generator pins
    #     `JobTimeoutSec=infinity` onto dev-mapper-cryptstore.device, the RUNNING job
    #     still dies at 90 s. Two victims:
    #       1. sysroot-nix.mount waits on dev-mapper-cryptstore.device, which only appears
    #          once the passphrase is entered. Prompt unanswered > 90 s → device job
    #          cancelled → mount failed → initrd-fs.target → emergency. (THE field lockout.)
    #       2. systemd-cryptsetup@cryptstore.service waits on the BACKING partition device
    #          (by-partlabel) — slow USB enumeration / slow controller init > 90 s kills
    #          it the same way before any prompt exists.
    #   * The knob that actually works is `x-systemd.device-timeout=0`:
    #       - on the /nix MOUNT options, the fstab generator turns it into a
    #         dev-mapper-cryptstore.device drop-in `JobRunningTimeoutSec=0` (infinite),
    #         fixing 1 (proven: 50-device-timeout.conf appears in the generator output);
    #       - on the CRYPTTAB entry, the cryptsetup generator emits the same drop-in for
    #         the backing device unit, fixing 2.
    #     Both flow into stage 1 verbatim: crypttabExtraOpts → the initrd /etc/crypttab
    #     (nixpkgs luksroot.nix), fileSystems options → the initrd sysroot fstab
    #     (nixpkgs filesystems.nix marks neededForBoot mounts x-initrd.mount and hands
    #     the real fstab-generator SYSTEMD_SYSROOT_FSTAB).
    #
    # Waiting IS the correct behavior: without /nix the box is useless, and a human
    # arriving minutes later must find the prompt, not a locked emergency shell. (A global
    # initrd DefaultDeviceTimeoutSec=infinity was considered and rejected — it would also
    # mask genuinely broken device dependencies everywhere, not just the unlock path.)
    boot.initrd.luks.devices.cryptstore.crypttabExtraOpts = [ "x-systemd.device-timeout=0" ];
    fileSystems."/nix".options = [ "x-systemd.device-timeout=0" ];

    disko.devices = {
      # Impermanence: root is tmpfs. As a disko `nodev` device it is mounted at the
      # install rootMountPoint (so the installer has a "/") and becomes fileSystems."/".
      nodev."/" = {
        fsType = "tmpfs";
        mountOptions = [ "size=50%" "mode=0755" ];
      };

      disk.main = {
        type = "disk";
        device = cfg.boot.usb.device;
        imageName = "nixnas";
        # Byte-precise `imageSize` (from the TUI's exact-fit build) wins over the whole-GiB value;
        # a raw byte count is what qemu-img create wants for an exactly device-sized `.raw`.
        imageSize =
          if cfg.boot.usb.imageSize != null
          then cfg.boot.usb.imageSize
          else "${toString cfg.boot.usb.imageSizeGiB}G";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              # Meaningful GPT partition label (else disko auto-names it `disk-main-ESP`).
              label = "boot";
              size = "${toString cfg.boot.usb.espSizeMiB}M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                # Label the ESP so hot-mode MAIN systems can mount it by-label (they share this
                # stick's ESP with the rescue; disk.nix doesn't run for them). See location.nix.
                extraArgs = [ "-n" "ESP" ];
                mountOptions = [ "umask=0077" "noatime" ];
              };
            };
            nixos = {
              # The store partition's GPT label (else disko auto-names it `disk-main-nixos`).
              # Load-bearing: crypto/{tpm2,recovery-escrow}.nix find the store by this partlabel,
              # and disko wires the initrd LUKS unlock by-partlabel too — so a stick's label must
              # match the image it was built from (rename ⇒ rebuild+reflash, never in place).
              label = "nixnas";
              size = "100%";
              content = {
                type = "luks";
                name = "cryptstore";
                # Format-time passphrase (becomes the recovery keyslot; TPM2+PIN is enrolled
                # later on hardware). The path is read INSIDE the image-builder VM: the TUI
                # places the real passphrase at the conventional path via
                # `--pre-format-files`; a build without it FAILS (fail-closed). The demo host
                # sets an explicit store-path demo passphrase instead.
                passwordFile =
                  if cfg.boot.usb.luksPassphraseFile != null
                  then cfg.boot.usb.luksPassphraseFile
                  else "/tmp/nixnas-luks.key";
                content = {
                type = "filesystem";
                format = "f2fs";
                mountpoint = "/nix";
                # zstd:22, 16 KiB cluster, compress everything, exclude the Nix sqlite DB, plus
                # the flash-friendly + RAM-cache flags -- the full per-flag rationale (incl. the
                # 8-char F2FS_EXTENSION_LEN trap that caps the sqlite exclusion to the main DB
                # file only) now lives at the recipe's own home, nixfs's lib/catalogue.nix
                # (filesystems.f2fs.compression) -- see STORAGE.md §4 / OPTIMIZATIONS.md §3 for
                # this appliance's own account of why each flag earns its place.
                extraArgs = [ "-O" f2fsRecipe.mkfsFeatures ];
                mountOptions = f2fsRecipe.mountOptions;
                };
              };
            };
          };
        };
      };
    };

    # f2fs compression's fs-mode never frees the blocks it reserves for a compressed file —
    # that needs an explicit per-file release (modules/lib/f2fs-release-cblocks.nix). gen-1 is
    # populated by nixos-install via copy/substitution, not a local build of the closure it
    # installs, so the ongoing post-build-hook (optimizations.nix) never sees it — the image
    # needs its own explicit pass. Run it ASYNC via a timer, NEVER on the boot-critical path: a
    # full-store sweep that forks a release ioctl per file must not block `nixos-activation` —
    # wired as an activationScript it hung the boot indefinitely ("A start job is running for
    # NixOS Activation … / no limit"; the ioctl runs against the very binaries mmapped from that
    # store), which was the boot-test regressor. OnBootSec fires it a few minutes AFTER boot (off
    # the critical path, so activation → multi-user → sshd come up normally); a daily tick catches
    # later gens. Idempotent: an already-released file's ioctl is a cheap no-op. Confirmed
    # load-bearing on a real deployment (2026-07-04): a store that never ran this pass stayed at
    # its pre-compression size (55% used; 40% after one manual pass). Same async pattern as
    # rescue-maintain (the first instance of this defect class fixed).
    systemd.services.nixnas-f2fs-release-cblocks = {
      description = "f2fs compression release pass over the on-stick /nix/store (density reclaim)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${import ../lib/f2fs-release-cblocks.nix { inherit pkgs; }}/bin/nixnas-f2fs-release-cblocks /nix/store";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.nixnas-f2fs-release-cblocks = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "3min"; OnCalendar = "daily"; Persistent = true; };
    };
  };
}
