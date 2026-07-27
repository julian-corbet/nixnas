# studies

Written-up findings: things that were measured (in CI, in the field, or against a
real device) and are worth recording properly — with the evidence and its source,
not just the headline number. A study earns its place here once it is reproducible
and changed (or confirmed) a decision in the main project. See
[`../experiments/README.md`](../experiments/README.md) for the open questions this
repo has *not* yet settled this way, and the main [README](../README.md) for the
project itself.

**Nothing in this file is invented.** Every number below is quoted or paraphrased
from a source already in this repo (a doc, a module comment, or a CI workflow) —
follow the citation to see it in context.

## Contents

1. [What `test/` + CI actually prove, and what QEMU structurally cannot](#001)
2. [The f2fs release-cblocks pass reclaims real, measured space](#002)
3. [Kept-generation ESP cost is dominated by shared kernel+initrd, not per-generation stubs](#003)
4. [Impermanence collapses stick writes to near-zero](#004)

---

<a id="001"></a>
## 001 — What `test/` + CI actually prove, and what QEMU structurally cannot

**Claim:** nixnas's boot-chain claims are not aspirational — they run on every push
and weekly, on GitHub's KVM-capable public runners, and the pass/fail criteria are
concrete (a login prompt reached, or a login prompt deliberately *not* reached).

**What is proven, on every push** (`.github/workflows/boot-test.yml`):
- `test/seal-2boot-test.sh` (positive): the demo image boots twice against one
  persistent swtpm state dir; boot #1 seals the initrd-SSH host key to the TPM
  (PCR 7), boot #2's initrd unseals it, brings up initrd-SSH, and the store unlocks
  over the network to a login prompt. This is a genuine two-boot power-cycle proof,
  not a single-boot smoke test.
- `test/seal-2boot-test.sh --tamper`: the same flow against a *fresh* swtpm (wrong
  TPM) — the unseal must fail and sshd must never come up. Pass condition is a
  **non**-unlock; this is the fail-closed proof.
- `test/hot-boot-test.sh`, twice (serial-primary and video-primary
  `consolePrimary` variants): a HOT-mode MAIN boots `/nix` from an external,
  operator-key-unlocked LUKS device via direct kernel boot, reaching login on the
  operator's passphrase alone; the second run confirms the LUKS prompt still
  appears on the serial log under the video-primary console default (SOL/serial
  users are not silently locked out).
- `test/hot-boot-zfs-test.sh`: the ZFS variant of the above — two LUKS-encrypted
  ZFS vdevs, one passphrase (systemd's password cache serialises the second
  member), pool import in the initrd, dataset mounted at `/nix`. If the second
  member never opened, `zpool import` itself would fail — the pool geometry proves
  the single-entry unlock, not just an assertion.
- `test/matrix-eval-test.sh`: eval-only (no QEMU) proof across six operator-persona
  variants (no-tpm / stick-4·16·32g / hot-ext4 / pin-strict / persist-nested) —
  option wiring and assertion guards, not boot behaviour.

**What is proven, weekly (or on `test/**` changes)** (`.github/workflows/deep-test.yml`):
- `test/lifecycle-test.sh`: the full rescue → `nixnas-install-hot` → main boot →
  rescue-only cycle, three real boots in sequence.
- `test/failure-injection-test.sh power-cut-mid-write`: a live `kill -9` on QEMU
  mid-write into `/nix`, then reboot — f2fs must recover from its checkpoint and
  reach login without operator repair.
- `test/failure-injection-test.sh pool-absent`: a HOT-mode MAIN direct-booted with
  its store disk *not attached* — the initrd must stall waiting for the missing
  LUKS device, never silently proceed.
- `test/failure-injection-test.sh no-tpm`: the demo image boots with no TPM device
  exposed to the guest — the LUKS passphrase prompt must still surface on serial
  (no hard TPM dependency).
- `test/upgrade-soak-test.sh`: N=5 successive generation upgrades against
  `keepGenerations=3`, asserting (a) the newest generation actually boots, (b) ESP
  UKI count tracks `min(cycle+1, 3)` — i.e. lanzaboote's own GC evicts old UKIs once
  the window fills, (c) `bootctl list` agrees, (d) per-cycle `/nix/store` growth
  stays bounded.

**What none of the above can prove — QEMU/swtpm is not the target hardware:**
- Real UEFI firmware behaviour: the firmware setup password and the
  boot-counting **bless** step (see [`../experiments/README.md`](../experiments/README.md#003)
  — the VM already showed bless running but *not* clearing the counter in the
  SB-off OVMF case).
- Real PCR values: `test/README.md` states this directly — "swtpm PCRs still differ
  from real hardware — these prove the *mechanism*, not the production PCR policy."
- Real flash wear over time (the 60 KiB figure below is one measured snapshot, not
  a longevity soak — see study 004).
- Own-Secure-Boot-key evil-maid testing: `test/README.md`'s "Known limits" section
  notes `--secboot` today validates a signed chain boots using the *firmware's
  default* key set — testing with nixnas's own enrolled PK/KEK/db is a documented
  follow-up, not yet automated.

**Source:** `.github/workflows/boot-test.yml`, `.github/workflows/deep-test.yml`,
`test/README.md`, `test/*.sh` headers (each script documents its own "claim under
test" — read the top of the script for the exact assertion).

<a id="002"></a>
## 002 — The f2fs release-cblocks pass reclaims real, measured space

**Claim:** f2fs `compress_mode=fs` compresses files at writeback but does **not**
return the saved space to the free pool by default (it keeps the uncompressed block
count reserved). `docs/STORAGE.md` §2 documents that the release pass
(`F2FS_IOC_RELEASE_COMPRESS_BLOCKS`, landed as
`modules/lib/f2fs-release-cblocks.nix`) actually recovers that space, with a real
number attached, not just a mechanism description:

> *Confirmed on a real deployment (2026-07-04): a store that had never run this
> pass released ~824 MiB (55%→40% used) the first time it ran.*

**Why this matters for a decision:** it validates the "two separable wins" model in
STORAGE.md §2 — wear/boot-speed reduction is free (mount options alone), but
*density* (more kept generations fitting the stick) genuinely required shipping the
release pass as build-time + on-box plumbing, which is what happened
(`modules/lib/f2fs-release-cblocks.nix`, wired into the image build, `rescue-maintain`'s
foreign-store `nix copy`, and `nix.extraOptions post-build-hook` for local rebuilds).

**Source:** `docs/STORAGE.md` §2.

**Reproduce:** `scripts/verify-f2fs-store.sh`'s release-reclaim probe (loop-device,
per `docs/STORAGE.md` §8), or compare `f2fs_io get_cblocks` / `df` on a real store
before and after running the release pass by hand.

<a id="003"></a>
## 003 — Kept-generation ESP cost is dominated by shared kernel+initrd, not per-generation stubs

**Claim:** an earlier estimate in this repo assumed each kept generation costs
~80 MiB of ESP space (one full UKI per generation), which would make
`boot.keepGenerations` (default 8) a tight fit against a small ESP. That estimate
has been superseded by a dated, cited measurement in
`modules/options.nix`'s `nixnas.boot.keepGenerations` description:

> *Measured on a live 2 GiB stick 2026-07-26: a kept generation is a lanzaboote
> STUB of ~195 KiB, while kernel+initrd are written once per kernel VERSION into
> `EFI/nixos` (~50 MiB a pair) and shared by every generation using them. 30 kept
> generations cost ~6 MiB of stubs. The real ESP weight is a self-contained rescue
> UKI, at ~47 MiB each.*

**Decision this changed:** `keepGenerations` "raise this freely for rollback depth;
size the ESP for kernel versions and rescue images, not for generation count"
(same option description) — a materially different sizing rule than the ~80 MiB/gen
assumption it replaced.

**Not yet done:** `docs/ARCHITECTURE.md` §9 item 5 and `README.md`'s "Hardware
spikes remaining" line still quote the old ~80 MiB/generation figure — see
[`../experiments/README.md`](../experiments/README.md#007) for that doc-sync gap.

**Source:** `modules/options.nix` (`nixnas.boot.keepGenerations` description).

<a id="004"></a>
## 004 — Impermanence collapses stick writes to near-zero

**Claim:** with root as tmpfs and journald/`/tmp`/coredumps/swap all in RAM
(`docs/OPTIMIZATIONS.md` §1), the only remaining write path to the stick is
deliberate (updates, boot-counting metadata). `docs/ARCHITECTURE.md` §10 cites a
concrete measured result, backed by an actual test:

> *`test/verify-writes.nix` proves it — ~100 MiB of logs+files moved **60 KiB** to
> the stick.*

`README.md` repeats the same figure ("measured at **60 KiB** for ~100 MiB of
log+file activity").

**Why this is load-bearing:** it is the empirical basis for the repo's whole
"cheap sticks don't wear out" claim, and for rejecting the more invasive
read-only-store-plus-remount-window design considered in `docs/ARCHITECTURE.md`
§10 ("Impermanence already kills the write *stream*; the ro-mount would only shave
the already-negligible per-boot/background bits... Not worth it.").

**What this is not:** a longevity soak. It is one measured snapshot of one
workload shape (~100 MiB of simulated log/file churn), not a claim about
cumulative wear over months of real updates — the dominant *intentional* write
path (a new generation, "a few hundred MB, ~a dozen a year") is separately
reasoned, not separately measured, in the same section.

**Source:** `docs/ARCHITECTURE.md` §10; `README.md`; test: `test/verify-writes.nix`.
