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

## 5. Rescue firmware posture (document, not change)
**Evidence:** the rescue boots a discrete GPU host with `amdgpu … Fatal error during
GPU init` (no firmware on the stick). Correct for the rescue (closure budget; BMC
graphics is the console) but it LOOKS alarming on the console and cost triage time.
**Fix:** docs (HOT-MODE/README): the rescue is deliberately firmware-lean; GPU errors
on its console are expected on dGPU hosts; the MAIN host config carries
`hardware.enableRedistributableFirmware`.
