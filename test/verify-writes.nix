# test/verify-writes.nix — a DEV-only self-check: PROVE the USB stick is write-isolated.
#
# Cheap USB sticks have no SSD-grade flash management: a steady write stream wears them out
# in ~a year and they go slow / drop. nixnas's whole point is that, except for updates (new
# generations) and opt-in emergency logs, the stick takes ~NO writes — logs, /tmp, coredumps
# and swap all live in RAM. This test makes that measurable instead of assumed: it generates
# ~100 MiB of logs + files and confirms the stick block device barely moves.
#
# Method: read sectors-written from /sys/block/vda/stat (vda = the stick in the test VM; the
# LUKS f2fs store + ESP are its partitions), generate a burst that WOULD wear a stick if any
# of it were misrouted there, and assert the device delta stays tiny (it all went to RAM).
{ pkgs, ... }:
{
  systemd.services.nixnas-verify-writes = {
    description = "DEV: prove the USB stick takes ~no writes during steady-state activity";
    wantedBy = [ "multi-user.target" ];
    # Run last, after the other DEV checks + first-boot writers (SB keys, TPM enroll,
    # initrd-SSH host key seal) have settled, so we measure STEADY STATE, not the one-time
    # boot writes.
    after = [ "multi-user.target" "nixnas-verify.service" "nixnas-verify-tpm2.service"
              "nixnas-seal-hostkey.service" ];
    path = [ pkgs.coreutils pkgs.util-linux pkgs.systemd pkgs.gawk ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      dev=vda
      statf=/sys/block/$dev/stat
      sw() { awk '{print $7}' "$statf"; }   # field 7 = sectors written (x512 B)
      echo "=== NIXNAS-WRITES-START ==="
      echo "[/var/log] $(findmnt -no SOURCE,FSTYPE /var/log 2>/dev/null || echo 'on the tmpfs root (RAM)')"
      echo "[/tmp]     $(findmnt -no SOURCE,FSTYPE /tmp 2>/dev/null || echo 'on the tmpfs root (RAM)')"
      echo "[journald] $(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '/^Storage=/{print $2}' | tail -1)"
      echo "[swap]     $(swapon --noheadings --show=NAME,TYPE 2>/dev/null | tr -s ' ' | paste -sd, - || echo none) (zram is RAM, not the stick)"

      sync; sleep 3
      t0=$(sw)
      # Burst: ~100 MiB that a naive system would dribble onto the stick — must land in RAM.
      dd if=/dev/zero of=/var/log/nixnas-writetest bs=1M count=50 2>/dev/null || true
      dd if=/dev/zero of=/tmp/nixnas-writetest     bs=1M count=50 2>/dev/null || true
      i=0; while [ $i -lt 3000 ]; do logger "nixnas-writetest $i ........................................"; i=$((i+1)); done
      sync; sleep 3
      t1=$(sw)
      rm -f /var/log/nixnas-writetest /tmp/nixnas-writetest

      kib=$(( (t1 - t0) * 512 / 1024 ))
      echo "[result] stick wrote ''${kib} KiB while ~100 MiB of logs+files were generated"
      if [ "$kib" -lt 5120 ]; then
        echo "[verdict] PASS — the writes went to RAM; the stick is isolated"
      else
        echo "[verdict] FAIL — the stick absorbed ''${kib} KiB of steady-state writes"
      fi
      echo "=== NIXNAS-WRITES-END ==="
    '';
  };
}
