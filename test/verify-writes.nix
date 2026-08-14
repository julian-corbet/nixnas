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
  # Keep nixboot's production unit journal-only, but make its full readback visible in the
  # captured serial log of the demo VM. A failed boot-chain assertion must remain diagnosable
  # even when the failure itself prevents the harness from reaching stage-2 SSH.
  systemd.services.nixboot-verify.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };

  systemd.services.nixnas-verify-writes = {
    description = "DEV: prove the USB stick takes ~no writes during steady-state activity";
    wantedBy = [ "multi-user.target" ];
    # Run last, after the other DEV checks + first-boot writers (SB keys,
    # initrd-SSH host key seal) have settled, so we measure STEADY STATE, not the one-time
    # boot writes. Do NOT order this unit after multi-user.target while also pulling it into
    # that target: that is an ordering cycle, so PID 1 may discard an otherwise healthy boot
    # job to make the transaction runnable. Name the concrete readiness prerequisites instead.
    after = [
      "nixnas-verify.service"
      "nixboot-seal-hostkey.service"
      "nscd.service"
      "sshd.service"
      "systemd-user-sessions.service"
    ];
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

      # A systemd initrd can hand systemd-tmpfiles-setup's active oneshot state into stage 2
      # even though it ran against the initrd root. Prove the appliance's distinct stage-2 pass
      # populated the actual tmpfs root, systemd created its privileged wrappers, and PID 1 did
      # not resolve an ordering cycle by discarding either job.
      volatile_root_ok=1
      if [ -d /var/empty ] \
        && [ -L /var/run ] \
        && [ "$(readlink /var/run)" = "../run" ] \
        && [ "$(systemctl show --value -p Result suid-sgid-wrappers.service)" = "success" ] \
        && [ "$(systemctl show --value -p ExecMainCode suid-sgid-wrappers.service)" = "1" ] \
        && [ "$(systemctl show --value -p ExecMainStatus suid-sgid-wrappers.service)" = "0" ] \
        && [ -u /run/wrappers/bin/unix_chkpwd ] \
        && [ -x /run/wrappers/bin/unix_chkpwd ]; then
        echo "[tmpfiles] PASS — stage-2 /var is populated and unix_chkpwd is setuid+executable"
      else
        volatile_root_ok=0
        echo "[tmpfiles] FAIL — volatile root or privileged wrappers are incomplete"
        ls -ld /var /var/empty /var/run /run/wrappers/bin/unix_chkpwd 2>&1 || true
        systemctl status --no-pager -l systemd-tmpfiles-setup.service \
          nixnas-stage2-tmpfiles.service suid-sgid-wrappers.service || true
        journalctl -b --no-pager -u systemd-tmpfiles-setup.service \
          -u nixnas-stage2-tmpfiles.service -u suid-sgid-wrappers.service || true
      fi
      cycle_log="$(mktemp)"
      journalctl -b -o cat --no-pager > "$cycle_log"
      if grep -Fiq 'ordering cycle' "$cycle_log"; then
        volatile_root_ok=0
        echo "[ordering] FAIL — PID 1 discarded jobs to resolve a boot ordering cycle"
        grep -Fi 'ordering cycle' "$cycle_log" || true
      else
        echo "[ordering] PASS — no boot ordering cycle"
      fi
      rm -f "$cycle_log"

      sync; sleep 3
      t0=$(sw)
      # Burst: ~100 MiB that a naive system would dribble onto the stick — must land in RAM.
      dd if=/dev/zero of=/var/log/nixnas-writetest bs=1M count=50 2>/dev/null || true
      dd if=/dev/zero of=/tmp/nixnas-writetest     bs=1M count=50 2>/dev/null || true
      i=0; while [ $i -lt 3000 ]; do logger "nixnas-writetest $i ........................................"; i=$((i+1)); done
      sync; sleep 3
      t1=$(sw)
      rm -f /var/log/nixnas-writetest /tmp/nixnas-writetest

      # If some unrelated unit failed early enough to take SSH or console login down, the
      # outer harness cannot ask the guest for its journal. Leave a bounded diagnostic on the
      # captured serial console while we still have a root service inside the running system.
      failed_units="$(systemctl --failed --no-legend --plain | awk '{print $1}')"
      if [ -n "$failed_units" ]; then
        echo "[failed-units] systemctl reports: $(echo "$failed_units" | tr '\n' ' ')"
        for unit in $failed_units; do
          echo "--- journal tail: $unit ---"
          journalctl -b -u "$unit" --no-pager -n 40 || true
        done
      else
        echo "[failed-units] none"
      fi

      kib=$(( (t1 - t0) * 512 / 1024 ))
      echo "[result] stick wrote ''${kib} KiB while ~100 MiB of logs+files were generated"
      if [ "$kib" -lt 5120 ]; then
        echo "[verdict] PASS — the writes went to RAM; the stick is isolated"
      else
        echo "[verdict] FAIL — the stick absorbed ''${kib} KiB of steady-state writes"
        exit 1
      fi
      [ "$volatile_root_ok" -eq 1 ] || exit 1
      echo "=== NIXNAS-WRITES-END ==="
    '';
  };
}
