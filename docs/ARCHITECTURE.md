# nixnas — ARCHITECTURE.md

FOSS-clean: every site value is a parameter (a typed `nixnas.*` option), never a literal.
This document is the post-steelman, decided design.

## 0. The model, in one line

nixnas is **standard NixOS — encrypted, Secure-Boot-signed (lanzaboote), self-updating
via generations — packaged to install on an 8 GB USB stick, with a RAM-resident root,
driven by a flake.** Updates, rollback, multiple versions and signing are *not* bespoke:
they are NixOS's own `system.autoUpgrade`, generations, `lanzaboote`, and LUKS. nixnas
adds only the **USB image/layout**, the **impermanence (tmpfs-root) packaging**, and a
**build+flash TUI**.

> **"RAM-resident" means tmpfs *root* + page-cache, NOT the store in RAM.** The
> `/nix/store` stays a **real persistent read-write LUKS partition** — because the box
> updates itself, and a new generation built into a tmpfs store would vanish on reboot.
> The stick is barely read in steady state (hot store paths live in the page cache after
> first touch); it is written only on update. The "store-in-RAM / stick yankable
> mid-run" idea is dropped — it is intrinsically incompatible with on-box self-update,
> and autonomy is the fixed constraint that wins.

> **Supersedes** the read-only dm-verity *image-appliance* model — but on honest grounds
> (see §1), not the original (wrong) one.

## 1. Why native self-update, not a verity image

| Requirement | Verity image | Native self-update (chosen) |
|---|---|---|
| Several versions on **8 GB** | ✗ no block sharing → ~2–5 | ✓ store-sharing → many cheap generations |
| Minimal custom software | ✗ keeps full Nix toolchain anyway + repart/sysupdate/roothash glue | ✓ stock `nixos-rebuild` + `autoUpgrade` |
| Flash wear / update cost | ✗ rewrites a fresh ~1 GB erofs image per update | ✓ a hardlinked profile generation + one signed UKI |
| Autonomous on-box update | ✓ *(achievable — sysupdate local source)* | ✓ |
| Userspace integrity | ✓ block-integrity (verity) | ~ signed-boot only; LUKS-XTS authenticates nothing (§6) — addable later as a hybrid |

**Correction to the earlier rejection:** on-box verity *is* possible (`systemd-sysupdate`
takes a local-directory source, so the box could build → `veritysetup` → `sbsign` →
write the inactive slot). Verity is not rejected for "needs a provisioning machine" — it
is rejected for **version density, flash wear, and custom surface** on a self-updating
8 GB box. Its one genuine edge (integrity of executed userspace) is low-severity for a
home NAS and is **addable later as a hybrid** (§6).

## 2. On-stick layout (GPT, adaptive to stick size)

Only **two** partitions, sized **proportionally to the stick** — the operator brings whatever
USB they have and nixnas lays it out:

```
#1  ESP    FAT32          ~1 GiB (1–2)   lanzaboote-signed systemd-boot + one signed UKI per
                                          generation + loader/ entries
#2  nixos  f2fs-in-LUKS2  REST of stick  the NixOS system: persistent /nix (store = all kept
                                          generations; /nix/var = db/profiles/gcroots) +
                                          machine-id + the persisted SSH host key (sops age id)
```

Sizing rule: **ESP = 1 GiB default (2 GiB on a larger stick), f2fs = everything else.**
8 GB stick → ~1 GiB ESP + ~7 GiB f2fs; 16 GB → 2 GiB ESP + 14 GiB f2fs; etc.

f2fs is **zstd:22-compressed** (`compress_log_size=2`/16 KiB) and mounted at **`/nix`** (so
`/nix/var` persists under tmpfs root); compression buys faster boot off the slow stick + less
wear. The full f2fs engineering detail — mechanics, the gen-1-via-disko seeding, the release
pass, mount options, the kernel/ZFS combo, and the footguns — is in **[`STORAGE.md`](STORAGE.md)**;
appliance tuning is in **[`OPTIMIZATIONS.md`](OPTIMIZATIONS.md)**. Data lives on the operator's
**separate** encrypted ZFS pools — never on the stick. Each generation's UKI (kernel + initrd) is
~80–150 MiB, so the **ESP is the bound on generation count** — ~8 in 1 GiB, ~16 in 2 GiB
(`boot.lanzaboote.configurationLimit`). The store side is cheap (base once + deltas).

## 3. Boot flow (headless, impermanence, compressed RAM)

