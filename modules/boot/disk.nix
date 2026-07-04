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
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
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
              size = "${toString cfg.boot.usb.espSizeMiB}M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                # Label the ESP so hot-mode MAIN systems can mount it by-label (they share this
                # stick's ESP with the rescue; disk.nix doesn't run for them). See location.nix.
                extraArgs = [ "-n" "NIXNAS-ESP" ];
                mountOptions = [ "umask=0077" "noatime" ];
              };
            };
            nixos = {
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
                extraArgs = [ "-O" "extra_attr,inode_checksum,sb_checksum,compression" ];
                # The STORAGE.md §4 recipe: zstd:22, 16 KiB cluster, compress everything,
                # exclude the Nix sqlite DB, plus the flash-friendly + RAM-cache flags
                # (OPTIMIZATIONS.md §3):
                #   flush_merge/checkpoint_merge — coalesce flushes/checkpoints on slow flash
                #   compress_cache               — cache COMPRESSED blocks in RAM (the
                #                                  "compressed page cache" the preload warms)
                #   fsync_mode=nobarrier         — fewer barriers for non-atomic files; safe
                #                                  here because store paths are re-fetchable
                #                                  (NEVER the bare `nobarrier` mount option)
                # NOTE: f2fs extension names are capped at 8 chars (F2FS_EXTENSION_LEN), so
                # `sqlite-wal`/`sqlite-shm` (10 chars) CANNOT be excluded — f2fs rejects the
                # whole mount ("invalid extension length"). Only `sqlite` (the main DB) is
                # excludable; the WAL/SHM sidecars live in /nix/var (never the store-scoped
                # release pass) and fs-mode compression handles their in-place rewrites fine.
                # The list is SHARED with rescue-maintain (hot mode re-mounts this store) —
                # one source so the compression config cannot drift.
                mountOptions = import ../lib/f2fs-store-mount-opts.nix;
                };
              };
            };
          };
        };
      };
    };
  };
}
