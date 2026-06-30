# nixnas — boot chain glue (UEFI + initrd) on the disko-built image.
#
# The disk LAYOUT lives in ./disk.nix; this module is the boot-time wiring:
# systemd-boot (lanzaboote wraps it once Secure Boot lands), the serial console,
# and the early kernel modules the initrd needs to see the USB stick + f2fs store.
#
# INCREMENT 1: plain systemd-boot on a removable image, root on f2fs (no LUKS / no
# lanzaboote / no TPM2 yet) — goal is simply to BOOT the disko-f2fs-zstd image in the
# test VM. Secure Boot signing, the LUKS+TPM2 unlock, impermanence and the CachyOS
# kernel are layered in next, each validated in the VM.
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

    # systemd in the initrd — the supported path for the coming TPM2-LUKS unlock + lanzaboote.
    boot.initrd.systemd.enable = true;

    # Serial console: the MC12-LE0 exposes SOL on ttyS0; it also lets the test VM be
    # observed headlessly. ttyS0 is LAST so it becomes /dev/console.
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
