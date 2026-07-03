# nixnas — the store closure BUDGET (the 8 GiB-stick guard).
#
# The whole appliance premise is that the OS closure lives on a small USB stick (f2fs,
# multiple kept generations) AND is warmed into RAM by store.preload. Both costs are the
# SAME compressed closure, so ONE budget on the uncompressed closure bounds both. This
# module turns `nixnas.store.maxClosureBytes` into a build-time check that FAILS if the
# host toplevel closure exceeds it — so an accidental fat package (a dev toolchain, an
# agent) can never silently overflow the stick. Wire `system.build.storeClosureBudget`
# into the operator's flake `checks`.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;
in
{
  config = lib.mkIf (cfg.enable && cfg.store.maxClosureBytes != null) {
    system.build.storeClosureBudget =
      let
        closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
        budget = cfg.store.maxClosureBytes;
      in
      pkgs.runCommand "nixnas-store-closure-budget"
        {
          nativeBuildInputs = [ pkgs.coreutils ];
          # closureInfo pulls the whole closure in as an input, so its store paths are
          # realized here and `du` sees the real on-disk footprint.
          inherit closure;
        } ''
        # Sum the on-disk size of every path in the toplevel closure (conservative vs NAR).
        size=$(du -sb --files0-from=<(tr '\n' '\0' < "$closure/store-paths") | awk '{s+=$1} END{print s}')
        budget=${toString budget}
        mib() { echo $(( $1 / 1024 / 1024 )); }
        echo "nixnas host closure: $(mib "$size") MiB   budget: $(mib "$budget") MiB"
        if [ "$size" -gt "$budget" ]; then
          echo "" >&2
          echo "ERROR: the nixnas host closure ($(mib "$size") MiB) EXCEEDS the budget ($(mib "$budget") MiB)." >&2
          echo "The USB stick stores this per kept generation (compressed ~2.3x) and store.preload" >&2
          echo "warms it into RAM — so this bounds BOTH the 8 GiB stick fit and the preload RAM." >&2
          echo "Move heavy packages OFF the host OS: dev toolchains, agents, images and data belong" >&2
          echo "in build pods / containers on your pool. Keep the host = base + kernel + runtimes." >&2
          echo "Biggest paths in the closure:" >&2
          du -sb --files0-from=<(tr '\n' '\0' < "$closure/store-paths") \
            | sort -rn | head -15 | awk '{printf "  %6d MiB  %s\n", $1/1048576, $2}' >&2
          exit 1
        fi
        echo "OK: within the ${toString budget}-byte budget."
        touch "$out"
      '';
  };
}
