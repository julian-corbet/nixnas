# Field backlog — product items from real deployments

Every entry is a lesson from a REAL boot on REAL hardware, not a speculative feature.
Items graduate out of this file when they land as code + a test. (The first deployment,
2026-07-04, produced the console flip, the 5s menu, the grow-unit removal, the auth
module, the failed-units CI gate, and the ephemeral first-boot SSH key — this file
tracks what that session surfaced but did not yet land.)

## 1. networkd everywhere (drop dhcpcd in stage 2)
**Evidence:** the initrd uses systemd-networkd (remote-unlock), stage 2 uses NixOS's
default dhcpcd. On first boots the stage-2 dhcpcd repeatedly failed its first start
(`[FAILED] Failed to start DHCP Client`, later self-healed) while the initrd lease kept
answering pings — two DHCP stacks, one interface, avoidable flake class.
**Fix:** `networking.useNetworkd = true` as the nixnas default; one stack from initrd
to stage 2, native lease handover. Multi-NIC guidance (bond/deactivate) in the docs —
two NICs on one LAN made the DHCP server juggle leases across boots and the NICs
ARP-fight each other (frozen SSH mid-command).

## 2. Store-unlock prompt must not 90s-timeout into emergency
**Evidence:** a slow-POST server (~15 min) plus an unanswered LUKS prompt = the
cryptsetup job times out after ~90 s → emergency mode → on a fresh image the emergency
shell is LOCKED (no root credential) → total lockout. Recovery required knowing the
"press Enter → jobs retry → fresh prompt" trick.
**Fix:** generous/infinite password-wait for the store unlock (the box is useless
without it anyway — waiting IS the correct behavior), so a human arriving minutes
later still gets the prompt, not a dead box. Needs a QEMU test: prompt unanswered for
>5 min, then answered → boot completes.

## 3. Preload must not starve the box (IO scheduling)
**Evidence:** `store.preload` (warming the closure into the compressed page cache)
reads the whole closure from a ~5 MB/s stick right after boot/switch; during that
window interactive use starves — SSH connections accept but shells take >30 s to exec.
On a rescue system this is exactly when an operator needs the box responsive.
**Fix:** run the preload unit with `IOSchedulingClass=idle` (+ lowest CPU weight);
warming is a background optimization and must never compete with the operator.

## 4. Activation must survive connection loss (detached switch) — LANDED (commit pending)
**Evidence:** a `switch-to-configuration switch` carried over a plain SSH session was
killed mid-flight when the network flapped — getty had already restarted but user
activation had not run yet: a HALF-activated system (login rejects everyone). The fix
in the field was re-running the switch under `systemd-run` (detached, session-immune).
**Fix:** ship `nixnas-switch` (a thin wrapper: `systemd-run --unit=… switch-to-
configuration <mode>` + result reporting) and use it in docs/auto-upgrade/
rescue-maintain paths; document "never run activation through a droppable session".
**Landed:** `modules/appliance/switch.nix` ships
`nixnas-switch [switch|boot|test] [--generation <store-path>]` on both usb and hot
systems: detached activation via `systemd-run --no-block --collect` (PID-1-owned —
`--no-block` because a plain oneshot start blocks the client until completion),
journal follow + honest `Result=` reporting (an ExecStopPost hook persists
`$SERVICE_RESULT`/`$EXIT_STATUS` — after `--collect` GC, `systemctl show` falsely
reports success even for a failed run), refusal while any nixnas-switch unit is
loaded, and stale `/run/nixos/switch-to-configuration.lock` cleanup ONLY when the
lock is flock'd but no switch process is alive (the exit-11 retry blocker: an
orphaned inherited fd — deleting the file gives stc a fresh inode). auto-upgrade and
rescue-maintain already run inside systemd units, i.e. detached by construction; the
README now says "never run activation through a droppable session".

## 6. TPM seal must survive SB key enrollment (self-heal) — LANDED
**Evidence (2026-07-04, first real deployment):** the initrd-SSH host key is sealed on first
boot with `systemd-creds encrypt --tpm2-pcrs=7`, but Secure Boot key enrollment
(`nixnas-enroll-sb`, a deliberate MANUAL step) runs AFTER that seal and **changes PCR 7**. On
the next boot the sealed `.cred` no longer decrypts. Two things then compounded into a hard
brick:
  1. the seal service's only idempotency gate was `ConditionPathExists=!…/nixnas-initrd-hostkey.cred`
     — it keyed off the file merely EXISTING, so a stale, undecryptable `.cred` permanently
     blocked the one code path that could re-bind the key to the new PCR 7. It **never re-sealed**;
  2. the initrd sshd (`Restart=on-failure` by nixpkgs default) retried its failed credential
     setup, each retry firing another TPM2 unseal; together with the store keyslot's own failed
     PCR-7 unseal this hammered the AMD fTPM into **dictionary-attack lockout** (`inLockout=1` →
     `TPM_RC_LOCKOUT`/0x921), which then failed `systemd-tpm2-setup`'s SRK provisioning.
  Manual field remedy was: `tpm2_dictionarylockout --clear-lockout`, `rm` the stale `.cred`, and
  `systemctl start nixnas-seal-hostkey` to re-seal against the new PCR 7.
