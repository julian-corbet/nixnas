# nixnas — the hub/TUI build library (pure functions; never run on the appliance node).
#
# These wrap the build → sign → seal → escrow → flash pipeline the TUI drives LOCALLY.
# The image is personalised (your config) AND signed with your own Secure Boot keys,
# so it cannot be pre-built generically or built on the k3s it will host — it is built
# on the machine running the TUI. See docs/DESIGN.md §5.
{ lib }:
{
  # Build the bootable USB image for an evaluated nixnas host. `host` is a
  # nixosSystem (e.g. `self.nixosConfigurations.<name>`) that imports the nixnas
  # module (disko on-stick layout in modules/boot/disk.nix).
  #
  # Returns disko's image builder: `diskoImages` (sandbox .raw) for a secret-free
  # demo; the TUI uses `diskoImagesScript` to inject the LUKS key at format time.
  mkImage = host: host.config.system.build.diskoImages;
}
