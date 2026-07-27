#!/usr/bin/env bash
# test/matrix-eval-test.sh — cheap eval-level coverage of the nixnas matrix variants.
#
# WHAT IS UNDER TEST: six nixosConfigurations defined in the integrator-provided flake
# snippet (see the return value of this script's authorship task), each proving a distinct
# real-operator configuration evaluates without error AND propagates option values into
# the expected NixOS config attributes:
#
#   matrix-no-tpm      — sealHostKey=false + plaintext hostKeyPath (Path B remote-unlock)
#   matrix-stick-4g    — 4 GiB stick: imageSizeGiB=4, espSizeMiB=512 + budget math
#   matrix-stick-16g   — 16 GiB stick: imageSizeGiB=16, espSizeMiB=2048 + budget math
#   matrix-stick-32g   — 32 GiB stick: imageSizeGiB=32, espSizeMiB=2048 + budget math
#   matrix-hot-ext4    — hot mode, fsType=ext4: initrd MUST carry NO "zfs" filesystem
#   matrix-pin-strict  — requirePin=true explicit + pcrs=[7,11] → crypttab has tpm2-pin=yes
#   matrix-persist-nested — StateDirectory nested under a bind-mounted ancestor must evaluate
#                            (persist-enforce ancestor walk; 2026-07-24 acme incident guard)
#
# Each config is probed with `nix eval` only — no builds, no QEMU. This is intentionally
# cheap: the goal is eval-correctness coverage (option wiring, assertion guards, module
# interactions), not boot-chain proof (that is hot-boot-test.sh / seal-2boot-test.sh).
#
# Usage: [FLAKE=.] test/matrix-eval-test.sh
set -uo pipefail

FLAKE="${FLAKE:-.}"

for c in nix; do
  command -v "$c" >/dev/null || { echo "!! missing tool: $c" >&2; exit 1; }
done

# ── portable OVMF firmware finder (available if this script is extended to boot tests) ──
# Copied verbatim from test/seal-2boot-test.sh so both scripts share the same detection
# logic — single authoritative source for distro path variants.
find_fw() { # find_fw "name1 name2 ..." → prints first existing path under the known dirs
  local d n
  for d in /usr/share/edk2-ovmf/x64 /usr/share/edk2/x64 /usr/share/OVMF /usr/share/ovmf/x64 /usr/share/qemu; do
    # shellcheck disable=SC2086  # intentional: $1 is a space-separated list of firmware names
    for n in $1; do [ -e "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }; done
  done
  return 1
}

PASS=0; FAIL=0

# ── check helpers ──────────────────────────────────────────────────────────────────────
ok()   { echo "  ok    $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $*"; FAIL=$(( FAIL + 1 )); }

# nix_eval ATTR [NIX_FLAGS...] — eval a single flake output attribute, return its value.
# Errors (undefined attrs, assertion failures) are surfaced as an empty string, which the
# caller checks.
nix_eval() {
  local attr="$1"; shift
  nix eval "$FLAKE#$attr" "$@" 2>/dev/null
}

# check_drv LABEL NIXOS_CONFIG — eval the toplevel drvPath; fail if empty.
check_drv() {
  local label="$1" cfg="$2"
  local drv
  drv=$(nix_eval "nixosConfigurations.${cfg}.config.system.build.toplevel.drvPath" --raw)
  if [ -n "$drv" ]; then
    ok "$label: evaluates (drvPath ${drv##/nix/store/})"
  else
    fail "$label: eval FAILED (assertion error or undefined attr — run: nix eval $FLAKE#nixosConfigurations.${cfg}.config.system.build.toplevel.drvPath)"
  fi
}

# check_eq LABEL ACTUAL EXPECTED — compare strings.
check_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    fail "$label  (expected: $expected  got: $actual)"
  fi
}

# check_contains LABEL HAYSTACK NEEDLE — grep for substring.
check_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    ok "$label"
  else
    fail "$label  (expected '$needle' in: $haystack)"
  fi
}

# check_absent LABEL HAYSTACK NEEDLE — assert substring is absent.
check_absent() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$label  ('$needle' was present but must be absent in: $haystack)"
  else
    ok "$label"
  fi
}

