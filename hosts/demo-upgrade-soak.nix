# hosts/demo-upgrade-soak.nix — soak configuration for test/upgrade-soak-test.sh.
#
# Extends hosts/demo (imported in the flake alongside this file) with:
#   * keepGenerations = 3  — the pruning window N=5 cycles crosses. Cycles 1-2 fill
#                            the window (1 UKI → 2 → 3). Cycles 3-5 hold it at 3,
#                            proving lzbt evicts the oldest UKI each time. This is
#                            the structurally interesting half of the soak — a simple
#                            accumulation test (keepGenerations ≥ N) would never exercise
#                            the configurationLimit GC path.
#   * 5 specialisations    — trivially-varied toplevels (one text file differs each).
#                            The test runner pre-builds the parent toplevel (which carries
#                            the specialisations in its closure) and copies them into the
#                            VM over SSH. No in-VM evaluation or network access required.
#
# NOT a bootable machine.  The flake's nixosConfigurations.demo-upgrade-soak is a TOPLEVEL
# SOURCE only — the test extracts the soak-gen-2..6 store paths from its specialisation/
# directory and installs them one per cycle with nix-env + switch-to-configuration boot.
#
# Specialisation numbering matches the NixOS PROFILE GENERATION number the test installs
# each one as:
#   initial boot (demo image)  → profile gen 1  (no marker file)
#   cycle 1 → soak-gen-2      → profile gen 2  (/etc/nixnas-soak-gen = "2")
#   cycle 2 → soak-gen-3      → profile gen 3  (/etc/nixnas-soak-gen = "3")
#   …
#   cycle 5 → soak-gen-6      → profile gen 6  (/etc/nixnas-soak-gen = "6")
{ ... }:
{
  nixnas.boot.keepGenerations = 3;

  specialisation = {
    soak-gen-2.configuration.environment.etc."nixnas-soak-gen".text = "2";
    soak-gen-3.configuration.environment.etc."nixnas-soak-gen".text = "3";
    soak-gen-4.configuration.environment.etc."nixnas-soak-gen".text = "4";
    soak-gen-5.configuration.environment.etc."nixnas-soak-gen".text = "5";
    soak-gen-6.configuration.environment.etc."nixnas-soak-gen".text = "6";
  };
}