1. UEFI — **Secure Boot, operator-only keys, MS 3rd-party CA removed, firmware password**.
2. **lanzaboote-signed `systemd-boot`** shows the generation menu.
3. The selected generation's **signed UKI** runs; its **signed initrd** brings up the network and
   **prompts for the single passphrase REMOTELY** — the box is **headless**, nobody is at the
   console (§6). Secure Boot guarantees the prompt is trusted: a maid cannot phish it with a
   tampered initrd.
4. **Root `/` is tmpfs** (impermanence); the real persistent **`/nix`** is mounted read-write from
   the unlocked LUKS partition; only `/nix`, the ESP, and the host key persist. The stick is **not
   loaded wholesale into RAM** — hot store paths are **page-cached on demand** and self-limiting
   (cold pages drop and re-read from the compressed f2fs). Working memory is kept small by **zram**
   (compressed swap, 20 % of RAM, no disk swap) + f2fs **`compress_cache`** (compressed store
   blocks cached in RAM) — so the appliance fits boxes with far less than 128 GB.
5. The stateless OS comes up; **sshd + Tailscale** start for headless admin; the operator's **data
   pools** import **non-fatally** — the **same one passphrase** opens the store (initrd) *and* every
   pool (stage-2) via kernel-keyring reuse. **One authentication, everything unlocks.**
6. **`system.autoUpgrade` pulls the operator's config flake from their private Git** (deploy key via
   sops-nix) and builds the next generation. The flake is *not* part of nixnas — it is how the
   declarative system config is loaded; nixnas only provides the mechanism.

## 4. Updates — autonomous, native

- **`system.autoUpgrade`** periodically pulls the operator's flake (their private repo,
  deploy key via sops-nix) and `nixos-rebuild boot`s a new generation — built on the
  box, **into the real persistent LUKS store** (this is exactly why the store must not be
  a tmpfs copy). Cap `nix.settings.max-jobs/cores`; `TMPDIR` on the persistent store.
- **`lanzaboote`** signs the new generation's UKI on the box; the SB `db` key lives in
  the LUKS store. (Price: a runtime root compromise could self-sign — see §6.)
- **Rollback:** the **generation menu is the guaranteed path** (manual rollback to any
  kept generation; its closure is in the store). **Automatic** rollback via systemd-boot
  **boot-counting is UNVERIFIED** with lanzaboote-signed UKIs (NixOS boot-counting is WIP;
  lanzaboote regenerates+signs the ESP each rebuild rather than letting systemd-boot
  mutate signed entries) — it must be **hardware-spiked** (force 3× boot failure → lands
  on the previous generation) before being relied on.
- **GC:** `nix.gc` + `configurationLimit` keep the store + ESP inside 8 GB.

## 5. Multiple versions on 8 GB — the "snapshot" win, for free

What makes *several* versions fit is **Nix store-path sharing**, not a CoW filesystem: N
generations of one NixOS+k3s system share ~the whole base (kernel, systemd, k3s,
containerd, glibc…) — only changed paths add bytes. That is the "snapper feel", and it
is simply **how NixOS's store already works**. No btrfs, no bcachefs (out of mainline
6.18), no custom snapshot logic.

## 6. Crypto / Evil-Maid — honest

- **Unlock model (DECIDED): TPM2-with-PIN, the PIN is required on EVERY boot — no
  unattended reboot, by design ("kein unbefugter Zugriff").** A single passphrase *is* the
  TPM2 PIN *and* is the same secret enrolled on the operator's data pools. The TPM releases
  the store key only if PCRs match (untampered boot chain) **and** the PIN is entered; a
  changed/tampered state makes the TPM refuse → the off-box **recovery keyslot** (mandatory)
  is the fallback. A stolen, powered-off box therefore **never auto-decrypts**.
- **Entered once.** The store is unlocked in the **initrd**; the data pools in **stage-2**
  (non-fatal). `systemd-cryptsetup` caches the entered secret in the kernel keyring and
  reuses it across devices → one prompt unlocks the store + all pools. *(Spike: confirm the
  keyring survives the initrd→stage-2 switch-root.)*
- **Build-time vs first-boot.** `lib.mkImage` enrolls only the **passphrase keyslot** on the
  store (hardware-independent). The **TPM2 keyslot is enrolled on first boot on the real
  hardware** (`systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin`) — PCRs are
  hardware-specific, so a build machine cannot seal to the target TPM. The operator enrolls
  the **same passphrase** on their self-built pools (nixnas never formats them).
