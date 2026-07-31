# nixnas — early-boot geometry: the initrd kernel modules the disk layout needs.
#
# The loader STANCE (which program owns the ESP, Secure Boot, remote-unlock, generations +
# boot-counting, console ordering) moved to nixboot (`nixboot.*`, see ./nixboot.nix — this
# appliance's own bridge from `nixnas.boot.*` into nixboot's option surface). What stays HERE
# is the GEOMETRY nixboot explicitly disclaims owning: `boot.initrd.systemd.enable` (the initrd
# init system TPM2-LUKS unlock and lanzaboote both need — nixboot deliberately leaves this to
# whoever composes its own remote-unlock/LUKS wiring, see its own module header), the finding-the
# -USB-stick mechanism (`nixboot.media.usb.enable`, deliberately independent of `nixboot.enable`
# — see that option's own doc), and the kernel modules the initrd needs to see the operator's
# DATA POOLS before any root filesystem exists (`nixnas.boot.usb.*` geometry stays with the disk-
# layout tool that owns it — never boot's business, since a disk-layout tool's own numbers are
# not a mechanism any other host could reuse verbatim).
{ config, lib, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf cfg.enable {
    # systemd in the initrd — the supported path for the TPM2-LUKS unlock + lanzaboote.
    # DELIBERATELY NOT owned by nixboot (its own header: "boot.initrd.systemd.enable is
    # DELIBERATELY NOT ported here... if a host's own crypto/appliance config needs systemd in
    # the initrd, that host sets it itself, the same way it will declare its own LUKS members
    # itself" — this appliance is exactly that host).
    boot.initrd.systemd.enable = true;

    # Finding the USB boot stick itself is nixboot's mechanism (`nixboot.media.usb.enable`,
    # deliberately independent of `nixboot.enable` — nixnas never turns that on, see
    # ./nixboot.nix's own header): this asks for it rather than listing usb_storage/uas/
    # xhci_pci/ehci_pci here a second time.
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
