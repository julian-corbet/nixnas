# nixnas — MIGRATE-HOT-ROOT.md: moving a LIVE `hot`-mode host onto a persistent root

**This is a runbook, not a tool.** No automation exists for this — `nixnas-install-hot`
(`modules/appliance/install-hot.nix`) only targets a **blank** root device via the rescue
environment; it has no notion of "a box that is already running, right now, on a tmpfs
root, and must keep its identity across the switch." This document is what a human follows
by hand. It is deliberately **not executed by an agent**: the final step is a reboot, and a
reboot of a live `hot`-mode host is its own separate, explicit human decision — no amount of
proof at the earlier stages substitutes for standing by the console (or initrd-SSH) when it
actually happens.

## Why this exists

Before this change, `store.location = "hot"` gave the MAIN system a **tmpfs root** — see
`docs/ARCHITECTURE.md` §3 (pre-this-change) and `docs/HOT-MODE.md`. In practice, on a host
that runs for months, that is not "impermanence" in the disciplined sense the `usb`-mode
appliance relies on (small, all state routed through `persist.*`, enforced at build time by
`modules/appliance/persist-enforce.nix`) — it's an easy way to lose a file nobody thought to
declare. Concretely, on a real long-running box: an SSH backup key placed directly under
`/root` or `/etc` (never a systemd `StateDirectory`, so the build-time gate never sees it,
and never listed in `persist.overlayClients`) vanished on reboot — **three separate times**.
A `sops` age key met the same fate and sat silently broken for **twelve days** before anyone
tried to decrypt something and found every secret in the vault undecryptable.

The build-time gate this repo already has (`persist-enforce.nix`) catches services that
declare `StateDirectory=` and forget to route it. **It cannot catch a file a human just
copied somewhere.** That is the gap only a real, ordinary, persistent root closes — which is
why the fix is architectural (delete the tmpfs root, require `store.root.device`), not one
more thing to add to a persistence list. This runbook exists because a host provisioned
*before* that fix is still running on the ephemeral model it describes, and moving it needs
care specifically **because** the failure mode is "we don't know everything that's on there."

## The shape of the migration

Nothing here is exotic: create a new dataset, copy the current root's actual contents onto
it (not a fresh install — this box has been running and has real, uninventoried state),
point the config at it, stage a new generation, and reboot into it with the OLD generation
kept as the rollback target. The risk is entirely in step 3 (what do we actually have to
carry over) and step 7 (the reboot itself); every other step is inspectable and reversible
without touching the running system.

---

### Stage 0 — Preconditions (no risk, read-only)

- The host is a `hot`-mode nixnas (`nixnas.store.location = "hot"`) on an UNMODIFIED nixnas
  version older than this change (i.e. it still evaluates `modules/store/location.nix`'s
  tmpfs `fileSystems."/"` block — check `nixos-rebuild list-generations` / the flake input
  pin nixnas was built against).
- You have console access OR a working `boot.remoteUnlock` (initrd-SSH) — the reboot in
  Stage 7 needs the SAME operator-key entry this host already requires for `store.hot.*`,
  now also gating the new root device.
- The pool backing `store.hot.device` has room for a new dataset/device sized for the
  CURRENT root's actual usage (Stage 1 tells you how much) plus headroom — this is normal
  system state (`/etc`, `/var/lib/*`, users, logs if `store.persistLogs` was ever flipped
  on), not the multi-GB store closure.

**Gate to proceed to Stage 1:** none — this stage is inspection only.

### Stage 1 — Inventory: what is actually on the running root right now

The whole point of this migration is that **nobody has a complete list of what's on this
tmpfs root** — that is exactly the failure class being fixed. Enumerate it directly from the
live system rather than trusting `persist.overlayClients` or any StateDirectory list:

```
# Everything on the running root, EXCLUDING the always-mounted-elsewhere paths
# (adjust the -path exclusions to match this host's actual fileSystems entries):
find / -xdev \
  -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' -not -path '/run/*' \
  -not -path '/nix/*' -not -path '/boot/*' \
  -printf '%y %m %U:%G %s\t%p\n' > /tmp/live-root-inventory.txt

# Total bytes at risk (sizes this dataset must actually hold):
du -sx --exclude=/nix --exclude=/boot --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run / 2>/dev/null
```