- **Headless remote unlock (mandatory).** The box is **headless** — nobody can type at the
  console, so the in-initrd PIN prompt must be reachable over the network. nixnas ships this:
  - **Primary: initrd-SSH** (`boot.initrd.network.ssh` + `boot.initrd.systemd.enable`) — bring
    up the NIC in the initrd, SSH in, hand the PIN to the password agent. Works for the general
    distro (no special hardware). *Caveat:* the initrd-SSH host key sits in the *signed* UKI but
    on the *plaintext* ESP → keep it LAN/tailnet-reachable, never internet-exposed.
  - **Where present: IPMI Serial-over-LAN** (example-host) — separate trust domain, no SSH key
    on the ESP; the cleaner channel.
  - **Tailscale-in-initrd** (unlock from anywhere) is **exotic** (tailscaled + state + tun in the
    initrd) — a spike, not the baseline. Pragmatic "from anywhere" = initrd-SSH on the LAN reached
    *through* a Tailscale node elsewhere.
  The **running** system always ships **sshd + Tailscale** as appliance defaults (operator supplies
  the tailnet auth key) — headless admin once booted.
- **Operational tension (security-concept option).** Headless + PIN-every-boot means **every** boot
  needs a working remote path; if the network is down at boot, the NAS stays locked until reachable.
  The strict choice (current default) maximises evil-maid resistance. The alternative —
  **TPM2 PCR-only auto-unlock** (no PIN; box self-recovers after a power cut; PIN only on tamper) —
  trades some resistance for unattended resilience. Exposed as an option; default = strict.
- **The evil-maid defense is signed boot, not encryption.** Honest framing:
  **confidentiality-by-encryption + integrity-by-signed-boot.** Default LUKS2 aes-xts is
  *unauthenticated and malleable* — it gives confidentiality, **not** integrity; and the
  store holds only *public* nixpkgs outputs, so that confidentiality buys little. What
  stops a maid is `lanzaboote` Secure Boot (no unsigned kernel runs) + the firmware
  password + operator-only keys.
- **On-box signing's price:** the SB `db` key is in RAM while the box runs, so a
  **runtime root compromise** (remote exploit, or a malicious flake input pulled by
  `autoUpgrade`) can mint a persistent SB-trusted UKI. Secure Boot here buys *offline*
  tamper-resistance, not *post-compromise persistence-resistance*. This is the conscious
  price of the no-provisioning-machine constraint.
- **MANDATORY preconditions** (the posture collapses without them):
  1. **Operator-only SB keys; the Microsoft 3rd-party UEFI CA REMOVED** (else a MS-signed
     shim/bootkit bypasses operator keys).
  2. **Firmware admin password** that blocks disabling SB / re-enrolling keys (else SB is
     toggled off and a fake unlock screen phishes the passphrase).
  3. **TPM2-NV monotonic anti-rollback counter** (or PCR-sealed version policy) — *this*,
     not verity, closes the "image an old store and wait for a CVE" replay maid. (Replay
     is a wash vs verity: neither model is safe without the counter.)
  4. IOMMU on, unused DMA ports off, no plaintext hibernation swap.
- **TPM2 + PIN**, PCR 7 baseline (stable across updates), recovery keyslot mandatory (AMD
  fTPM is wiped by a BIOS/NVRAM clear), SHA-256 bank. Non-fatal pool import (`Wants`-only,
  off `local-fs.target`, `boot.zfs.devNodes=/dev/disk/by-id`). nixnas **imports +
  unlocks** operator-built pools; it never creates/formats/destroys.
- **Future hardening (verity parity, no verity costs):** layer **dm-verity or
  dm-integrity/AEAD** on the persistent store, with the root hash **sealed into the
  already-signed UKI**. Captures verity's one genuine integrity edge without its
  version-density, flash-wear, and run-from-RAM costs.
- **No self-reboot.** Because the PIN is required every boot, `autoUpgrade` runs with
  `allowReboot = false`: a new generation is staged (`nixos-rebuild boot`) and only
  activates on the next operator-initiated, PIN-unlocked reboot. The box must never reboot
  itself into a PIN prompt no one is at.

## 7. The flake / TUI workflow

- **Build once, here.** A capable machine (the cluster) evaluates the operator's
  `nixosConfiguration`; `lib.mkImage` produces the initial USB image (LUKS store seeded
  with generation 1 + the lanzaboote keys + the signed UKI); the **Rust TUI** flashes it.
  The TUI is **install-only** — *not* in the update path.
- **After flashing, the box is autonomous** (`autoUpgrade`). Updating nixnas = committing
  to the operator's flake; the box pulls + rebuilds itself.
- **`nixnas.config`** = the operator's `nixnas.*` parameters + their own
  `services.k3s`/`hardware.amdgpu`/… — the whole closure is what gets installed.

