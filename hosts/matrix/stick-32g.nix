# nixnas — matrix variant: 32 GiB stick (upper bound; HOT-MODE.md caps usage at 32 GiB
# regardless of physical stick size — a 1 TB stick still gets imageSizeGiB = 32).
#
# Proves the 32 GiB class evaluates and satisfies the budget arithmetic:
#
#   image = 32 GiB  |  ESP = 2 GiB  |  raw store = 30 GiB
#   zstd ~2.3× compression → effective store ≈ 69 GiB
#   keepGenerations = 8  |  budget = 5 GiB/gen → 40 GiB needed < 69 GiB effective
#
# At a 5 GiB budget the stick can carry a hub-class host (base + k3s + GPU userland
# without the model weights — those live on the data pool). The cap at 32 GiB is a
# deliberate discipline: anything heavier belongs in pods on the hot store, not the OS.
{ lib, ... }:
{
  nixnas.boot.usb.imageSizeGiB = 32;
  nixnas.boot.usb.espSizeMiB   = 2048;
  nixnas.boot.keepGenerations  = 8;
  # lib.mkForce overrides the demo base's explicit `store.maxClosureBytes = 4 GiB`.
  # Budget: 5 GiB uncompressed / gen × 8 gens = 40 GiB needed.
  # Store: (32×1024 - 2048) MiB raw × 2.3 ≈ 69 GiB effective.  40 < 69 ✓
  nixnas.store.maxClosureBytes = lib.mkForce (5 * 1024 * 1024 * 1024);
}
