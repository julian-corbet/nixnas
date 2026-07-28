# nixnas — a hot-mode variant of the demo carrying a PINNED rescue toplevel, so CI actually
# builds `system.build.extraEntryMaintainers.rescue` (nixboot's own build+sign+place+rotate
# pipeline) end to end, from a real toplevel, and proves `nixnas-rescue-maintain` is wired to
# call it. See modules/appliance/rescue-maintain.nix's header for the pinned-vs-self-upgrading
# split this exercises only the PINNED half of.
#
# Deliberately NOT built on top of ./demo-hot.nix: that file sets `nixnas.rescue.enable = false`
# at plain priority, and this variant needs it true — two plain-priority definitions of the same
# option would be a straight eval conflict, not an override. Everything else here mirrors
# demo-hot.nix's own hot-mode wiring; `rescue.enable`/`rescue.toplevel` are set from flake.nix
# instead (rescue.toplevel needs `self`, which a plain host module does not receive).
{ pkgs, ... }:
{
  nixnas.store.location = "hot";
  nixnas.store.hot = {
    # A distinct mapper/partlabel from demo-hot.nix's own `nixstore-demo` — this is a SEPARATE
    # nixosConfiguration in the same CI matrix, and by-partlabel devices must stay unique across
    # the QEMU integration fixtures that could one day present both at once.
    device = "/dev/mapper/nixstore-demo-rescue";
    fsType = "ext4";
    unlock.nixstore-demo-rescue = "/dev/disk/by-partlabel/nixstore-demo-rescue";
  };

  # Hot mode enters the store key in the initrd — keep remote-unlock (initrd-SSH) on, same as
  # demo-hot.nix.
  nixnas.boot.remoteUnlock.enable = true;

  # rescue-maintain.nix asserts hot-mode rescue needs STABLE Secure Boot keys (never the
  # autogenerate/keyless path `hosts/demo` otherwise uses) — a real signing identity is what
  # makes the rescue UKI's signature meaningful across reflashes. DEMO ONLY, same explicit,
  # visible opt-in pattern as `hosts/demo`'s own `boot.usb.luksPassphraseFile`: a placeholder
  # path satisfying the type/assertion, never a real Secure Boot key. Real hosts supply this via
  # sops, materialised by the TUI onto the build machine — never checked into any Nix store path.
  nixnas.boot.secureBoot.keysSops = pkgs.writeText "demo-rescue-keysSops" "DEMO ONLY — not a real Secure Boot key";

  # rescue.enable defaults to true whenever store.location == "hot" (modules/options.nix) — set
  # explicitly anyway from flake.nix's own nixosConfigurations entry (alongside rescue.toplevel,
  # which needs `self` and so cannot be set from a plain host module like this one), purely so
  # the intent ("this variant exists to exercise the pinned-rescue path") is visible there.
}