`-xdev` stops `find` at filesystem boundaries, so anything ALREADY on a real mount (a bind
from `/nix/persist`, an operator's own `fileSystems` entry) is correctly excluded here — the
output is precisely the set of files that exist **only** on the tmpfs and would be silently
gone on the next reboot if this migration did not happen. Read this list. Specifically look
for anything under `/root`, `/home`, `/etc` that is not a symlink into `/nix/store` and not
one of the paths `modules/appliance/identity.nix` already manages — that is where a hand-
placed SSH key or an age key file will be.

**Gate to proceed to Stage 2:** the inventory has been read by a human, and the operator
knows, by name, every file that Stage 3's copy must not lose. No amount of tooling
substitutes for actually looking at this list once — that is the check this whole runbook
exists to force.

### Stage 2 — Create the new root dataset/device (storage prep, non-destructive)

Same contract as `store.hot.device` (`docs/HOT-MODE.md` step 0): nixnas never formats — this
is the operator's own action, on their own already-unlocked pool.

```
# ZFS example — a sibling dataset of the existing hot store, same pool.
# Either mount shape works; declare the one you pick with store.root.zfsMountpoint.
zfs create -o mountpoint=legacy <pool>/system/root                    # zfsMountpoint = "legacy"
zfs create -o mountpoint=/ -o canmount=noauto <pool>/system/root      # zfsMountpoint = "property"

# Non-ZFS example — a new LUKS member + filesystem on a spare partition/volume:
cryptsetup luksFormat /dev/disk/by-id/<new-member>
cryptsetup open /dev/disk/by-id/<new-member> nixroot
mkfs.ext4 -L nixroot /dev/mapper/nixroot
```

This step touches only NEW, previously-unused storage. It does not modify the running
system, the existing store dataset, or anything currently mounted.

> **Converting an EXISTING dataset from `legacy` to `property` is a two-step operation.**
> A plain `zfs set mountpoint=/ <dataset>` MOUNTS IT IMMEDIATELY at the new location —
> which for a root dataset means over the running system's `/`. Set `canmount=noauto`
> first, then use `zfs set -u` (update the property, do not mount):
>
> ```
> zfs set canmount=noauto <pool>/system/root
> zfs set -u mountpoint=/ <pool>/system/root
> ```
>
> Verify with `zfs list` that it reports `noauto` and is NOT mounted before continuing.

**Observable proving this stage:** `zfs list <pool>/system/root` shows `mountpoint legacy`,
or a real mountpoint with `canmount noauto` and `mounted no` for the `property` shape
(ZFS case); or `blkid /dev/mapper/nixroot` shows the new filesystem (device case). Nothing
else on the host changed — `mount` output for the running system is identical to before
this stage.

**Gate to proceed to Stage 3:** the new dataset/device exists and is confirmed empty
(`zfs list -o used,avail <pool>/system/root` shows ~0 used; the new filesystem was never
mounted before this run). Human confirms before any data touches it.

### Stage 3 — Copy the running root's real content onto the new device

Mount the new device at a scratch path and copy the running system onto it. This is a COPY,
never a move and never a deletion of anything on the live root — per house rule, verify-and-
delete is always separate from copy, and nothing gets deleted in this runbook at all.

```
mkdir -p /mnt/newroot
mount -t zfs <pool>/system/root /mnt/newroot   # or: mount /dev/mapper/nixroot /mnt/newroot

# Cross filesystem boundaries deliberately (do NOT pass -x/--one-file-system): any Tier-1
# bind mount from /nix/persist (modules/appliance/identity.nix, still active on THIS
# pre-migration generation) must be followed through so its real content lands on the new
# root too, not just an empty mount-point directory.
rsync -aAX --numeric-ids \
  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
  --exclude=/nix --exclude=/boot --exclude=/mnt/newroot \
  / /mnt/newroot/
```

**Observable proving this stage:** re-run Stage 1's `find … -printf` against
`/mnt/newroot` (with the same exclusions, paths rewritten) and diff the two listings —
every path from the live inventory must appear in the copy with matching size and
ownership. Specifically confirm, BY NAME, that the exact files flagged as at-risk in Stage 1
are present (this is where an SSH backup key or a sops age key gets a human's eyes on it a
second time, not just rsync's).

**Gate to proceed to Stage 4:** the diff is clean (or every discrepancy is explained and
accepted by a human) and the specific at-risk files from Stage 1 are confirmed present,
byte-for-byte, on the new root.

### Stage 4 — Point the config at the new root; clear the now-obsolete `persist.*` options

In the host's own config (the private overlay repo that imports `nixnas.nixosModules.nixnas`
— see `docs/REPO-LAYOUT.md`):

```nix
nixnas.store.root = {
  device = "<pool>/system/root";   # or "/dev/mapper/nixroot"
  fsType = "zfs";                  # or "ext4" / whatever Stage 2 formatted
  # zpool = "<pool>";              # only if it does not derive from device
  # unlock.<name> = "/dev/disk/by-id/...";  # only if root's members differ from store.hot.unlock
};

# These are usb-mode-only concepts and modules/store/location.nix now REFUSES a hot-mode
# host that still sets either one non-empty — clear whatever this host had:
nixnas.persist.overlayClients = [ ];
nixnas.persist.explicitlyEphemeral = [ ];
```

Build (do not deploy yet) against the CURRENT running generation's inputs, to prove the
config is valid before anything about the live system changes:

```
nixos-rebuild build --flake .#<hostname>
```

**Observable proving this stage:** the build succeeds and prints a `result` symlink to a
toplevel `drvPath`. If `store.root.device` were left unset, this step would fail LOUDLY at
EVALUATION with `modules/store/location.nix`'s own named assertion — that is the proof this
whole refactor was built to produce; see this repo's own CI (`checks.x86_64-linux.demo-hot-
toplevel`) for the same assertion firing against the public demo host.

**Gate to proceed to Stage 5:** the build is green. Nothing has been staged onto the boot
menu yet, and nothing about the running system has changed.

### Stage 5 — Stage the new generation (no reboot, no activation)

```
nixos-rebuild boot --flake .#<hostname>
```

`boot` (never `switch`, never `test`) registers the new generation — its signed UKI on the
shared ESP, `fileSystems."/"` pointing at the new device — as the **default next-boot
entry**, without touching the currently running system at all. The box keeps running,
unmodified, on its old tmpfs-root generation until it is next rebooted.

**Observable proving this stage:** `bootctl list` (or the equivalent for this host's loader)
shows the new generation's entry as default; `nixos-rebuild list-generations` shows it
present. `mount` on the LIVE system is still unchanged — still tmpfs root, still the old
generation's kernel running.

**Gate to proceed to Stage 6:** the new generation is confirmed staged and its own eval
(Stage 4) already proved it builds with the persistent root wired in.

### Stage 6 — The separate, explicit human go for the reboot itself

Everything above this line is inspectable and reversible without a reboot. This line is not.
**Do not proceed past here without a fresh, explicit go from the operator, given AT this
point** — momentum from the earlier stages does not carry (per house rule: every destructive
or irreversible stage gets its own explicit go, not a blanket one from the start of the
runbook). Confirm, out loud, before rebooting:

- console or initrd-SSH access is confirmed reachable RIGHT NOW, not "was reachable
  earlier" — this is the same operator-key entry the box already requires today for
  `store.hot.device`, now ALSO gating the new root device, over the SAME one-passphrase
  chain (`modules/store/location.nix`'s serialised unlock — one entry still opens
  everything, this migration does not add a second prompt);
- Stage 3's copy-and-diff is the last state this reboot will see — any change made to the
  LIVE root after Stage 3 and before the reboot is NOT on the new root and will appear to
  vanish (this is the one place "verify, then immediately act" matters — a long gap between
  Stage 3 and Stage 6 re-opens exactly the risk this migration exists to close);
- the OLD generation is confirmed still present and selectable in the boot menu (Stage 7's
  rollback path).

### Stage 7 — Reboot, observe, verify identity

Reboot the host. At the initrd prompt, enter the operator passphrase exactly as before
(nothing about the unlock UX changes — `store.root.unlock`, if set, rides the same chain as
`store.hot.unlock`). The box mounts the new persistent root, switch-roots, and comes up.

**Observable proving success — check ALL of these, not just "it came up":**

- `mount | grep ' / '` shows the NEW device/dataset, not tmpfs.
- Every file flagged in Stage 1 is present at its expected path, with expected content — in
  particular, re-verify the SPECIFIC files this migration exists to protect (an SSH key's
  fingerprint matches what it was pre-migration; a `sops` age key actually decrypts a known
  secret). This is the actual regression test for the twelve-day-silent-failure incident.
- A second, cosmetic reboot (once you're confident) shows the state is IDENTICAL to the
  first post-migration boot — proving persistence, not just a lucky first landing.

**If it fails to reach login:** select the OLD generation from the boot menu. Because Stage
5 used `nixos-rebuild boot` (never activated the new generation on the running system), the
old generation is a complete, self-contained, unmodified system — it boots exactly as it did
before this migration started, tmpfs root and all. The new root dataset/device from Stage 2
is simply left unused; nothing about it needs cleaning up before retrying (diagnose the
failure, fix the config, repeat from Stage 4's build check).

### Stage 8 — Cleanup (only after Stage 7 is confirmed stable)

Once the new root has survived at least one deliberate extra reboot cleanly: the OLD
tmpfs-root generations can be pruned by the normal `boot.keepGenerations` / GC mechanism —
no special action needed, they aren't referencing anything the new root depends on. There is
nothing on the new root to clean up; it is the box's real, ordinary state now.

---

## Summary table

| Stage | Risk | Reversible? | Gate |
|---|---|---|---|
| 0. Preconditions | none | — | none |
| 1. Inventory | none (read-only) | — | human reads the list |
| 2. Create new dataset/device | none (unused storage) | trivially (destroy the unused dataset) | confirmed empty |
| 3. Copy + diff | none (copy only, no deletion) | trivially (re-copy) | diff clean + at-risk files confirmed present |
| 4. Point config + build | none (build only) | trivially (revert the config edit) | build green |
| 5. Stage generation (`boot`) | none (not activated) | trivially (don't reboot into it) | generation confirmed staged |
| 6. Explicit human go | — | — | fresh, separate confirmation, not inherited momentum |
| 7. **Reboot** | **real — the box may not come back up on the first try** | **yes — old generation is untouched and selectable** | operator physically present / reachable over initrd-SSH |
| 8. Cleanup | none | — | Stage 7 confirmed stable across ≥2 boots |