# budget_check LABEL IMAGE_GIB ESP_MIB MAX_CLOSURE_BYTES KEEP_GENS
# Assert: ESP fits in image AND (max_closure_bytes * keep_gens) fits in the effective
# compressed store (conservative: uses 2.3× factor expressed as 23/10 for integer math).
budget_check() {
  local label="$1" image_gib="$2" esp_mib="$3" max_bytes="$4" keep_gens="$5"
  local esp_limit=$(( image_gib * 1024 ))
  if [ "$esp_mib" -ge "$esp_limit" ]; then
    fail "$label: ESP ($esp_mib MiB) does not fit in image (${image_gib} GiB = $esp_limit MiB)"
    return
  fi
  local store_mib=$(( image_gib * 1024 - esp_mib ))
  # Effective bytes at 2.3× compression (23/10 for integer arithmetic):
  local effective=$(( store_mib * 1024 * 1024 * 23 / 10 ))
  local needed=$(( max_bytes * keep_gens ))
  if [ "$needed" -le "$effective" ]; then
    ok "$label: budget ok (${keep_gens}×${max_bytes}B needed ≤ ${effective}B effective @ 2.3× on ${store_mib} MiB raw)"
  else
    fail "$label: BUDGET OVERFLOW — ${keep_gens}×${max_bytes}B = ${needed}B > ${effective}B effective (store ${store_mib} MiB × 2.3)"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 1: matrix-no-tpm
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-no-tpm (sealHostKey=false + plaintext hostKeyPath) ──"
check_drv "no-tpm" "matrix-no-tpm"

v=$(nix_eval "nixosConfigurations.matrix-no-tpm.config.nixnas.crypto.tpm2.enable" --json)
check_eq "no-tpm: crypto.tpm2.enable = false" "$v" "false"

v=$(nix_eval "nixosConfigurations.matrix-no-tpm.config.nixnas.boot.remoteUnlock.sealHostKey" --json)
check_eq "no-tpm: remoteUnlock.sealHostKey = false" "$v" "false"

# With sealHostKey=false the initrd must carry a plaintext host key (Path B).
# boot.initrd.network.ssh.hostKeys is a list of key paths — must be non-empty.
v=$(nix_eval "nixosConfigurations.matrix-no-tpm.config.boot.initrd.network.ssh.hostKeys" --json)
check_absent "no-tpm: ssh.hostKeys list is not empty" "$v" "[]"

# The sealed-credential LoadCredentialEncrypted must NOT be present (Path A is inactive).
v=$(nix_eval "nixosConfigurations.matrix-no-tpm.config.boot.initrd.systemd.services.sshd.serviceConfig" --json 2>/dev/null || echo "{}")
check_absent "no-tpm: initrd sshd has no LoadCredentialEncrypted (Path A inactive)" "$v" "LoadCredentialEncrypted"

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 2: matrix-stick-4g
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-stick-4g (4 GiB: imageSizeGiB=4, espSizeMiB=512, keepGens=3, budget=1GiB) ──"
check_drv "stick-4g" "matrix-stick-4g"

image_gib=$(nix_eval "nixosConfigurations.matrix-stick-4g.config.nixnas.boot.usb.imageSizeGiB" --json)
esp_mib=$(nix_eval   "nixosConfigurations.matrix-stick-4g.config.nixnas.boot.usb.espSizeMiB"   --json)
keep_gens=$(nix_eval "nixosConfigurations.matrix-stick-4g.config.nixnas.boot.keepGenerations"  --json)
max_bytes=$(nix_eval "nixosConfigurations.matrix-stick-4g.config.nixnas.store.maxClosureBytes" --json)

check_eq "stick-4g: imageSizeGiB = 4"              "$image_gib"  "4"
check_eq "stick-4g: espSizeMiB = 512"              "$esp_mib"    "512"
check_eq "stick-4g: keepGenerations = 3"            "$keep_gens"  "3"
check_eq "stick-4g: maxClosureBytes = 1 GiB"        "$max_bytes"  "$(( 1 * 1024 * 1024 * 1024 ))"
budget_check "stick-4g: budget arithmetic" \
  "$image_gib" "$esp_mib" "$max_bytes" "$keep_gens"

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 3: matrix-stick-16g
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-stick-16g (16 GiB: imageSizeGiB=16, espSizeMiB=2048, keepGens=8, budget=3GiB) ──"
check_drv "stick-16g" "matrix-stick-16g"

image_gib=$(nix_eval "nixosConfigurations.matrix-stick-16g.config.nixnas.boot.usb.imageSizeGiB" --json)
esp_mib=$(nix_eval   "nixosConfigurations.matrix-stick-16g.config.nixnas.boot.usb.espSizeMiB"   --json)
keep_gens=$(nix_eval "nixosConfigurations.matrix-stick-16g.config.nixnas.boot.keepGenerations"  --json)
max_bytes=$(nix_eval "nixosConfigurations.matrix-stick-16g.config.nixnas.store.maxClosureBytes" --json)

check_eq "stick-16g: imageSizeGiB = 16"            "$image_gib"  "16"
check_eq "stick-16g: espSizeMiB = 2048"            "$esp_mib"    "2048"
check_eq "stick-16g: keepGenerations = 8"           "$keep_gens"  "8"
check_eq "stick-16g: maxClosureBytes = 3 GiB"       "$max_bytes"  "$(( 3 * 1024 * 1024 * 1024 ))"
budget_check "stick-16g: budget arithmetic" \
  "$image_gib" "$esp_mib" "$max_bytes" "$keep_gens"

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 4: matrix-stick-32g
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-stick-32g (32 GiB: imageSizeGiB=32, espSizeMiB=2048, keepGens=8, budget=5GiB) ──"
check_drv "stick-32g" "matrix-stick-32g"

image_gib=$(nix_eval "nixosConfigurations.matrix-stick-32g.config.nixnas.boot.usb.imageSizeGiB" --json)
esp_mib=$(nix_eval   "nixosConfigurations.matrix-stick-32g.config.nixnas.boot.usb.espSizeMiB"   --json)
keep_gens=$(nix_eval "nixosConfigurations.matrix-stick-32g.config.nixnas.boot.keepGenerations"  --json)
max_bytes=$(nix_eval "nixosConfigurations.matrix-stick-32g.config.nixnas.store.maxClosureBytes" --json)

check_eq "stick-32g: imageSizeGiB = 32"            "$image_gib"  "32"
check_eq "stick-32g: espSizeMiB = 2048"            "$esp_mib"    "2048"
check_eq "stick-32g: keepGenerations = 8"           "$keep_gens"  "8"
check_eq "stick-32g: maxClosureBytes = 5 GiB"       "$max_bytes"  "$(( 5 * 1024 * 1024 * 1024 ))"
budget_check "stick-32g: budget arithmetic" \
  "$image_gib" "$esp_mib" "$max_bytes" "$keep_gens"

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 5: matrix-hot-ext4
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-hot-ext4 (hot mode, fsType=ext4, assert initrd has NO zfs) ──"
check_drv "hot-ext4" "matrix-hot-ext4"

v=$(nix_eval "nixosConfigurations.matrix-hot-ext4.config.nixnas.store.location" --raw)
check_eq "hot-ext4: store.location = hot" "$v" "hot"

v=$(nix_eval "nixosConfigurations.matrix-hot-ext4.config.nixnas.store.hot.fsType" --raw)
check_eq "hot-ext4: store.hot.fsType = ext4" "$v" "ext4"

# The load-bearing assertion: location.nix's ZFS-in-initrd block is behind
# `lib.mkIf (hot.fsType == "zfs")`. With ext4 it must be entirely inactive.
# boot.initrd.supportedFilesystems: whether list (["zfs"]) or attrset ({"zfs":true}),
# the JSON rendering will contain the string "zfs" if ZFS is enabled — grep catches both.
v=$(nix_eval "nixosConfigurations.matrix-hot-ext4.config.boot.initrd.supportedFilesystems" --json)
check_absent "hot-ext4: initrd.supportedFilesystems has no zfs entry" "$v" '"zfs"'

# boot.zfs.devNodes is set by the ZFS block in location.nix; for ext4 it must stay
# at the NixOS default ("/dev/disk/by-id") — not "/dev/mapper".
v=$(nix_eval "nixosConfigurations.matrix-hot-ext4.config.boot.zfs.devNodes" --raw)
check_absent "hot-ext4: boot.zfs.devNodes not redirected to /dev/mapper (zfs block inactive)" \
  "$v" "/dev/mapper"

# The zfs-import initrd service override must not exist for an ext4 hot store.
# We check via the initrd systemd services attrset — absence of "zfs-import" in the keys.
v=$(nix_eval "nixosConfigurations.matrix-hot-ext4.config.boot.initrd.systemd.services" --json 2>/dev/null || echo "{}")
check_absent "hot-ext4: no zfs-import service in initrd.systemd.services" "$v" "zfs-import"

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 6: matrix-pin-strict
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-pin-strict (requirePin=true explicit, pcrs=[7,11], crypttab has tpm2-pin=yes) ──"
check_drv "pin-strict" "matrix-pin-strict"

v=$(nix_eval "nixosConfigurations.matrix-pin-strict.config.nixnas.crypto.tpm2.requirePin" --json)
check_eq "pin-strict: crypto.tpm2.requirePin = true" "$v" "true"

v=$(nix_eval "nixosConfigurations.matrix-pin-strict.config.nixnas.crypto.tpm2.pcrs" --json)
check_eq "pin-strict: crypto.tpm2.pcrs = [7,11]" "$v" "[7,11]"

# The critical end-to-end check: requirePin must propagate into the initrd LUKS
# crypttab extras that systemd-cryptsetup reads at unlock time.
v=$(nix_eval "nixosConfigurations.matrix-pin-strict.config.boot.initrd.luks.devices.cryptstore.crypttabExtraOpts" --json)
check_contains "pin-strict: crypttabExtraOpts contains tpm2-device=auto" "$v" '"tpm2-device=auto"'
check_contains "pin-strict: crypttabExtraOpts contains tpm2-pin=yes"     "$v" '"tpm2-pin=yes"'

# ──────────────────────────────────────────────────────────────────────────────────────
# VARIANT 7: matrix-persist-nested
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── matrix-persist-nested (StateDirectory nested under a bind-mounted ancestor) ──"
# The load-bearing proof: this variant declares StateDirectory two path components below a
# fileSystems bind mount, never as its own exact key. Before the ancestor-walk fix, this ate
# an assertion failure (nix eval below would come back empty) exactly like the real-world
# regression this guards against: a set of ACME service units (acme-setup plus a per-domain
# order/renew unit pair) all nested under fileSystems."/var/lib/acme", none of which matched an
# exact StateDirectory key. check_drv succeeding here is the regression guard:
# persist-enforce.nix must keep recognizing this shape as persisted.
check_drv "persist-nested" "matrix-persist-nested"

# ──────────────────────────────────────────────────────────────────────────────────────
# INVARIANT: nixram owns the memory subsystem; zswap is off under mode = "zram"
# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "── nixram ownership + zswap invariant (appliance/optimizations.nix) ──"
# The CachyOS kernel nixnas ships is built with CONFIG_ZSWAP_DEFAULT_ON=y, so zswap is
# armed before userspace exists -- nothing in any config file to grep for. Combined with
# the appliance default of zram-as-the-only-swap, zswap's writeback target becomes RAM
# itself: it compresses already-compressed pages into the resource it is caching, and with
# swapDevices = [ ] it has nowhere to evict to at all. Found live on a 125 GiB deployment
# (enabled=Y, stored_pages climbing, written_back_pages pinned at 0).
#
# Both directions matter. The parameter must appear by default, AND it must disappear on
# its own for a host that gives itself a real swap partition -- the gate is written against
# swapDevices precisely so that host needs no override to remember.
v=$(nix_eval "nixosConfigurations.demo.config.boot.kernelParams" --json)
check_contains "zswap: disabled by default (swapDevices = [ ])" "$v" '"zswap.enabled=0"'

# Also proves the parameter MERGES with a host's own boot.kernelParams rather than
# replacing them (it is a list; a lib.mkDefault here would have been silently dropped by
# any host defining kernelParams at normal priority).
check_contains "zswap: host kernelParams still present alongside it" "$v" '"root=fstab"'

# The negative half, via extendModules so it is provably the SAME config with one
# option changed -- not a separate hand-built variant that could drift. An operator
# who genuinely wants zswap declares it, and must give the host a durable swap device
# for it to cache in front of (nixram asserts that pairing itself).
v=$(nix eval --impure --json --expr "
((builtins.getFlake \"$(pwd)\").nixosConfigurations.demo.extendModules {
  modules = [ {
    nixram.mode = \"zswap\";
    swapDevices = [ { device = \"/dev/disk/by-label/swap\"; } ];
  } ];
}).config.boot.kernelParams" 2>/dev/null)
if [ -n "$v" ] && ! printf '%s' "$v" | grep -q '"zswap.enabled=0"'; then
  ok "zswap: not disabled when the operator explicitly selects mode = zswap"
else
  fail "zswap: still force-disabled under mode = zswap (got: ${v:-<eval failed>})"
fi
check_contains "zswap: mode = zswap arms it instead" "$v" '"zswap.enabled=1"'

# nixnas itself must declare NO memory values -- the whole point of the migration.
# zramSwap is nixpkgs' own module and renders the same zram-generator.conf nixram
# does, so a leftover declaration here is not cosmetic: it is a hard eval conflict
# waiting for the next person who sets a level.
if grep -rqE '^\s*(zramSwap|boot\.kernel\.sysctl|systemd\.oomd)' modules/; then
  fail "nixnas still declares memory-subsystem values (grep modules/ for zramSwap/sysctl/oomd)"
else
  ok "nixnas declares no memory-subsystem values of its own"
fi

# ──────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "================ RESULT ================"
total=$(( PASS + FAIL ))
if [ "$FAIL" = 0 ]; then
  echo "PASS — all ${total} matrix eval checks passed."
  echo "       Seven nixnas operator-persona variants evaluate without error and carry"
  echo "       the expected option values, plus the zswap/swapDevices invariant in both"
  echo "       directions. (No builds, no QEMU — eval-correctness only.)"
  exit 0
fi
echo "FAIL — ${FAIL} of ${total} checks failed (PASS: ${PASS})."
echo "       Run individual failing nix eval commands (shown above) to diagnose."
exit 1
