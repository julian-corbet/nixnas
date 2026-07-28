# nixnas — `nixnas-install-hot`: install a HOT-mode MAIN from the running rescue/usb system.
#
# The rescue IS the install environment (docs/HOT-MODE.md): the stick boots the box, the
# operator unlocks/creates their pool(s), the build machine `nix copy`s the MAIN toplevel
# over (or the box builds it), and THIS tool does the error-prone dance in one verified shot:
#
#   nixnas-install-hot --device hot/nixnas/nix --root-device hot/nixnas/root \
#     /nix/store/xxxx-nixos-system-main
#
#   1. sanity: the toplevel exists locally; each zfs device's pool is imported (imports it
#      off /dev/mapper if not) and its dataset is mountpoint=legacy (the hot-mode contract) —
#      checked for BOTH the store device and the root device;
#   2. stage the target: the REAL PERSISTENT ROOT DEVICE mounted at /mnt/nixnas-install (NOT
#      a scratch tmpfs — a persistent root is the whole point of this refactor: everything
#      nixos-install writes under the target root — /etc, /var, /home, the user db — must
#      land on real storage, not be thrown away when this script's mount points unwind), the
#      hot store mounted at ./nix within it, and the BOOTED stick's ESP bind-mounted at
#      ./boot (the rescue's /boot IS the shared ESP);
#   3. seed the Secure Boot PKI from this system's /nix/lanzaboote/pki into the target
#      store (mkdir first — a bare cp into a missing dir lands the keys one level up),
#      and VERIFY the db key landed where the main's lanzaboote will look;
#   4. `nixos-install --system` — registers the profile in the hot store, installs the
#      main's signed UKIs onto the shared ESP, and populates the REAL root (/etc, /var,
#      users) that now persists across every future reboot;
#   5. pre-place the durable rescue entry EFI/Linux/nixnas-rescue.efi (step 4's installer
#      prunes the rescue's original `nixos-*` entries, and rescue-maintain only takes over
#      after the main first boots — without this the riskiest reboot has no rescue);
#   6. verify: profile registered, main UKIs + rescue UKI on the ESP. Then: reboot.
#
# If the closure is not on the box yet, the build machine pushes it here first:
#   nix copy --to "ssh://<this-box>?remote-store=/mnt/nixnas-install" <toplevel>
#   (or plain `nix copy --to ssh://<this-box>` into THIS store before staging — both work;
#   the tool re-copies local→target as needed.)
#
# WHAT NIXNAS DOES NOT DO HERE: it never `zfs create`s / `mkfs`s the root dataset/device —
# same "unlock + import + mount, never format" contract as the hot store and every data
# pool (docs/HOT-MODE.md step 0). The operator creates the root dataset the same way they
# create the store one, e.g. `zfs create -o mountpoint=legacy hot/nixnas/root`.
#
# Ships on usb-mode systems (any usb nixnas can install a hot sibling — the rescue story).
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;

  installHot = pkgs.writeShellApplication {
    name = "nixnas-install-hot";
    runtimeInputs = with pkgs; [
      nix coreutils util-linux nixos-install-tools zfs sbsigntool gnugrep
    ];
    text = ''
      device=""; fstype="zfs"; toplevel=""
      rootDevice=""; rootFstype="zfs"
      usage() {
        echo "usage: nixnas-install-hot --device <dataset|/dev/mapper/x> [--fstype zfs|ext4|…] \\" >&2
        echo "                          --root-device <dataset|/dev/mapper/x> [--root-fstype zfs|ext4|…] \\" >&2
        echo "                          <main-toplevel-store-path>" >&2
        exit 2
      }
      while [ $# -gt 0 ]; do case "$1" in
        --device) device="$2"; shift ;;
        --fstype) fstype="$2"; shift ;;
        --root-device) rootDevice="$2"; shift ;;
        --root-fstype) rootFstype="$2"; shift ;;
        -h|--help) usage ;;
        /nix/store/*) toplevel="$1" ;;
        *) echo "unknown arg: $1" >&2; usage ;;
      esac; shift; done
      [ -n "$device" ] && [ -n "$rootDevice" ] && [ -n "$toplevel" ] || usage
      [ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

      # ── 1. sanity ──────────────────────────────────────────────────────────
      [ -e "$toplevel/init" ] || { echo "!! $toplevel is not a system toplevel (no ./init) — nix copy it to this box first" >&2; exit 1; }
      pki=/nix/lanzaboote/pki
      [ -r "$pki/keys/db/db.key" ] || { echo "!! no Secure Boot PKI at $pki (this must run on a TUI-flashed nixnas stick)" >&2; exit 1; }

      # checked for BOTH the store device and the root device — either can be zfs or not,
      # independently, so this runs once per device with its own fstype.
      check_zfs_legacy() {
        dev="$1"; fst="$2"; label="$3"
        [ "$fst" = "zfs" ] || return 0
        pool="''${dev%%/*}"
        zpool list "$pool" >/dev/null 2>&1 || {
          echo ">> importing pool $pool for $label (off /dev/mapper — unlock your members first: nixnas-unlock)"
          zpool import -d /dev/mapper "$pool"
        }
        mp="$(zfs get -H -o value mountpoint "$dev")"
        [ "$mp" = "legacy" ] || { echo "!! $label device $dev has mountpoint=$mp — the hot-mode contract is mountpoint=legacy (zfs set mountpoint=legacy $dev)" >&2; exit 1; }
      }
      check_zfs_legacy "$device" "$fstype" "store"
      check_zfs_legacy "$rootDevice" "$rootFstype" "root"

      # ── 2. stage the target: the PERSISTENT ROOT DEVICE, then /nix and /boot within it ──
      target=/mnt/nixnas-install
      cleanup() {
        umount "$target/boot" 2>/dev/null || true
        umount "$target/nix" 2>/dev/null || true
        umount "$target" 2>/dev/null || true
      }
      trap cleanup EXIT
      mkdir -p "$target"
      if [ "$rootFstype" = "zfs" ]
      then mount -t zfs "$rootDevice" "$target"
      else mount -t "$rootFstype" "$rootDevice" "$target"
      fi
      mkdir -p "$target/nix" "$target/boot"
      if [ "$fstype" = "zfs" ]
      then mount -t zfs "$device" "$target/nix"
      else mount -t "$fstype" "$device" "$target/nix"
      fi
      mount --bind /boot "$target/boot"   # the booted stick's ESP IS the shared ESP

      # ── 3. seed the PKI (mkdir FIRST — see the header) + verify ────────────
      mkdir -p "$target/nix/lanzaboote"
      cp -a "$pki" "$target/nix/lanzaboote/"
      [ -r "$target/nix/lanzaboote/pki/keys/db/db.key" ] || { echo "!! PKI seed landed wrong" >&2; exit 1; }

      # ── 4. the closure + the install ───────────────────────────────────────
      echo ">> copying the toplevel closure into the hot store …"
      nix copy --no-check-sigs --to "$target" "$toplevel"
      echo ">> nixos-install (profile + the main's signed UKIs onto the shared ESP + the real root) …"
      nixos-install --root "$target" --system "$toplevel" --no-root-passwd --no-channel-copy

      # ── 5. pre-place the durable rescue entry (survives the main's ESP GC) ──
      if [ ! -f /boot/EFI/Linux/nixnas-rescue.efi ]; then
        echo ">> pre-placing EFI/Linux/nixnas-rescue.efi from the running system …"
        me="$(readlink -f /run/current-system)"
        work="$(mktemp -d)"
        osrel=()
        [ -e "$me/etc/os-release" ] && osrel=(--os-release="@$me/etc/os-release")
        ${pkgs.systemdUkify}/bin/ukify build \
          --linux="$me/kernel" --initrd="$me/initrd" \
          --cmdline="init=$me/init $(cat "$me/kernel-params")" \
          "''${osrel[@]}" --output="$work/r.efi"
        sbsign --key "$pki/keys/db/db.key" --cert "$pki/keys/db/db.pem" \
          --output /boot/EFI/Linux/nixnas-rescue.efi "$work/r.efi"
        rm -rf "$work"
      fi

      # ── 6. verify ──────────────────────────────────────────────────────────
      fail=0
      [ -e "$target/nix/var/nix/profiles/system" ] || { echo "!! no system profile in the hot store" >&2; fail=1; }
      [ -e "$target/etc" ] || { echo "!! no /etc on the root device — nixos-install did not populate it" >&2; fail=1; }
      ls /boot/EFI/Linux/nixos-generation-*.efi >/dev/null 2>&1 || { echo "!! no main UKI on the ESP" >&2; fail=1; }
      [ -f /boot/EFI/Linux/nixnas-rescue.efi ] || { echo "!! no rescue UKI on the ESP" >&2; fail=1; }
      sync
      [ "$fail" = 0 ] || exit 1
      echo ""
      echo "OK — the MAIN is installed: root on $rootDevice, store on $device, UKIs on the"
      echo "shared ESP, and the rescue entry is in place. Reboot; the main entry is the"
      echo "default. Its initrd will wait for YOUR passphrase (initrd-SSH from the 2nd boot;"
      echo "console for the first)."
    '';
  };
in
{
  # Any usb-mode nixnas can install a hot-mode sibling — that IS the rescue's install role.
  config = lib.mkIf (cfg.enable && cfg.store.location == "usb") {
    environment.systemPackages = [ installHot ];
    system.build.hotInstaller = installHot;
  };
}
