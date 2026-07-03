# nixnas — matrix variant: 16 GiB stick (mid-range, the most common off-the-shelf size).
#
# Proves the 16 GiB class evaluates and satisfies the budget arithmetic:
#
#   image = 16 GiB  |  ESP = 2 GiB  |  raw store = 14 GiB
#   zstd ~2.3× compression → effective store ≈ 32 GiB
#   keepGenerations = 8  |  budget = 3 GiB/gen → 24 GiB needed < 32 GiB effective
#
# The 2 GiB ESP is the HOT-MODE.md recommendation: it holds the main's kept UKIs +
# the rescue pair comfortably. `keepGenerations = 8` is the nixnas default; at a 3 GiB
# budget the stick carries a typical base+k3s+container-runtime host with margin.
{ lib, ... }:
{
  nixnas.boot.usb.imageSizeGiB = 16;
  nixnas.boot.usb.espSizeMiB   = 2048;
  nixnas.boot.keepGenerations  = 8;
  # lib.mkForce overrides the demo base's explicit `store.maxClosureBytes = 4 GiB`.
  # Budget: 3 GiB uncompressed / gen × 8 gens = 24 GiB needed.
  # Store: (16×1024 - 2048) MiB raw × 2.3 ≈ 32.9 GiB effective.  24 < 32.9 ✓
  nixnas.store.maxClosureBytes = lib.mkForce (3 * 1024 * 1024 * 1024);
}
