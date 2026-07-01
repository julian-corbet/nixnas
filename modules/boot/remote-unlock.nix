# nixnas — headless remote store unlock via initrd-SSH.
#
# The store is unlocked in the INITRD, but the box is headless: nobody can type the
# PIN/passphrase at the console. So we bring the NIC up inside the initrd and run an
# sshd there — you `ssh root@<box>` and hand the secret to systemd's password agent,
# then the boot proceeds. This is the PRIMARY remote-unlock channel (IPMI-SOL, where
# present, is the alternative — set `boot.remoteUnlock.enable = false`). ARCHITECTURE §6.
#
# HOST KEY — two paths, controlled by `sealHostKey`:
#
# PATH A: sealHostKey = true (default, requires crypto.tpm2.enable)
#   The initrd-SSH host key never touches the plaintext ESP. On FIRST BOOT:
#     1. stage-2 `nixnas-seal-hostkey` generates an ed25519 key, seals it to the
#        box's TPM2 (PCR 7, Secure Boot state) via `systemd-creds encrypt`, writes
#        the ciphertext blob to /boot/nixnas/initrd-hostkey.cred, shreds the plaintext.
#   From the SECOND BOOT onwards:
#     2. initrd `nixnas-unseal-hostkey` mounts the ESP read-only, decrypts the blob
#        via `systemd-creds decrypt --tpm2-device=auto`, writes the private key to
#        /run/nixnas/initrd_host_ed25519_key, then sshd picks it up from there.
#   BOOTSTRAP CAVEAT: first boot has no sealed blob → the unseal service exits 1 →
#   sshd does NOT start → operator uses serial console or IPMI-SOL for the first
#   unlock. After stage-2 completes and the seal service runs, every subsequent boot
#   has initrd-SSH available. A tampered boot chain (PCR 7 mismatch) cannot recover
#   the key, so a stolen stick cannot impersonate the box's unlock prompt.
#   PCR 7 (Secure Boot state) is update-stable; kernel/UKI updates need no reseal.
#
# PATH B: sealHostKey = false (or crypto.tpm2.enable = false)
#   The host key is a BUILD-MACHINE path (`hostKeyPath`), embedded in the initrd at
#   build time and landed on the plaintext ESP inside the signed UKI. Keep this
#   LAN/tailnet-only. Unchanged from the original implementation.
#
# Login keys are `nixnas.admin.authorizedKeys` — the same set as the running system's sshd.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixnas;

  # ── Path B (plaintext): non-store destination for the host key inside the initrd.
  hostKeyDest = "/etc/ssh/nixnas_initrd_host_ed25519_key";
  # Source as its own tracked store path (proper context ⇒ present in the disko builder VM).
  # Guarded with null check so Nix never forces builtins.path on a null path.
  hostKeySource =
    if cfg.boot.remoteUnlock.hostKeyPath != null
    then builtins.path { path = cfg.boot.remoteUnlock.hostKeyPath; name = "nixnas-initrd-host-key"; }
    else null;

  # ── Path A (sealed): whether TPM-sealed initrd host key path is active.
  sealActive = cfg.boot.remoteUnlock.sealHostKey && cfg.crypto.tpm2.enable;

  # Runtime path where the unsealed key lands in the initrd (in RAM; never on the ESP).
  unsealedKeyPath = "/run/nixnas/initrd_host_ed25519_key";
  # systemd-creds must be explicitly present in the initrd (the stripped systemd there does
  # not bundle it by default); reference it by full path so the unseal unit always finds it.
  systemdCreds = "${pkgs.systemd}/bin/systemd-creds";
