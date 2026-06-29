# nixnas — the hub/TUI build library (pure functions; never run on the appliance node).
#
# These wrap the build → sign → seal → escrow → flash pipeline the TUI drives LOCALLY.
# The image is personalised (your config) AND signed with your own Secure Boot keys,
# so it cannot be pre-built generically or built on the k3s it will host — it is built
# on the machine running the TUI. See docs/DESIGN.md §5.
{ lib }:
{
  # Build the bootable USB image (the `.raw`) for an evaluated nixnas host.
  # `host` is a nixosSystem (e.g. `self.nixosConfigurations.<name>`), which must
  # include `modules/boot/image.nix` (nix-native `image.repart`, not mkosi).
  #
  # TODO(boot-chain): today this is the entry point; it returns the signed,
  # verity-protected, A/B image once modules/boot/image.nix is wired in.
  mkImage = host: host.config.system.build.image;
}