## 8. What is nixnas-specific (everything else is stock NixOS)

1. The USB **GPT/disko layout** + `lib.mkImage` + the **impermanence (tmpfs-root)**
   packaging.
2. The **Rust TUI** (build the initial stick + flash + edit `nixnas.config`).
3. Packaging Secure Boot (lanzaboote keys) + the LUKS-store-on-USB into a flashable image.

Generations, rollback, self-update and signing are **stock NixOS** — `autoUpgrade`, the
bootloader's generation list, `lanzaboote`, LUKS, impermanence. nixnas is a thin
packaging of a well-trodden encrypted-Secure-Boot-autoUpgrade NixOS onto USB + a flake
workflow.

## 9. Open questions / spikes

1. **boot-counting × lanzaboote** — hardware-spike automatic rollback before relying on
   it; manual generation-menu rollback is the guaranteed fallback.
2. **autoUpgrade against a private flake** — pull auth (deploy key via sops-nix), root git
   `safe.directory`, end-to-end build-once-then-self-update on the 8 GB target.
3. **Keyring reuse across switch-root** — confirm one PIN entry in the initrd unlocks the
   stage-2 data pools (primary transport DECIDED: **initrd-SSH** — generic, every box;
   IPMI-SOL is an optional cleaner channel where a BMC exists, not the default).
4. **The anti-rollback counter** — TPM2-NV implementation + the version policy.
5. **Generation count vs ESP size** on 8 GB (one ~80 MiB UKI per generation).
6. **TPM-sealed initrd-SSH host key** (§10) — seal the host key to PCR 7 so it is never on
   the plaintext ESP; unseal in the initrd before sshd. Removes the one evil-maid wart of
   initrd-SSH generically (no IPMI needed). Needs the unseal-before-sshd unit ordering.

*(Resolved by the steelman: "copytoram a tmpfs /nix/store" does NOT compose with
autoUpgrade-to-LUKS — replaced by tmpfs-root + persistent store, §3.)*

## 10. Storage hierarchy, wear & the rescue model

- **The layers — only the smallest is on the stick.** A tiny boot medium holds the OS (in
  RAM); everything heavy lives elsewhere. (The classic appliance-NAS split: boot the OS from
  a small write-light medium, keep data + state on the array.)
  | Layer | What | Where |
  |---|---|---|
  | OS image | the **nix store** (kernel, k3s/containerd binaries, systemd, rendered config) | **USB stick** (read into RAM; impermanence) |
  | Runtime state | **container images**, the kine DB, app PVCs, persistent logs | **HOT pool** (SSD, e.g. `hot`) |
  | Bulk | media, backups | **COLD pool** (HDD, e.g. `cold`) |
  | Workloads | the k8s/Argo manifests (what runs) | **Git** (pulled at runtime) |
  The nix store holds *programs*, never *container images* — containerd keeps those in its own
  store (the ZFS snapshotter dataset on HOT). So the stick stays ~3–4 GiB no matter how many
  apps run.
- **HOT / COLD are nixnas concepts.** `storage.pools.hot` / `.cold` already name the imported
  pools; a **persistence-routing layer** (`storage.persist.{hot,cold}`, *planned*) bind-mounts
  the chosen state paths (`/var/lib/rancher`, containerd, …) from the tmpfs root onto datasets
  on the respective pool. This is also where the k3s-state binds live (impermanence needs them).
- **Where /nix lives.** DEFAULT = on the stick → self-contained, **boots even if a pool is
  missing**. OPT-IN `storage.storeOnHot` (*planned*) relocates the store to HOT for speed,
  redefining HOT as the boot-required system pool and COLD as boot-optional bulk.
- **Wear isolation (measured).** Cheap USB sticks have no SSD-grade flash management and die /
  go slow under a steady write stream. So logs (journald `volatile`), `/tmp`, coredumps and
  swap (zram) all live in RAM; the stick takes ~no writes except updates. `test/verify-writes.nix`
  proves it: generating ~100 MiB of logs+files moved **60 KiB** to the stick. Persistent
  "emergency" logs are opt-in (`store.persistLogs`, *planned*) and route to **HOT**, not the stick.
- **The rescue model (data pools are portable).** Only the **stick store** binds to the TPM
  (TPM2+PIN). The data pools (HOT/COLD + the SMR drives) carry a **plain LUKS2 passphrase
  keyslot** — the same secret as the PIN, reused via the kernel keyring — and are **never
  TPM-bound**. So a pool member pulled into another machine unlocks with the passphrase alone;
  no specific box's TPM is required. nixnas only imports + unlocks them, never reformats.
