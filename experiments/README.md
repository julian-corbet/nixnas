# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up
properly. Nothing here is guaranteed to work, be maintained, or survive the next
cleanup pass. If something in here turns out to matter, distill the actual finding
into [`../studies/`](../studies/README.md) and let the experiment stay disposable
(or delete it).

This is also the open-questions ledger for nixnas's own judgment calls. Unlike a
fresh scaffold, nixnas already has extensive CI coverage
(`.github/workflows/boot-test.yml` on every push, `deep-test.yml` weekly) and one
real field deployment (`docs/FIELD-BACKLOG.md`). The entries below are not "untested
code" — they are the specific decisions that a QEMU/swtpm CI environment structurally
cannot settle (real UEFI firmware, real PCR values, real flash wear over time) or
that the repo's own docs/comments already flag as reasoned-not-measured or
not-yet-designed. Every entry cites the exact file/doc it comes from. Results feed
back into the cited option's default or the cited doc as they close.

## Contents

1. [Is `compress_log_size=2` (16 KiB f2fs cluster) actually the right boot-speed/density trade?](#001)
2. [Is f2fs `mode=lfs` actually better than the `adaptive` default on real USB flash?](#002)
3. [Does boot-counting's "bless" step ever clear the counter on real hardware?](#003)
4. [The TPM2-NV anti-rollback counter — no implementation, no version policy yet](#004)
5. [`autoUpgrade` against a private flake on an 8 GiB target — pull-auth undesigned](#005)
6. [PCR 11 (measured/signed UKI) binding — deferred "phase-2 hardening"](#006)
7. [Doc drift: the ~80 MiB-per-generation ESP-cost figure is now contradicted by a cited measurement](#007)

---

<a id="001"></a>
## 001 — Is `compress_log_size=2` (16 KiB f2fs cluster) actually the right boot-speed/density trade?

**Question:** `docs/STORAGE.md` §3 fixes the f2fs compression cluster at
`compress_log_size=2` (16 KiB) specifically to minimise read-amplification on the
boot path (a 4 KiB page fault pulls a whole cluster). The doc's own reasoning ends
with an explicit admission:

> *A QEMU boot-time A/B vs an uncompressed control is still worth measuring, but
> does not gate the decision.*

**Hypothesis (as currently reasoned, not measured):** 16 KiB is the read-amplification
*floor*, cheap and locality-friendly, and a bigger cluster would only buy a modest
ratio gain (STORAGE.md's own estimate: "single-digit-to-~15%, concentrated on the
non-ELF minority") at the cost of multiplying per-fault boot I/O. Derived from kernel
source (`fs/f2fs/{f2fs.h,super.c,compress.c}`), not from a timed boot.

**Method sketch:** boot the demo image in `test/boot-vm.sh` (or the CI QEMU job) with
`compress_log_size` swept across its legal range (2, 3, 4 — `MIN=2`…`MAX=8` per
`fs/f2fs/f2fs.h`) against an otherwise-identical uncompressed control, and time
wall-clock to `login:` on the serial console for each. Needs re-seeding generation 1
per value (STORAGE.md §3: cluster size is fixed per-inode at file creation).

**Status:** open. (`docs/STORAGE.md` §3)

<a id="002"></a>
## 002 — Is f2fs `mode=lfs` actually better than the `adaptive` default on real USB flash?

**Question:** `docs/OPTIMIZATIONS.md` §3 lists `mode=lfs` (pure-sequential writes,
which would suit a write-once store on sequential flash) as a candidate, marked ◯
(operator policy), with its own caveat inline:

> *raises GC pressure; **benchmark on the real stick** before adopting. Leave
> `adaptive` unless measured.*

**Hypothesis:** unevaluated either way — the doc takes no position beyond "leave the
default." `adaptive` is f2fs's own default and is what nixnas currently ships.

**Method sketch:** a stick-longevity/GC-pressure comparison needs real wear over
many write cycles (updates + generation churn), which a single QEMU boot cannot
produce — this one plausibly needs a soak on real hardware, not just the VM.

**Status:** open. (`docs/OPTIMIZATIONS.md` §3)

<a id="003"></a>
## 003 — Does boot-counting's "bless" step ever clear the counter on real hardware?

**Question:** `modules/boot/rollback.nix` wires `boot.lanzaboote.bootCounting.initialTries`
and documents a VM run where the *counting* half worked (gen-1 installs as `…+3`,
first boot renames it to `…+2-1`) but the *blessing* half — `systemd-bless-boot.service`
clearing the counter on a good boot — **ran but did not clear the counter** in the
SB-off OVMF VM:

> *the stub↔`LoaderBootCountPath`↔bless bridge is the lanzaboote×systemd hardware
> spike (ARCHITECTURE §9.1)*

This is the single most cross-referenced open item in the repo — flagged in
`modules/boot/rollback.nix`, `docs/ARCHITECTURE.md` §9.1, `docs/KERNEL.md`
("⚠️ boot-counting × lanzaboote is still UNVERIFIED — it is the load-bearing spike"),
and `README.md`'s "Hardware spikes remaining" line.

**Hypothesis:** the manual generation menu is a guaranteed fallback regardless
(`keepGenerations`), so the structural failsafe holds even if bless never lands —
but *automatic* rollback (the point of boot-counting on a headless box) does not
work until this closes.

**Method sketch:** force three consecutive boot failures on a real UEFI board and
confirm the bootloader menu's default entry actually falls back to the previous
generation without operator intervention; separately confirm a genuinely good boot
clears the counter (`bootctl status` / the `LoaderBootCountPath` EFI var reads back
clean).

**Status:** open — hardware spike, VM already showed the negative half of this result.

<a id="004"></a>
## 004 — TPM2-NV anti-rollback — rejected by scope

The fleet policy reserves TPM for the SSH-channel identity, so TPM2-NV is not an
authorized anti-rollback mechanism. Secure Boot does not by itself reject an older still-signed
UKI; the current design therefore claims bounded exact-release reconciliation, not cryptographic
signed-version anti-rollback.

**Status:** rejected by scope.

**Status:** open, unimplemented. (`docs/ARCHITECTURE.md` §9.4)

<a id="005"></a>
## 005 — `autoUpgrade` against a private flake on an 8 GiB target — pull-auth undesigned

**Question:** `modules/appliance/auto-upgrade.nix` wires stock
`system.autoUpgrade` (`operation = "boot"`, `allowReboot = false`), but
`modules/options.nix`'s `autoUpgrade.flake` description defers the actual private-repo
case:

> *Private flakes need pull auth the operator supplies (deploy key / netrc); that,
> and update-on-the-8 GiB-target, is the autoUpgrade spike (ARCH §9.2).*

`docs/ARCHITECTURE.md` §9 item 2 repeats it: "pull auth (deploy key via sops-nix),
root git `safe.directory`, end-to-end build-once-then-self-update on the 8 GB
target."

**Hypothesis:** none committed yet — sops-nix for the deploy key is the likely
mechanism (matches the rest of the repo's secrets handling), but the root-owned
`git safe.directory` interaction and whether the 8 GiB stick has headroom to build
(vs. only ever pulling substituted closures — OPTIMIZATIONS.md §5's substituter
note) are unresolved.

**Method sketch:** an end-to-end run against a real private flake with a deploy key,
on the actual `usb` disk-size target, checking it neither wedges on `git` ownership
checks nor exhausts stick space mid-build.

**Status:** open, undesigned. (`docs/ARCHITECTURE.md` §9.2, `modules/options.nix` autoUpgrade.flake)

<a id="006"></a>
## 006 — PCR 11 disk binding — closed by simplification

The TPM-bound LUKS design was removed. Every disk now requires a passphrase and TPM is
reserved for the initrd-SSH host identity. That credential remains on PCR 7 so normal signed
UKI updates do not require per-release resealing. Exact release acceptance is handled by
nixrescue/nixdeploy, not by a TPM disk-unlock policy.

**Status:** closed by redesign.

<a id="007"></a>
## 007 — Doc drift: the ~80 MiB-per-generation ESP-cost figure is now contradicted by a cited measurement

**Question:** `docs/ARCHITECTURE.md` §9 item 5 and `README.md`'s "Hardware spikes
remaining" paragraph both still describe the open question as "Generation count vs
ESP size on 8 GB (**one ~80 MiB UKI per generation**)". But
`modules/options.nix`'s `nixnas.boot.keepGenerations` description now carries a
dated, cited correction:

> *The ESP cost is far smaller than an earlier revision of this text claimed
> (~80 MiB per kept generation). Measured on a live 2 GiB stick 2026-07-26: a kept
> generation is a lanzaboote STUB of ~195 KiB, while kernel+initrd are written once
> per kernel VERSION into `EFI/nixos` (~50 MiB a pair) and shared by every
> generation using them. 30 kept generations cost ~6 MiB of stubs. The real ESP
> weight is a self-contained rescue UKI, at ~47 MiB each.*

The two docs now disagree, and only one has been updated with the real number.

**Hypothesis:** `modules/options.nix` is the corrected, dated, measured source;
`docs/ARCHITECTURE.md` §9.5 and `README.md` are stale and should be reworded to
match (per-kernel-version + rescue-image ESP sizing, not per-generation), or
explicitly marked resolved. This is a documentation-sync task, not a design
question — but it is open until someone actually edits those two files.

**Method sketch:** none needed — the measurement already exists (see
[`../studies/README.md`](../studies/README.md) #003); this entry closes the moment
`docs/ARCHITECTURE.md` §9 and `README.md` are edited to match `modules/options.nix`.

**Status:** open — doc-sync gap, not a missing measurement.