**Fix (LANDED):** `nixnas-seal-hostkey` is now **self-healing** — it runs every boot with no
`ConditionPathExists` gate and decides in-script via a real **decrypt self-test**
(`systemd-creds decrypt … "$cred" - >/dev/null`): valid → do nothing (fingerprint unchanged);
missing OR undecryptable → (re)generate + (re)seal, overwriting `.cred`/`.pub` and printing the
new fingerprint loudly (operator re-pins, one expected known-hosts warning). Correctness:
firmware extends PCR 7 before the bootloader and does not re-extend it between stage-1 and
stage-2, so a stage-2 decrypt success guarantees the stage-1 initrd-sshd unseal succeeds next
boot; a stale cred costs exactly ONE failed unseal, then heals. To stop the lockout hammer
(which would otherwise also defeat the self-heal — its `systemd-creds encrypt` needs the TPM
too), the initrd sshd is pinned to `Restart = mkForce "no"`: a delivered-but-undecryptable cred
fails once, sshd stays down for that single physically-present enrollment boot (console prompt
still there), and stage-2 re-seals for the next boot. Anti-downgrade semantics unchanged (still
no ephemeral fallback for a delivered cred). The misleading "PCR 7 is update-stable; no reseal"
comment (remote-unlock.nix, options.nix ×2, ARCHITECTURE §6) is corrected to name SB enrollment
as the one PCR 7 delta. `modules/boot/remote-unlock.nix`; covered by the existing
`test/seal-2boot-test.sh` (boot #2 re-runs the seal: valid cred self-tests OK → skip → stable
fingerprint) and `test/verify-sealed-hostkey.nix`.
**Follow-up (store keyslot parity):** the STORE LUKS keyslot (`modules/crypto/tpm2.nix`,
`tpm2-device=auto`, PCR 7) has the identical staleness — after SB enrollment its TPM2 unseal
also fails (store still opens via the passphrase slot, but it feeds the same DA counter each
boot). `nixnas-enroll-tpm2` is already idempotent (`--wipe-slot=tpm2`), so the fix is to RE-RUN
it after enrollment + reboot; this is now documented in `options.nix` and the `nixnas-enroll-sb`
success message. A box-side read-only warning unit (analogous to `nixnas-recovery-status`) that
flags a store keyslot that no longer unseals is the remaining not-yet-landed piece — untestable
in the keyless demo (no TPM2 store slot is enrolled there), so it is tracked here rather than
shipped blind.

## 5. Rescue firmware posture (document, not change)
**Evidence:** the rescue boots a discrete GPU host with `amdgpu … Fatal error during
GPU init` (no firmware on the stick). Correct for the rescue (closure budget; BMC
graphics is the console) but it LOOKS alarming on the console and cost triage time.
**Fix:** docs (HOT-MODE/README): the rescue is deliberately firmware-lean; GPU errors
on its console are expected on dGPU hosts; the MAIN host config carries
`hardware.enableRedistributableFirmware`.

## 6. install-hot needs nix-command enabled (field-hit 2026-07-04)
**Evidence:** `nixnas-install-hot` runs `nix copy --to "$target"` (a nix-command call), but the
rescue's nix.conf did not have `experimental-features = nix-command` — so the install aborted
`error: experimental Nix feature 'nix-command' is disabled`. Worked around with
`NIX_CONFIG='experimental-features = nix-command flakes' nixnas-install-hot …`.
**Fix:** either the rescue (usb-mode) nix config enables `nix-command` by default (it ships
`nixnas-install-hot`, which requires it), or install-hot invokes `nix copy` with
`--extra-experimental-features nix-command` itself. The latter is more robust (self-contained).

## 7. install-hot must place the console auth hash on the hot store (field-hit 2026-07-04)
**Evidence:** the MAIN's install warned `password file '/nix/nixnas/auth/passphrase.hash' does
not exist` — the auth module points root/admin at that runtime file (modules/appliance/auth.nix),
but only the TUI image build writes it (usb images); install-hot never seeds it onto the hot
store, so the MAIN's CONSOLE login is fail-closed locked (SSH-key still works). Worked around by
writing the yescrypt hash to `hot/system/nix` `…/nixnas/auth/passphrase.hash` (0600) by hand
before the reboot.
**Fix:** install-hot should seed the auth hash onto the hot store the same way it seeds the SB
PKI (step 3) — either copy the operator-provided hash, or (cleaner) let the MAIN config carry an
inline `hashedPassword` for the hot mode where the TUI file mechanism doesn't apply. Reconcile
the auth module (hashedPasswordFile) vs an inline hashedPassword so hot systems aren't locked.
