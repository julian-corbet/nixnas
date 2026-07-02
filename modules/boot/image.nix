# nixnas — boot chain glue (UEFI + initrd) on the disko-built image.
#
# The disk LAYOUT lives in ./disk.nix; this module is the boot-time wiring:
# systemd-boot (lanzaboote wraps its installer when Secure Boot is on — see
# ./secureboot.nix), the serial console, and the early kernel modules the initrd
# needs to see the USB stick + the f2fs store.
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    # UEFI boot. Removable image → never write EFI variables (the stick boots on any box).
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.grub.enable = false;

    # Short menu timeout: fast boot, but the generation menu (the guaranteed manual
    # rollback) stays reachable with a keypress.
    boot.loader.timeout = lib.mkDefault 1;

    # systemd in the initrd — the supported path for the TPM2-LUKS unlock + lanzaboote.
    boot.initrd.systemd.enable = true;

    # Serial console: headless boxes expose SOL/BMC serial on ttyS0, and it lets the
    # test VM be observed headlessly. ttyS0 is LAST so it becomes /dev/console.
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200"
    ];

    # The boot device + data-pool controllers the initrd must drive. A generic image
    # auto-detects none, so without these the USB stick (and the f2fs store) are invisible
    # to early userspace and boot hangs waiting for the root device.
    boot.initrd.availableKernelModules = [
      "usb_storage" "uas" "xhci_pci" "ehci_pci" # USB boot stick
      "ahci" "nvme" "sd_mod"                    # SATA / NVMe (data pools on real hardware)
      "virtio_blk" "virtio_pci" "virtio_scsi"   # VM testing
    ];
    # f2fs (+ its crc32 dep) must be in the initrd to mount the store.
    boot.initrd.kernelModules = [ "f2fs" "crc32" ];
  };
}
