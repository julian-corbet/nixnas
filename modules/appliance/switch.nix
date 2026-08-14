# nixnas — `nixnas-switch`: detached, session-immune system activation.
#
# A `switch-to-configuration switch` carried by an SSH session can be killed
# mid-flight when activation changes that same session's network or login
# dependencies. This wrapper detaches the work from the transport.
#
# OWNERSHIP STATUS: this is the current functional activation wrapper.
# Activation, rollback, health and their typed outcomes now belong to
# nixdeploy, so this wrapper is marked for migration rather than a second
# permanent delivery mechanism:
#
#   nixnas-switch [switch|boot|test] [--generation <store-path>]
#
#   * the real `switch-to-configuration <mode>` runs DETACHED in a transient unit
#     (`systemd-run --no-block --collect`), owned by PID 1 — losing the SSH session
#     cannot interrupt activation. `--no-block` matters: for Type=oneshot a plain
#     systemd-run BLOCKS the client until the unit finishes (measured), which would
#     re-couple the switch to the droppable session;
#   * the wrapper then follows the unit's journal and reports the HONEST outcome: an
#     ExecStopPost hook captures $SERVICE_RESULT/$EXIT_STATUS to /run/nixnas/…,
#     because after `--collect` garbage-collects the finished unit, `systemctl show`
#     can lose the failed unit's result after collection;
#   * a second invocation while any nixnas-switch-* unit is loaded REFUSES (two
#     activations cannot overlap); the check-then-start race is closed by systemd-run
#     itself, which refuses an already-loaded unit name;
#   * stale-lock hygiene: switch-to-configuration-ng
#     serialises on flock(2) of /run/nixos/switch-to-configuration.lock and exits
#     with the raw errno on contention — EAGAIN, "Could not acquire lock", exit 11.
#     A killed switch can leave that fd inherited by an orphaned child, so every
#     retry dies with exit 11 although no switch is running. Deleting the lock FILE
#     unblocks retries (stc re-creates it, a fresh inode — the orphan's flock stays
#     on the old, unlinked one). The wrapper deletes it ONLY when the lock is
#     actually held AND no switch-to-configuration process is alive.
#
# Ships on BOTH store locations (usb and hot) — every nixnas is switched the same way.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;

  # The unit's ExecStopPost result capture, as a real script file rather than an
  # inline `/bin/sh -c '...'`. The inline form had to survive THREE escaping layers
  # in a row -- Nix string, bash double-quote processing inside the wrapper, then
  # systemd's own Exec-line parsing -- and it did not: `\$\$SERVICE_RESULT` reached
  # bash as an unescaped `$$`, which bash expanded to the WRAPPER'S OWN PID. Every
  # run therefore wrote a literal "<pid>SERVICE_RESULT <pid>EXIT_STATUS" into the
  # result file, never matched "success", and the tool reported FAILED and exited
  # non-zero after a switch that had in fact completed. The separate script
  # avoids that quoting ambiguity.
  #
  # That is the exact inverse of the failure mode this tool exists to prevent.
  # A separate
  # script has no nested quoting left to get wrong -- systemd sets SERVICE_RESULT and
  # EXIT_STATUS in the ExecStopPost environment, and this reads them straight out of it.
  resultCapture = pkgs.writeShellScript "nixnas-switch-capture-result" ''
    printf '%s %s\n' "''${SERVICE_RESULT:-unknown}" "''${EXIT_STATUS:-0}" > "$1"
  '';

  switchTool = pkgs.writeShellApplication {
    name = "nixnas-switch";
    runtimeInputs = with pkgs; [
      systemd # systemd-run, systemctl, journalctl
      coreutils # id, readlink, date, cat, mkdir, rm, sleep
      util-linux # flock — probes the SAME flock(2) switch-to-configuration-ng takes
      procps # pgrep — liveness check before cleaning the lock
      psmisc # fuser — reports who holds the orphaned lock fd
    ];
    text = ''
      # ── arguments ──────────────────────────────────────────────────────────
      mode=""; target=""
      usage() {
        echo "usage: nixnas-switch [switch|boot|test] [--generation <store-path>]" >&2
        echo "  switch        activate now AND make it the boot default (default mode)" >&2
        echo "  boot          only make it the boot default (activates on next reboot)" >&2
        echo "  test          activate now; do not touch the bootloader" >&2
        echo "  --generation  a system toplevel (or profile/generation link) to activate;" >&2
        echo "                default: the system profile /nix/var/nix/profiles/system" >&2
        exit 2
      }
      while [ $# -gt 0 ]; do case "$1" in
        switch|boot|test) mode="$1" ;;
        --generation) [ $# -ge 2 ] || usage; target="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
      esac; shift; done
      mode="''${mode:-switch}"
      [ "$(id -u)" = 0 ] || { echo "nixnas-switch: must run as root" >&2; exit 1; }

      # ── resolve the target toplevel ────────────────────────────────────────
      [ -n "$target" ] || target=/nix/var/nix/profiles/system
      resolved="$(readlink -f -- "$target")" || { echo "!! cannot resolve $target" >&2; exit 1; }
      case "$resolved" in
        /nix/store/*) ;;
        *) echo "!! $target resolves to $resolved — not a /nix/store system toplevel" >&2; exit 1 ;;
      esac
      stc="$resolved/bin/switch-to-configuration"
      [ -x "$stc" ] || { echo "!! $resolved is not a system toplevel (no bin/switch-to-configuration)" >&2; exit 1; }

      unit="nixnas-switch-$mode"
      resfile="/run/nixnas/switch-$mode.result"

      # ── refuse while any nixnas-switch is in flight (unit-exists check) ────
      # Activations must not overlap (they would also collide on the stc lock below).
      # A finished unit is --collect'ed away, so "loaded" means: genuinely running.
      for m in switch boot test; do
        if [ "$(systemctl show -p LoadState --value "nixnas-switch-$m.service")" = "loaded" ]; then
          echo "!! refusing: nixnas-switch-$m.service is already running — activations must not overlap." >&2
          echo "   follow it:   journalctl -fu nixnas-switch-$m" >&2
          echo "   its result:  cat /run/nixnas/switch-$m.result   (written when it finishes)" >&2
          exit 1
        fi
      done

      # ── stale-lock hygiene (the exit-11 field bug) ─────────────────────────
      # stc serialises on flock(2) of this file and exits 11 (EAGAIN) on contention.
      # `flock -n` probes the very same lock. If it is held but NO switch process is
      # alive, the holder is an orphaned inherited fd from a killed switch: deleting
      # the FILE unblocks the retry (stc re-creates it — a fresh inode the orphan's
      # flock does not cover). If a switch process IS alive, never touch it.
      lock=/run/nixos/switch-to-configuration.lock
      if [ -e "$lock" ] && ! flock --nonblock "$lock" true; then
        if pgrep -af 'bin/switch-to-configuration' >&2; then
          echo "!! refusing: the activation lock is held and a switch-to-configuration process is alive (above)." >&2
          exit 1
        fi
        echo ">> cleaning a stale $lock — flock'd, but no switch process is alive."
        echo ">> orphaned holders of the old fd (informational):"
        fuser -v "$lock" || true
        rm -f -- "$lock"
      fi

      # ── start the switch DETACHED ──────────────────────────────────────────
      if [ -s "$resfile" ]; then
        echo ">> previous $mode result: $(cat "$resfile")"
      fi
      mkdir -p /run/nixnas
      rm -f -- "$resfile"
      started="$(date '+%Y-%m-%d %H:%M:%S')"
      echo ">> $mode → $resolved"
      echo ">> starting detached unit $unit.service — owned by PID 1; losing this"
      echo ">> session can NOT interrupt the activation."
      # --no-block: return once the unit is created (a blocking start would tie the
      #   oneshot's completion to this droppable client again).
      # --collect: a failed run is garbage-collected too — no `reset-failed` needed
      #   before a retry. That GC is why ExecStopPost must persist the result:
      #   /bin/sh is guaranteed on NixOS, and $$ keeps the vars for systemd to hand
      #   to the hook, where the shell expands them from its environment.
      # TimeoutStartSec=infinity: a big switch may legitimately take long; it must
      #   never be killed by a start timeout mid-activation (oneshot's default is
      #   already infinity — pinned explicitly because a timeout here is the exact
      #   half-activation this tool exists to prevent).
      systemd-run \
        --no-block \
        --unit="$unit" \
        --description="nixnas-switch: switch-to-configuration $mode → $resolved" \
        --service-type=oneshot \
        --collect \
        --quiet \
        --property=TimeoutStartSec=infinity \
        --property="ExecStopPost=${resultCapture} $resfile" \
        -- "$stc" "$mode"

      # ── follow the unit until it reports ───────────────────────────────────
      journalctl -u "$unit" --since "$started" --follow --no-pager --output=cat &
      follower=$!
      on_detach() {
        kill "$follower" 2>/dev/null || true
        echo ""
        echo ">> detached — $unit.service keeps running unattended."
        echo ">>   follow:  journalctl -fu $unit"
        echo ">>   result:  cat $resfile   (written when it finishes)"
        exit 130
      }
      trap on_detach INT TERM

      while [ ! -s "$resfile" ]; do
        if [ "$(systemctl show -p LoadState --value "$unit.service")" = "not-found" ]; then
          # ExecStopPost writes before the unit deactivates; allow the write to land.
          sleep 1
          if [ ! -s "$resfile" ]; then
            trap - INT TERM
            kill "$follower" 2>/dev/null || true
            wait "$follower" 2>/dev/null || true
            echo "!! $unit.service is gone but reported no result — inspect: journalctl -u $unit -b" >&2
            exit 1
          fi
        fi
        sleep 1
      done

      trap - INT TERM
      sleep 1   # let the follower drain the tail of the unit's output
      kill "$follower" 2>/dev/null || true
      wait "$follower" 2>/dev/null || true

      # ── report the honest result (from the ExecStopPost capture) ───────────
      read -r result status < "$resfile" || { echo "!! cannot read $resfile" >&2; exit 1; }
      echo ""
      if [ "$result" = "success" ]; then
        echo "OK — $unit.service finished: Result=success (exit $status)."
      else
        echo "FAILED — $unit.service finished: Result=$result, exit status $status." >&2
        echo "   full log: journalctl -u $unit -b" >&2
        case "$status" in
          ""|*[!0-9]*|0) exit 1 ;;
          *) exit "$status" ;;
        esac
      fi
    '';
  };
in
{
  # Expose the tool UNCONDITIONALLY so CI can build it (writeShellApplication runs
  # shellcheck at build time — the cheap guard used for every shipped shell application).
  config = lib.mkMerge [
    { system.build.nixnasSwitch = switchTool; }

    (lib.mkIf cfg.enable {
      # Both store locations — usb and hot systems are switched the same safe way.
      environment.systemPackages = [ switchTool ];
    })
  ];
}
