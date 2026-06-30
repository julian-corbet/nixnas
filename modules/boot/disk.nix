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
# keyfile would live INSIDE the encrypted store and so be unavailable at unlock time. The demo
# formats with the passphrase "nixnas-demo"; a real host's passphrase is supplied by the TUI at
# format time (and TPM2-PIN enrolment is a later increment). See docs/STORAGE.md §4, ARCHITECTURE §6.
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
                mountOptions = [ "umask=0077" ];
              };
            };
            nixos = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptstore";
                # Format-time passphrase (becomes the recovery keyslot; TPM2+PIN is enrolled
                # later on hardware). The operator's passphrase comes from the TUI via
                # `boot.usb.luksPassphraseFile`; null = the public demo passphrase. Either way
                # it is a store path so disko can read it inside the image-builder VM.
                passwordFile =
                  if cfg.boot.usb.luksPassphraseFile != null
                  then builtins.path { path = cfg.boot.usb.luksPassphraseFile; name = "nixnas-luks-pass"; }
                  else "${pkgs.writeText "nixnas-demo-luks" "nixnas-demo"}";
                content = {
                type = "filesystem";
                format = "f2fs";
                mountpoint = "/nix";
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
    };
  };
}
