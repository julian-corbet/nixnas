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

    # Menu timeout: long enough for a HUMAN to react and reach the generation menu (the
    # guaranteed manual rollback). A 1 s flash is unusable — might as well not show it.
    boot.loader.timeout = lib.mkDefault 5;

    # systemd in the initrd — the supported path for the TPM2-LUKS unlock + lanzaboote.
    boot.initrd.systemd.enable = true;

    # Console policy: BOTH consoles are ALWAYS on the command line — kernel messages
    # reach the attached display AND ttyS0, a getty runs on both, and systemd's
    # password agent prompts (and reads input) on both. `nixnas.boot.consolePrimary`
    # only decides which one is LAST — i.e. /dev/console, where systemd's boot status
    # stream and the emergency shell land.
    #
    #   "video" (the default): tty0 last. First boot asks for the store passphrase ON
    #     THE MONITOR — the right default for a human at the machine with a monitor +
    #     keyboard. (The old serial-primary default effectively demanded IPMI/SOL for
    #     the first boot — the prompt was easy to miss on the attached display; a
    #     real-world trap, since first boot can never use initrd-SSH: the TPM-sealed
    #     host key does not exist yet.)
    #   "serial": ttyS0 last. For genuinely headless SOL/BMC-administered boxes, and
    #     for the QEMU CI suite, which observes the VM only through the serial port.
    #
    # INVARIANT: reorder, never drop. Removing console=ttyS0 would silence the serial
    # LUKS prompt and the serial getty everywhere — headless boxes and the entire CI
    # suite at once. Keep 115200 (the SOL/BMC and QEMU default rate).
    boot.kernelParams =
      if cfg.boot.consolePrimary == "serial" then [
        "console=tty0"
        "console=ttyS0,115200"
      ] else [
        "console=ttyS0,115200"
        "console=tty0"
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
