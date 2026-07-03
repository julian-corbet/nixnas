# nixnas — matrix variant: 4 GiB stick (minimum practical size class).
#
# Proves the smallest common USB stick evaluates and satisfies the budget arithmetic:
#
#   image = 4 GiB  |  ESP = 512 MiB  |  raw store = 3584 MiB (3.5 GiB)
#   zstd ~2.3× compression → effective store ≈ 8 GiB
#   keepGenerations = 3  |  budget = 1 GiB/gen → 3 GiB needed << 8 GiB effective
#
# A 4 GiB stick is a rescue/appliance-only class: it comfortably holds 3 lean generations
# of a base nixnas closure (~600 MiB uncompressed each at the 1 GiB ceiling). k3s/heavy
# runtimes belong on the hot store, not this class.
#
# The 512 MiB ESP holds systemd-boot + 3 UKIs (× ~100 MiB = 300 MiB; fits with headroom
# for lanzaboote's signed boot bundle). Lower is possible but leaves no rollback margin.
{ lib, ... }:
{
  nixnas.boot.usb.imageSizeGiB = 4;
  nixnas.boot.usb.espSizeMiB   = 512;
  nixnas.boot.keepGenerations  = 3;
  # lib.mkForce overrides the demo base's explicit `store.maxClosureBytes = 4 GiB`.
  # Budget: 1 GiB uncompressed / gen × 3 gens = 3 GiB needed.
  # Store: (4×1024 - 512) MiB raw × 2.3 ≈ 8.2 GiB effective.  3 << 8.2 ✓
  nixnas.store.maxClosureBytes = lib.mkForce (1 * 1024 * 1024 * 1024);
}
