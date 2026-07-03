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
  config = lib.mkIf cfg.enable {
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
        imageSize = "${toString cfg.boot.usb.imageSizeGiB}G";
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
                mountOptions = [
                  "compress_algorithm=zstd:22"
                  "compress_log_size=2"
                  "compress_extension=*"
                  "compress_chksum"
                  "nocompress_extension=sqlite"
                  "flush_merge"
                  "checkpoint_merge"
                  "compress_cache"
                  "fsync_mode=nobarrier"
                  "noatime"
                  "lazytime"
                  "nodiscard"
                ];
                };
              };
            };
          };
        };
      };
    };
  };
}
