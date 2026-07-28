# nixnas — boot chain glue (UEFI + initrd) on the disko-built image.
#
# The disk LAYOUT lives in ./disk.nix; this module is the boot-time wiring:
# systemd-boot (lanzaboote wraps its installer when Secure Boot is on — see
# ./secureboot.nix), the serial console, and the early kernel modules the initrd
# needs to see the USB stick + the f2fs store.
#
# BOOT IS NOT AN APPLIANCE CONCERN — the operator's decision, enacted here:
# the MECHANISM of booting from removable media (which kernel modules let the
# initrd even SEE a USB-attached device before any root filesystem exists)
# now lives in nixboot (`nixboot.media.usb.enable`, deliberately usable
# without adopting nixboot's whole boot-stance ownership — see that option's
# own doc). What stays HERE is the GEOMETRY of nixnas's own stick
# (`nixnas.boot.usb.*` in ../options.nix: device path, image/ESP size,
# partition count) — never boot's business, since a disk-layout tool's
# numbers are not a mechanism any other host could reuse verbatim.
#
# The loader STANCE below (never write EFI variables) answers the same
# "removable-vs-NVRAM entry" question nixboot's own `loader.efiVariables`
# option now generalizes — kept inline here rather than composed, for the
# same reason `./secureboot.nix` and `./remote-unlock.nix` still are:
# `nixboot.enable` pulls in a bundle of OTHER opinions (a required
# `loader.program`, `nixboot-verify`'s readback checks against nixboot's OWN
# option values, `secureBoot.sbctlCompat`'s unconditional `/etc/sbctl/
# sbctl.conf` write) that this appliance, which already owns its whole boot
# chain, would have to carefully neutralize rather than gain anything from
# (flake.nix's own nixboot input note explains the same boundary for
# secureBoot/remoteUnlock). A future full cutover is a deliberate, separate
# migration, not a side effect of this move.
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

    # Finding the USB boot stick itself is nixboot's mechanism now (see the header
    # note above): this asks for it rather than listing usb_storage/uas/xhci_pci/
    # ehci_pci here a second time. `nixboot.media.usb.enable` is independent of
    # `nixboot.enable` (nixnas never turns that on — see the header note), so this
    # is a real composition, not a hole where the mechanism used to be.
    nixboot.media.usb.enable = true;

    # The data-pool controllers the initrd must drive, once past the stick. A generic
    # image auto-detects none, so without these the f2fs store's OWN backing disk is
    # invisible to early userspace and boot hangs waiting for the root device.
    boot.initrd.availableKernelModules = [
      "ahci" "nvme" "sd_mod"                    # SATA / NVMe (data pools on real hardware)
      "virtio_blk" "virtio_pci" "virtio_scsi"   # VM testing
    ];
    # f2fs (+ its crc32 dep) must be in the initrd to mount the store.
    boot.initrd.kernelModules = [ "f2fs" "crc32" ];
  };
}
