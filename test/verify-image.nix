# test/verify-image.nix — a DEV-only self-check baked into the demo image.
#
# On boot it prints, to the serial console, whether the f2fs store is actually
# zstd-compressed (so we confirm gen-1 compression instead of assuming it) and where
# the root + /nix are mounted. Included via the flake's demo modules during development;
# not part of the appliance.
{ pkgs, ... }:
{
  systemd.services.nixnas-verify = {
    description = "DEV: report f2fs compression + mounts on the serial console";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    path = [ pkgs.f2fs-tools pkgs.util-linux pkgs.findutils pkgs.coreutils ];
    script = ''
      echo "=== NIXNAS-VERIFY-START ==="
      echo "[mounts]"; mount | grep -E ' / |/nix' || true
      f="$(find /nix/store -maxdepth 4 -type f -name '*.so.*' 2>/dev/null | head -1)"
      echo "[sample] $f"
      if [ -n "$f" ]; then
        echo -n "[get_coption] "; f2fs_io get_coption "$f" 2>&1 || true
        echo -n "[get_cblocks] "; f2fs_io get_cblocks "$f" 2>&1 || true
      fi
      echo "=== NIXNAS-VERIFY-END ==="
    '';
  };
}