in
{
  config = lib.mkIf (cfg.enable && cfg.boot.remoteUnlock.enable) (lib.mkMerge [

    # ── Common: bring NIC up in the initrd for the remote unlock hand-off. ───────────────
    {
      assertions = [{
        assertion = sealActive || cfg.boot.remoteUnlock.hostKeyPath != null;
        message = ''
          nixnas.boot.remoteUnlock is enabled but no initrd-SSH host key is configured.
          Either:
            • Set crypto.tpm2.enable = true (keeps sealHostKey = true, the secure default):
              the key is generated + sealed to this box's TPM on first boot; from the 2nd
              boot the initrd unseals it. First boot needs serial/IPMI-SOL console access.
            • Or set boot.remoteUnlock.sealHostKey = false and supply a plaintext key via
              boot.remoteUnlock.hostKeyPath (key is embedded in the initrd at build time,
              lands on the plaintext ESP — LAN/tailnet-only).
            • Or set boot.remoteUnlock.enable = false if you unlock over IPMI-SOL instead.
        '';
      }];

      # Bring networking up in the initrd, then run sshd there for the unlock hand-off.
      boot.initrd.network.enable = true;
      boot.initrd.network.ssh = {
        enable = true;
        port = 22;
        authorizedKeys = cfg.admin.authorizedKeys;
      };
      # With systemd-initrd the classic udhcpc path is off; networkd handles the link, but
      # `network.enable` alone declares no .network, so the NIC would get no lease. DHCP every
      # ethernet link explicitly so the box is reachable for the unlock.
      boot.initrd.systemd.network = {
        enable = true;
        networks."10-uplink" = {
          matchConfig.Name = "en* eth*";
          networkConfig.DHCP = "yes";
        };
      };

      # The NIC drivers the initrd must load to get on the network (merges with image.nix).
      boot.initrd.availableKernelModules = [
        "virtio_net"                                   # VM testing
        "e1000e" "igb" "igc" "r8169" "tg3" "atlantic"  # common server/desktop NICs
      ];
    }

    # ── Path B: sealHostKey = false — embed the plaintext key in the initrd. ─────────────
    # Behaviour unchanged from the original implementation.
    (lib.mkIf (!sealActive && cfg.boot.remoteUnlock.hostKeyPath != null) {
      # A non-store STRING destination (NixOS uses it verbatim as the in-initrd HostKey path).
      boot.initrd.network.ssh.hostKeys = [ hostKeyDest ];
      # Override the auto-derived secret SOURCE with the real, tracked key so it is copied
      # into the initrd during the image build.
      boot.initrd.secrets.${hostKeyDest} = lib.mkForce hostKeySource;
    })

    # ── Path A: sealHostKey = true + crypto.tpm2.enable — TPM2-sealed key. ──────────────
    # See module header for the two-boot bootstrap sequence and PCR-mismatch guarantee.
    (lib.mkIf sealActive {

      # No static key embedded in the initrd — the key is decrypted from the TPM at runtime.
      # ignoreEmptyHostKeys suppresses the NixOS assertion that fires on empty hostKeys.
      # extraConfig injects the runtime key path into the initrd sshd_config.
      boot.initrd.network.ssh.ignoreEmptyHostKeys = true;
      boot.initrd.network.ssh.extraConfig = "HostKey ${unsealedKeyPath}\n";

      # FAT driver to mount the ESP read-only inside the initrd (for the sealed blob).
      boot.initrd.kernelModules = [ "vfat" ];
      # Ensure systemd-creds (+ closure) is inside the initrd for the unseal.
      boot.initrd.systemd.storePaths = [ systemdCreds ];

      # ── Initrd unseal service ─────────────────────────────────────────────────────────
      # Mounts the ESP, decrypts the TPM2-sealed credential blob, writes the private key to
      # /run (RAM) for sshd. Fails cleanly on first boot (no blob yet) so sshd doesn't start
      # and the operator falls through to serial/IPMI-SOL for the first unlock.
      boot.initrd.systemd.services.nixnas-unseal-hostkey = {
        description = "Unseal initrd SSH host key from TPM2 credential (PCR 7)";
        wantedBy = [ "initrd-network.target" ];
        after = [ "systemd-udev-settle.service" ];
        before = [ "sshd.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        # util-linux for mount/umount; coreutils for mkdir/chmod/echo.
        # systemd-creds is available in PATH from the initrd's systemd installation.
        path = [ pkgs.util-linux pkgs.coreutils ];
        script = ''
          ESP_DEV="/dev/disk/by-partlabel/disk-main-ESP"
          CRED_PATH="/mnt/nixnas-esp/nixnas/initrd-hostkey.cred"
          mkdir -p /run/nixnas /mnt/nixnas-esp
          if ! mount -t vfat -o ro "$ESP_DEV" /mnt/nixnas-esp 2>&1; then
            echo "nixnas-unseal: cannot mount ESP ($ESP_DEV) — initrd-SSH unavailable"
            exit 1
          fi
          if [ ! -f "$CRED_PATH" ]; then
            umount /mnt/nixnas-esp
            echo "nixnas-unseal: no sealed blob (first boot) — initrd-SSH skipped; use serial/IPMI-SOL"
            exit 1
          fi
          ${systemdCreds} decrypt \
            --tpm2-device=auto \
            --name=nixnas-initrd-hostkey \
            "$CRED_PATH" \
            "${unsealedKeyPath}"
          umount /mnt/nixnas-esp
          chmod 600 "${unsealedKeyPath}"
          echo "nixnas-unseal: host key unsealed OK"
        '';
      };

      # Hard dependency: sshd requires the unseal service to have succeeded.
      # On first boot (unseal fails → no blob yet), sshd does not start — correct.
      # From the second boot, unseal succeeds → key is at ${unsealedKeyPath} → sshd starts.
      boot.initrd.systemd.services.sshd = {
        requires = [ "nixnas-unseal-hostkey.service" ];
        after = [ "nixnas-unseal-hostkey.service" ];
      };

      # ── Stage-2 seal service ──────────────────────────────────────────────────────────
      # Runs once, on first boot, after the store is mounted and the TPM2 is accessible.
      # ConditionPathExists uses the credential file as its own idempotency lock.
      systemd.services.nixnas-seal-hostkey = {
        description = "Generate + TPM2-seal the initrd SSH host key (first boot only)";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "sysinit.target" ];
        unitConfig.ConditionPathExists = "!/boot/nixnas/initrd-hostkey.cred";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        path = [ pkgs.systemd pkgs.openssh pkgs.coreutils ];
        script = ''
          echo "=== NIXNAS-SEAL-START ==="
          # Use a temp DIRECTORY so the key file does not exist yet when ssh-keygen
          # is called (mktemp creates the placeholder file, which triggers an
          # "Overwrite?" prompt if we passed it directly to ssh-keygen -f).
          tmpdir="$(mktemp -d -t nixnas-initrd-hostkey-XXXXXX)"
          tmpkey="$tmpdir/key"
          cleanup() {
            find "$tmpdir" -type f -exec shred -u {} \; 2>/dev/null || true
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT
          ssh-keygen -t ed25519 -N "" -C "nixnas-initrd-hostkey" -f "$tmpkey" -q
          mkdir -p /boot/nixnas
          systemd-creds encrypt \
            --tpm2-device=auto \
            --tpm2-pcrs=7 \
            --name=nixnas-initrd-hostkey \
            "$tmpkey" \
            /boot/nixnas/initrd-hostkey.cred
          chmod 600 /boot/nixnas/initrd-hostkey.cred
          echo "nixnas: initrd SSH host key sealed to /boot/nixnas/initrd-hostkey.cred"
          echo "=== NIXNAS-SEAL-END ==="
        '';
      };
    })
  ]);
}
