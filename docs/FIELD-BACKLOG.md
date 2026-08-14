# Field backlog — product items from real deployments

Every entry is a lesson from a REAL boot on REAL hardware, not a speculative feature.
Items graduate out of this file when they land as code + a test. (The first real-hardware
deployment produced the console flip, the 5s menu, the grow-unit removal, the auth
module, the failed-units CI gate, and the first-boot SSH bootstrap problem — this file
tracks what that session surfaced but did not yet land.)

## 1. networkd everywhere (drop dhcpcd in stage 2) — LANDED
**Evidence:** the initrd uses systemd-networkd (remote-unlock), stage 2 uses NixOS's
default dhcpcd. On first boots the stage-2 dhcpcd repeatedly failed its first start
(`[FAILED] Failed to start DHCP Client`, later self-healed) while the initrd lease kept
answering pings — two DHCP stacks, one interface, avoidable flake class.
**Fix:** `networking.useNetworkd = true` as the nixnas default; one stack from initrd
to stage 2, native lease handover. Multi-NIC guidance (bond/deactivate) in the docs —
two NICs on one LAN made the DHCP server juggle leases across boots and the NICs
ARP-fight each other (frozen SSH mid-command).
**Landed:** `networking.useNetworkd = mkDefault true;` in `modules/appliance/base.nix:27`
(the module's own comment cites this item by number) — commit `7155a5b` (2026-07-04),
the same commit that landed item #4.

## 2. Store-unlock prompt must not 90s-timeout into emergency — LANDED
**Evidence:** a slow-POST server (~15 min) plus an unanswered LUKS prompt = the
cryptsetup job times out after ~90 s → emergency mode → on a fresh image the emergency
shell is LOCKED (no root credential) → total lockout. Recovery required knowing the
"press Enter → jobs retry → fresh prompt" trick.
**Fix:** generous/infinite password-wait for the store unlock (the box is useless
without it anyway — waiting IS the correct behavior), so a human arriving minutes
later still gets the prompt, not a dead box. Needs a QEMU test: prompt unanswered for
>5 min, then answered → boot completes.
**Landed:** `x-systemd.device-timeout=0` on both the `cryptstore` crypttab entry and the
`/nix` mount options (`modules/boot/disk.nix:93-94`, `FIELD-BACKLOG #2` in its own
comment; the hot-mode equivalent is `modules/store/location.nix:125,151`) — commit
`7155a5b` (2026-07-04), the same commit that landed item #4. The queued QEMU test
(prompt unanswered for minutes, then answered) has not been added — `test/failure-
injection-test.sh`'s `pool-absent` case covers a genuinely absent device (which is
still expected to hit the 90 s device-timeout by design), not an unanswered password
prompt on a present device.

## 3. Preload must not starve the box (IO scheduling) — LANDED
**Evidence:** `store.preload` (warming the closure into the compressed page cache)
reads the whole closure from a ~5 MB/s stick right after boot/switch; during that
window interactive use starves — SSH connections accept but shells take >30 s to exec.
On a rescue system this is exactly when an operator needs the box responsive.
**Fix:** run the preload unit with `IOSchedulingClass=idle` (+ lowest CPU weight);
warming is a background optimization and must never compete with the operator.
**Landed:** `nixnas-store-preload` sets `IOSchedulingClass = "idle"`,
`CPUSchedulingPolicy = "idle"`, and `Nice = 19` (`modules/appliance/optimizations.nix:98-99`)
— commit `7155a5b` (2026-07-04), the same commit that landed item #4.

## 4. Activation must survive connection loss (detached switch) — LANDED
**Evidence:** a `switch-to-configuration switch` carried over a plain SSH session was
killed mid-flight when the network flapped — getty had already restarted but user
activation had not run yet: a HALF-activated system (login rejects everyone). The fix
in the field was re-running the switch under `systemd-run` (detached, session-immune).
**Fix:** ship `nixnas-switch` (a thin wrapper: `systemd-run --unit=… switch-to-
configuration <mode>` + result reporting) and use it in activation paths; document "never run
activation through a droppable session".
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
README now says "never run activation through a droppable session".

## 5–7. Legacy per-host rescue/install path — REMOVED

The old firmware-lean per-host rescue, its maintainer, and the blank-root installer were removed.
Fleet recovery is now the separate, broadly compatible nixrescue role; these historical field
issues are no longer actionable nixnas backlog.

## 8. TPM seal must survive SB key enrollment (self-heal) — LANDED
**Evidence (first real deployment):** the initrd-SSH host key is sealed on first
boot with `systemd-creds encrypt --tpm2-pcrs=7`, but Secure Boot key enrollment
(`nixnas-enroll-sb`, a deliberate MANUAL step) runs AFTER that seal and **changes PCR 7**. On
the next boot the sealed `.cred` no longer decrypts. Two things then compounded into a hard
brick:
  1. the seal service's only idempotency gate was `ConditionPathExists=!…/nixboot-initrd-hostkey.cred`
     — it keyed off the file merely EXISTING, so a stale, undecryptable `.cred` permanently
     blocked the one code path that could re-bind the key to the new PCR 7. It **never re-sealed**;
  2. the initrd sshd (`Restart=on-failure` by nixpkgs default) retried its failed credential
     setup, each retry firing another TPM2 unseal. This hammered the AMD fTPM into
     **dictionary-attack lockout** (`inLockout=1` →
     `TPM_RC_LOCKOUT`/0x921), which then failed `systemd-tpm2-setup`'s SRK provisioning.
  Manual field remedy was: `tpm2_dictionarylockout --clear-lockout`, `rm` the stale `.cred`, and
  `systemctl start nixboot-seal-hostkey` to re-seal against the new PCR 7.
**Fix (LANDED):** `nixboot-seal-hostkey` is now **self-healing** — it runs every boot with no
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
`test/seal-3boot-test.sh` (boot #3 re-runs the seal: valid cred self-tests OK → skip → stable
fingerprint) and `test/verify-sealed-hostkey.nix`.
**Root simplification:** nixnas no longer supports a TPM-bound LUKS keyslot. TPM is reserved for
this SSH identity; every disk always requires the operator's passphrase. Consequently a stale
credential can only remove remote unlock for one boot, never interfere with disk decryption.
