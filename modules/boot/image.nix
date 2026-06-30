# nixnas — bootable USB image (nix-native, built on nixpkgs' image.repart verityStore).
#
# The nix store lives in a dm-verity-protected /usr partition; nixpkgs builds a UKI
# that carries the verity roothash (`usrhash=…`) in its cmdline, and the systemd
# initrd sets up dm-verity and mounts /usr. We add, in later iterations: SecureBoot
# signing of that UKI, copytoram (RAM-load the store), and A/B slots + boot-counting.
# See docs/DESIGN.md §2.
#
# STATUS: v0 — goal is simply to BOOT a verity image in a QEMU/OVMF VM. Iterated via
# the build(cluster) + boot(VM) loop. copytoram / SecureBoot / A-B are TODO.
{ config, lib, modulesPath, ... }:
let
  cfg = config.nixnas;
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  config = lib.mkIf cfg.enable {
    boot.loader.grub.enable = false;
    boot.initrd.systemd.enable = true; # required for the dm-verity setup generator

    # Serial console (the MC12-LE0 has SOL on ttyS0; also lets a test VM be observed).
    # ttyS0 is the LAST console= so it becomes /dev/console (systemd writes there).
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200"
    ];

    # The boot device + data-pool controllers the initrd must drive. A generic image
    # auto-detects none, so the USB boot stick (and SATA/NVMe data pools) are invisible
    # to early userspace — and the dm-verity /usr partition never appears → boot hangs.
    boot.initrd.availableKernelModules = [
      "usb_storage" "uas" "xhci_pci" "ehci_pci" # USB boot stick
      "ahci" "nvme" "sd_mod"                    # SATA / NVMe (data pools on real hardware)
      "virtio_blk" "virtio_pci" "virtio_scsi"   # VM testing
    ];

    # RAM-root: / is tmpfs; the immutable store comes from the verity-protected /usr.
    fileSystems."/" = lib.mkDefault {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=2G" ];
    };

    image.repart = {
      name = "nixnas";
      verityStore = {
        enable = true;
        # v0: boot the UKI directly via the removable-media fallback path, so UEFI
        # runs it with no bootloader. systemd-boot + A/B boot-counting come later.
        ukiPath = "/EFI/BOOT/BOOTX64.EFI";
      };
      partitions = {
        "00-esp".repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "ESP";
          SizeMinBytes = "256M";
          SizeMaxBytes = "256M";
        };
        # 10-store-verity (hash) + 20-store (erofs /usr) are provided by verityStore.
      };
    };
  };
}
