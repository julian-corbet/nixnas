# nixnas — grow the on-stick f2fs store to fill its partition (first-boot completion of a
# "grow-to-fill" flash).
#
# THE FLOW (see the TUI's flash pathway): a smaller/generic .raw is dd'd onto a bigger stick,
# then the TUI extends the LAST GPT partition (the LUKS store) to the true device end — but it
# does ONLY the secret-free part at flash time (partition geometry). It deliberately does NOT
# resize the LUKS mapping or the f2fs, because those need the store passphrase, which the flasher
# does not hold. This module finishes the job on the box, where the store is already unlocked.
#
# Why nothing else is needed here:
#   * LUKS2's default data segment is "dynamic" (spans to the end of its device), so the FRESH
#     stage-1 `cryptsetup open` of the already-grown partition maps the WHOLE grown partition —
#     no `cryptsetup resize` is required (we open, we don't resize a live mapping).
#   * Only the f2fs inside then lags: it was mkfs'd at the small image size. We grow it ONLINE
#     against the mounted /nix — the sound, low-risk path (the OS runs out of this fs; an offline
#     initrd resize of the live root store would be far riskier and needs delicate ordering).
#
# Idempotent: on an exact-fit image (or a re-boot) the fs already spans the mapper, so
# `resize.f2fs` reports "Nothing to resize" and the unit is a no-op.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
  # Stick-resident systems only (usb mode). In hot mode /nix is the operator's own device and
  # this is meaningless; disk.nix (which creates the f2fs store) is likewise usb-only.
  onUsb = cfg.enable && cfg.store.location == "usb";
  # The LUKS store mapper disko opens (modules/boot/disk.nix: the `nixos` partition's luks
  # `name = "cryptstore"`). This is the block device the f2fs store lives on.
  storeDev = "/dev/mapper/cryptstore";

  grow = pkgs.writeShellApplication {
    name = "nixnas-grow-store";
    runtimeInputs = [ pkgs.f2fs-tools pkgs.util-linux ];
    text = ''
      dev="${storeDev}"
      if [ ! -b "$dev" ]; then
        echo "nixnas-grow-store: $dev is not a block device — skipping"
        exit 0
      fi
      # Target = full size of the (flash-time-grown) LUKS mapper, in 512-byte sectors. The mapper
      # already spans the grown partition (dynamic LUKS2 segment on a fresh open — see the header).
      target="$(blockdev --getsz "$dev")"
      # Online grow of the MOUNTED f2fs store via the F2FS_IOC_RESIZE_FS ioctl. Passing an explicit
      # -t target is the reliable online trigger (resize.f2fs uses the ioctl on the mounted device);
      # it aligns the target down to a 2 MiB f2fs segment boundary itself and is a no-op once the fs
      # already spans the mapper — so this is safe to run on every boot.
      echo "nixnas-grow-store: online-resizing the f2fs store on $dev to $target sectors"
      resize.f2fs -t "$target" "$dev"
    '';
  };
in
{
  config = lib.mkIf (onUsb && cfg.boot.usb.growToFill) {
    systemd.services.nixnas-grow-store = {
      description = "Grow the f2fs store to fill its partition (first boot after a grow-to-fill flash)";
      # /nix is neededForBoot (stage-1) and appears as an active mount unit in stage-2; grow it
      # online once it is up. Require the mount so this never runs against a missing store.
      after = [ "nix.mount" ];
      requires = [ "nix.mount" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathIsMountPoint = "/nix";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe grow;
      };
    };
  };
}
