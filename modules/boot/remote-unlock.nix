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
#   The host key never touches the plaintext ESP; it rides as a TPM2-sealed systemd
#   CREDENTIAL, so systemd — not a hand-rolled service — does all the unseal plumbing.
#     1. FIRST BOOT (stage-2) `nixnas-seal-hostkey` generates an ed25519 key and seals it
#        with `systemd-creds encrypt --with-key=auto-initrd --tpm2-pcrs=7` straight to the
#        ESP's `\loader\credentials\nixnas-initrd-hostkey.cred` (a plain file write — /boot
#        is the mounted ESP). `auto-initrd` = TPM2-only key derivation, so the initrd (which
#        has no /var credential secret) can decrypt it.
#     2. EVERY SUBSEQUENT BOOT the lanzaboote stub scans `\loader\credentials\*.cred` and packs
#        them into the initrd (`.extra/global_credentials`). The initrd sshd unit carries
#        `LoadCredentialEncrypted=nixnas-initrd-hostkey`, so systemd inherits + TPM2-decrypts
#        the credential during sshd activation and drops the plaintext key in the unit's
#        $CREDENTIALS_DIRECTORY; sshd_config `HostKey` points there.
#   BOOTSTRAP CAVEAT: first boot has no credential yet → LoadCredentialEncrypted fails → sshd
#   does NOT start → operator uses serial console or IPMI-SOL for that one unlock. From the
#   second boot on, initrd-SSH is available. A tampered boot chain (PCR 7 mismatch) makes the
#   TPM refuse to release the key, so a stolen stick cannot impersonate the box's unlock prompt.
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

  # The host key travels as a TPM2-sealed *systemd credential*. Name is shared across the three
  # touch-points: the sealed file `<credName>.cred`, the `--name=` baked into the ciphertext, and
  # the sshd `LoadCredentialEncrypted=<credName>` that inherits + decrypts it.
  credName = "nixnas-initrd-hostkey";
  # The ESP's global credential drop-in dir (mounted at /boot in stage-2). lanzaboote's stub packs
  # \loader\credentials\*.cred into the initrd (.extra/global_credentials) on every subsequent boot.
  credEspPath = "/boot/loader/credentials/${credName}.cred";
  # Where systemd hands the DECRYPTED credential to the sshd unit ($CREDENTIALS_DIRECTORY).
  hostKeyCredPath = "/run/credentials/sshd.service/${credName}";
in
{
  config = lib.mkIf (cfg.enable && cfg.boot.remoteUnlock.enable) (lib.mkMerge [

    # ── Common: bring NIC up in the initrd for the remote unlock hand-off. ───────────────
    {
      assertions = [
        {
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
        }
        {
          # Path A's delivery vehicle is the LANZABOOTE stub: it is what scans
          # \loader\credentials\*.cred and packs the sealed key into the initrd. Plain
          # systemd-boot (no Secure Boot) boots kernel+initrd directly — no stub, no
          # credential, and initrd sshd would fail LoadCredentialEncrypted on EVERY boot.
          # Fail the build instead of shipping a silently-dead unlock path.
          assertion = sealActive -> cfg.boot.secureBoot.enable;
          message = ''
            nixnas.boot.remoteUnlock.sealHostKey = true requires nixnas.boot.secureBoot.enable:
            only the lanzaboote (UKI) stub delivers the TPM2-sealed host-key credential into
            the initrd. Enable Secure Boot, or set sealHostKey = false with a plaintext
            hostKeyPath, or set remoteUnlock.enable = false (IPMI-SOL/serial unlock).
          '';
        }
      ];

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

    # ── Path A: sealHostKey = true + crypto.tpm2.enable — TPM2-sealed key, delivered as a
    # systemd CREDENTIAL (no bespoke unseal service). See module header for the bootstrap.
    (lib.mkIf sealActive {

      # No static key in the initrd. sshd itself loads the TPM2-sealed credential the stub
      # delivered and systemd decrypts it during activation — the plaintext lands in the unit's
      # $CREDENTIALS_DIRECTORY, which we point HostKey at. ignoreEmptyHostKeys silences the
      # NixOS empty-hostKeys assertion. No ESP mount, no vfat/codepage modules, no unseal unit.
      boot.initrd.network.ssh.ignoreEmptyHostKeys = true;
      boot.initrd.network.ssh.extraConfig = "HostKey ${hostKeyCredPath}\n";

      # sshd inherits the stub-provided credential by name and TPM2-decrypts it (auto-initrd key).
      # On FIRST boot the credential does not exist yet ⇒ LoadCredentialEncrypted fails ⇒ sshd
      # does not start ⇒ the operator uses serial/IPMI-SOL for that one bootstrap unlock. From the
      # second boot the sealed .cred is on the ESP, the stub packs it in, and sshd comes up.
      boot.initrd.systemd.services.sshd.serviceConfig.LoadCredentialEncrypted = [ credName ];

      # ── Stage-2 seal service (first boot only) ────────────────────────────────────────
      # Generates the ed25519 key and TPM2-seals it into the ESP's loader/credentials/ dir with
      # `--with-key=auto-initrd` (TPM2-only key derivation — the /var credential secret is not
      # available in the initrd) bound to PCR 7 (Secure Boot state, update-stable). /boot is the
      # ESP, already mounted in stage-2, so this is a plain file write. The .cred file is its own
      # idempotency lock. From here on lanzaboote's stub auto-delivers it to every initrd.
      systemd.services.nixnas-seal-hostkey = {
        description = "Generate + TPM2-seal the initrd SSH host key credential (first boot only)";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "sysinit.target" ];
        unitConfig.ConditionPathExists = "!${credEspPath}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        path = [ pkgs.systemd pkgs.openssh pkgs.coreutils ];
        script = ''
          echo "=== NIXNAS-SEAL-START ==="
          # Temp DIRECTORY so the key file does not pre-exist (ssh-keygen -f would prompt).
          tmpdir="$(mktemp -d -t nixnas-initrd-hostkey-XXXXXX)"
          tmpkey="$tmpdir/key"
          cleanup() { find "$tmpdir" -type f -exec shred -u {} \; 2>/dev/null || true; rm -rf "$tmpdir"; }
          trap cleanup EXIT
          ssh-keygen -t ed25519 -N "" -C "${credName}" -f "$tmpkey" -q
          mkdir -p "$(dirname "${credEspPath}")"
          # --with-key=auto-initrd: seal to the TPM2 only (no /var secret), so the initrd can
          # decrypt it; --name must match the sshd LoadCredentialEncrypted= name; PCR 7 anchor.
          systemd-creds encrypt \
            --with-key=auto-initrd \
            --tpm2-device=auto \
            --tpm2-pcrs=7 \
            --name=${credName} \
            "$tmpkey" \
            "${credEspPath}"
          chmod 600 "${credEspPath}"
          echo "nixnas: initrd SSH host key sealed to ${credEspPath}"
          echo "=== NIXNAS-SEAL-END ==="
        '';
      };
    })
  ]);
}
