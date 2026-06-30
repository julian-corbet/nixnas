# nixnas — the on-stick disk layout (disko).
#
# Two partitions, sized from `nixnas.boot.usb.*`:
#   ESP   (FAT)  — lanzaboote-signed systemd-boot + the signed UKIs
#   nixos (f2fs) — the NixOS store, zstd:22-compressed (gen-1 is written THROUGH this
#                  compressed mount by disko's installer, so it lands compressed).
#
# disko's image builder (`system.build.diskoImages`) partitions + mkfs + mounts +
# runs the installer in a throwaway VM, then drops the `.raw`. The store is the only
# device nixnas ever formats — the operator's data pools are import-only.
#
# INCREMENT 1: root is on f2fs directly (mountpoint "/") and the store is plaintext —
# enough to prove the disko-f2fs-zstd image boots. impermanence (tmpfs root + /nix)
# and LUKS are the next increments. See docs/STORAGE.md §4.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    disko.devices.disk.main = {
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
              mountOptions = [ "umask=0077" ];
            };
          };
          nixos = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "f2fs";
              mountpoint = "/";
              extraArgs = [ "-O" "extra_attr,inode_checksum,sb_checksum,compression" ];
              # The STORAGE.md §4 recipe: zstd:22, 16 KiB cluster, compress everything,
              # exclude the Nix sqlite DB, flash-friendly mount flags.
              mountOptions = [
                "compress_algorithm=zstd:22"
                "compress_log_size=2"
                "compress_extension=*"
                "compress_chksum"
                "nocompress_extension=sqlite"
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
}
