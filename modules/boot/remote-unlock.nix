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
#   BOOTSTRAP (first boot): the credential does not exist yet. systemd treats a MISSING
#   inherited credential as non-fatal (ID-only LoadCredentialEncrypted= is "missing_ok" —
#   skipped, not a unit failure), so sshd would launch, find no host key at all and die in a
#   restart loop ("sshd: no hostkeys available"). Instead, a preStart detects the empty
#   $CREDENTIALS_DIRECTORY and generates an EPHEMERAL ed25519 host key in the initrd's
#   RAM-backed rootfs (never persisted — the initrd fs is discarded at switch-root), served
#   with a LOUD SSH banner: the fingerprint is a throwaway and WILL CHANGE once
#   `nixnas-seal-hostkey` seals the real identity later that same boot. Remote unlock
#   therefore works on the VERY FIRST boot too — no monitor, no IPMI needed. SECURITY: a
#   credential that WAS delivered but fails to DECRYPT (tampered boot chain, PCR 7 mismatch)
#   still hard-fails the unit during credential setup — BEFORE the preStart — that lockout
#   is intentional. DELETING the .cred from the plaintext ESP, however, is indistinguishable
#   from a genuine first boot and DOES yield an ephemeral prompt — an inherent residual of
#   the first-boot fallback. The protection there is client-side: your known-hosts pin turns
#   the swapped fingerprint into a LOUD mismatch, never a silent accept.
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
  # The seal service drops the PUBLIC half beside the .cred for out-of-band verification.
  pubEspPath = "${lib.removeSuffix ".cred" credEspPath}.pub";

  # ── Path A first-boot fallback: EPHEMERAL host key, generated in the initrd. ──
  # Both paths live on the initrd's RAM-backed rootfs — discarded at switch-root, never
  # persisted anywhere. /etc/ssh already exists in the initrd (sshd_config lives there).
  ephemeralKeyPath = "/etc/ssh/nixnas_initrd_ephemeral_ed25519_key";
  bannerPath = "/etc/ssh/nixnas_initrd_banner";
  # Same openssh package whose sshd the nixpkgs initrd-ssh module copies in — reusing it
  # for ssh-keygen adds (almost) nothing to the initrd closure.
  sshPackage = config.programs.ssh.package;
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
                boot the initrd unseals it. The very first boot serves initrd-SSH with a
                loudly-flagged EPHEMERAL RAM-only host key (fingerprint changes once the
                sealed identity exists) — no monitor or IPMI needed even on boot #1.
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
          # credential, so the sealed key would never arrive and the first-boot fallback
          # would serve a DIFFERENT ephemeral key (with a bogus "first boot" banner) on
          # EVERY boot. Fail the build instead of shipping a permanently-unpinnable
          # unlock channel.
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
      # $CREDENTIALS_DIRECTORY, which the first HostKey points at. The second HostKey is the
      # first-boot EPHEMERAL fallback (generated by the preStart below); on every other boot
      # that file simply does not exist — sshd logs "Unable to load host key" for the absent
      # one and carries on with whichever is present. The Banner file is only written on the
      # ephemeral path; when it is absent sshd sends no banner (both behaviors verified against
      # a live sshd). ignoreEmptyHostKeys silences the NixOS empty-hostKeys assertion.
      # No ESP mount, no vfat/codepage modules, no unseal unit.
      boot.initrd.network.ssh.ignoreEmptyHostKeys = true;
      boot.initrd.network.ssh.extraConfig = ''
        HostKey ${hostKeyCredPath}
        HostKey ${ephemeralKeyPath}
        Banner ${bannerPath}
      '';

      # sshd inherits the stub-provided credential by name and TPM2-decrypts it (auto-initrd key).
      # Failure semantics (systemd, exec-credential.c) are load-bearing here:
      #   • credential DELIVERED + decrypts        → boot 2+ normal path, stable identity.
      #   • credential DELIVERED + decrypt FAILS   → tampered chain / PCR mismatch: the unit
      #     hard-fails during credential setup, before any ExecStartPre — NO ephemeral
      #     fallback, the box stays locked (intentional; a stolen stick cannot present a
      #     plausible unlock prompt).
      #   • credential MISSING (genuine first boot) → an ID-only LoadCredentialEncrypted= is
      #     "missing_ok": non-fatal, the unit starts with an empty $CREDENTIALS_DIRECTORY and
      #     the preStart below generates the ephemeral key + warning banner.
      boot.initrd.systemd.services.sshd.serviceConfig.LoadCredentialEncrypted = [ credName ];

      # make-initrd-ng copies listed objects + ELF library deps only — it does NOT chase
      # store references inside script text, so the ssh-keygen the preStart calls must be
      # listed explicitly (same pattern as the nixpkgs module's sshd binaries).
      boot.initrd.systemd.storePaths = [ "${sshPackage}/bin/ssh-keygen" ];

      # ── First-boot fallback: serve an EPHEMERAL host key rather than not serving at all.
      # nixnas must be unlockable without IPMI and without a monitor even on the very first
      # boot. The key lives on the initrd's RAM rootfs; nothing survives switch-root. Loud,
      # honest UX: the SSH banner (shown before authentication) says the fingerprint is a
      # throwaway and where to verify the real one from boot #2 on.
      boot.initrd.systemd.services.sshd.preStart = ''
        # Boot 2+: systemd decrypted the sealed credential — stable identity, nothing to do.
        if [ -s "''${CREDENTIALS_DIRECTORY:-/run/credentials/sshd.service}/${credName}" ]; then
          exit 0
        fi
        # GENUINE first boot: no credential was delivered by the stub. (A delivered-but-
        # undecryptable credential never reaches this script — see the comment above.)
        if [ ! -s ${ephemeralKeyPath} ] || [ ! -s ${ephemeralKeyPath}.pub ]; then
          rm -f ${ephemeralKeyPath} ${ephemeralKeyPath}.pub
          ${sshPackage}/bin/ssh-keygen -t ed25519 -N "" -C "nixnas-ephemeral-first-boot" \
            -f ${ephemeralKeyPath} -q
        fi
        fp="$(${sshPackage}/bin/ssh-keygen -lf ${ephemeralKeyPath}.pub)"
        {
          echo "=================================================================="
          echo " nixnas FIRST BOOT: initrd SSH is using an EPHEMERAL host key"
          echo "   $fp"
          echo " RAM-only, thrown away at switch-root. The fingerprint WILL"
          echo " CHANGE once the TPM-sealed identity is created later this boot"
          echo " (nixnas-seal-hostkey, right after you unlock). From the NEXT"
          echo " boot on, verify the new fingerprint against"
          echo "   ${pubEspPath}"
          echo " (also printed on console+journal by the seal service) and expect"
          echo " a one-time ssh known-hosts change warning — that one is expected."
          echo "=================================================================="
        } > ${bannerPath}
        echo "nixnas: FIRST BOOT - initrd sshd is serving an EPHEMERAL host key: $fp"
      '';

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
          # Surface the PUBLIC half (it is public — plaintext ESP is fine) so the operator can
          # VERIFY the first initrd-SSH connection instead of TOFU-accepting it: the .pub next
          # to the .cred, plus the fingerprint on journal+console. Without this the fingerprint
          # would be destroyed with the tmpdir and the unlock channel starts unverifiable.
          install -m 0644 "$tmpkey.pub" "${pubEspPath}"
          echo "nixnas: initrd SSH host key fingerprint (verify this on your first initrd-SSH connect):"
          ssh-keygen -lf "$tmpkey.pub"
          echo "nixnas: initrd SSH host key sealed to ${credEspPath} (public key beside it)"
          echo "=== NIXNAS-SEAL-END ==="
        '';
      };
    })
  ]);
}
