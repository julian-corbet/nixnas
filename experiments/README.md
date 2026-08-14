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
3. [Does boot-counting exhaust failed tries and select the previous generation?](#003)

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
## 003 — Does boot-counting exhaust failed tries and select the previous generation?

**Question:** Secure-Boot-capable OVMF now proves both halves of a successful counted boot:
the firmware publishes `LoaderBootCountPath`, and nixboot's post-bless verifier confirms
`systemd-bless-boot` marked that boot good. The remaining automatic-fallback claim is the
negative path: after `initialTries` deliberately failed boots, does firmware actually select
the retained previous generation?

**Method sketch:** stage a known-good generation and a deliberately non-completing successor,
boot the successor through all configured tries without blessing it, then require OVMF to select
the known-good generation automatically. Assert the selected generation from inside the guest,
not merely by inspecting filenames on the ESP.

**Status:** open. The generation menu remains the guaranteed manual fallback; successful
counting/blessing is automated, but failed-try exhaustion is not yet an end-to-end test.
