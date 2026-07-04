# shellcheck shell=bash
# test/assert-no-failed-units.sh — CI quality gate: a "booted" system with failed
# systemd units is NOT a passing system.
#
# Why: every suite's success marker (login prompt, sealed blob, ESP contents) only
# proves the HAPPY path progressed. A oneshot that failed BEHIND the marker sails
# through — which is exactly how a broken unit shipped. This gate makes
# `systemctl --failed` EMPTY a hard postcondition of every booted system a suite
# can reach over SSH.
#
# Usage (sourced, never executed):
#   . "$(dirname "$0")/assert-no-failed-units.sh"
#   # requires: SSH — an array whose expansion is a complete ssh command ending in
#   # the destination (e.g. root@127.0.0.1), against a booted system.
#   assert_no_failed_units "boot #1 (running system)" || exit 1
#   # or, right after a serial login-prompt marker (sshd may still be binding):
#   assert_no_failed_units_after_ssh_wait "boot #2 (running system)" 20 || exit 1
#
# Allowlist (the documented escape hatch — DEFAULT EMPTY):
#   NIXNAS_FAILED_UNITS_ALLOWLIST — space-separated EXACT unit names (e.g.
#   "foo.service bar.service") that may be failed without failing the gate.
#   Every use must be justified where it is set (workflow env). The empty default
#   means ANY failed unit fails the suite.
#
# Exit-code note (verified empirically): `systemctl --failed` exits 0 whether or
# not failed units exist — the gate keys on OUTPUT EMPTINESS. A non-zero rc from
# the ssh/systemctl call therefore means "could not verify", and the gate fails
# CLOSED (an unverifiable system is a failing system).

# assert_no_failed_units <label> — hard-assert `systemctl --failed` is empty on the
# system behind ${SSH[@]}. Prints the offending units (plus a bounded status dump)
# and returns 1 on failure.
assert_no_failed_units() {
  local label="${1:?assert_no_failed_units: label required}"
  local out rc line unit remaining=""
  # --plain --no-legend --full: bare "UNIT LOAD ACTIVE SUB DESCRIPTION" rows, no
  # legend, no ellipsised unit names. BatchMode: a CI gate must never hang on an
  # interactive auth prompt. (ssh parses -o after the destination as an option.)
  out="$("${SSH[@]}" -o BatchMode=yes \
    'systemctl --failed --no-legend --plain --full' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "!! ${label}: could not query failed units over SSH (rc=${rc}) — failing closed" >&2
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    unit="${line%%[[:space:]]*}"      # first column = the unit name
    case " ${NIXNAS_FAILED_UNITS_ALLOWLIST:-} " in
      *" ${unit} "*)
        echo "   ${label}: ignoring ALLOWLISTED failed unit: ${unit}" ;;
      *)
        remaining="${remaining}${line}"$'\n' ;;
    esac
  done <<EOF_FAILED_UNITS
${out}
EOF_FAILED_UNITS
  if [ -n "$remaining" ]; then
    echo "!! ${label}: FAILED systemd units on the booted system (gate: list must be EMPTY):"
    printf '%s' "$remaining" | sed 's/^/     /'
    # Bounded diagnosis: status of the first offenders (includes their recent log lines).
    printf '%s' "$remaining" | awk '{print $1}' | head -5 | while IFS= read -r unit; do
      echo "   ---- systemctl status ${unit} ----"
      "${SSH[@]}" -o BatchMode=yes "systemctl status --no-pager -l -- '${unit}'" 2>/dev/null \
        | sed 's/^/   /' || true
    done
    echo "!! ${label}: failed-units gate FAILED" \
         "(allowlist NIXNAS_FAILED_UNITS_ALLOWLIST='${NIXNAS_FAILED_UNITS_ALLOWLIST:-}')"
    return 1
  fi
  echo "   ${label}: no failed systemd units (systemctl --failed empty) ✔"
}

# assert_no_failed_units_after_ssh_wait <label> [tries=20] — poll the running-system
# sshd first (right after a serial login-prompt marker it may still be binding; after
# switch-root the forwarded port moves from initrd-SSH to the running sshd), then gate.
assert_no_failed_units_after_ssh_wait() {
  local label="${1:?assert_no_failed_units_after_ssh_wait: label required}"
  local tries="${2:-20}" up=0 _i
  for _i in $(seq 1 "$tries"); do
    if "${SSH[@]}" -o BatchMode=yes true 2>/dev/null; then up=1; break; fi
    sleep 3
  done
  if [ "$up" != 1 ]; then
    echo "!! ${label}: running-system SSH never became reachable — cannot verify" \
         "failed units (failing closed)" >&2
    return 1
  fi
  assert_no_failed_units "$label"
}
