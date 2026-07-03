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
                                          /nix/persist — the box's identity: machine-id, the
                                          running system's SSH host key, tailscale state
                                          (modules/appliance/identity.nix)
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
3. The selected generation's **signed UKI** runs; its **signed initrd** unlocks the STORE via
   **TPM2** — with `crypto.tpm2.requirePin = true` (the strict default) the PIN is entered
   remotely over initrd-SSH; with `requirePin = false` the store auto-unlocks (PCR-bound) and the
   box comes up unattended. Either way Secure Boot + the TPM-sealed host key guarantee any prompt
   channel is trusted: a maid cannot phish it with a tampered initrd or a swapped stick (§6).
4. **Root `/` is tmpfs** (impermanence); the real persistent **`/nix`** is mounted read-write from
   the unlocked LUKS partition; only `/nix` and the ESP persist (identity — machine-id, SSH host
   keys, tailscale state — lives at `/nix/persist`). The stick is **not loaded wholesale into
   RAM** — hot store paths are **page-cached on demand** and self-limiting (cold pages drop and
   re-read from the compressed f2fs). Working memory is kept small by **zram** (compressed swap,
   20 % of RAM, no disk swap) + f2fs **`compress_cache`** (compressed store blocks cached in
   RAM) — so the appliance fits boxes with far less than 128 GB.
5. The stateless OS comes up **reachable, with the data still locked**: sshd + Tailscale start
   with their stick-persisted identity, while every `storage.unlock` member stays `noauto`. The
   operator SSHes in and runs **`nixnas-unlock`**: ONE passphrase opens the members serially
   (systemd's kernel-keyring cache covers the rest), the ZFS pools import, and
   `nixnas-storage.target` raises the gated mounts + services. **One entry, everything data.**
6. **`system.autoUpgrade` pulls the operator's config flake from their private Git** (deploy key via
   sops-nix) and builds the next generation. The flake is *not* part of nixnas — it is how the
   declarative system config is loaded; nixnas only provides the mechanism.

## 4. Updates — autonomous, native

- **`system.autoUpgrade`** periodically pulls the operator's flake (their private repo,
  deploy key via sops-nix) and `nixos-rebuild boot`s a new generation — built **on the box**
  (DECIDED), **into the real persistent LUKS store** (this is exactly why the store must not be
  a tmpfs copy). Cap `nix.settings.max-jobs/cores`; `TMPDIR` on the persistent store.
  - **Why build on the box (not receive a closure):** nixnas targets machines *strong enough to
    build themselves* — and more than that, a nixnas box is **the nexus**: the capable hub that
    may in turn build + push closures to weaker *dependent* systems (an e2-micro, an alwaysdata
    box) that must never do real work. So the model is inverted from the fleet's tiny nodes:
    nixnas is the builder, not the built-for. (Contrast the [build on hub, never on node] rule for
    the brittle fleet — nixnas *is* a hub.) No receive-closure / image-swap path for nixnas itself.
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

- **Unlock model — two independent layers, by design.**
  - **The OS stick binds to the TPM** (`crypto.tpm2`): the TPM releases the store key only if
    PCRs match (untampered boot chain). `requirePin = true` (the strict default) additionally
    demands the PIN on EVERY boot — a stolen, powered-off box never auto-decrypts, but every
    boot needs an operator. `requirePin = false` trades that for unattended resilience: the box
    self-recovers from a power cut to "reachable, data locked", and only a TAMPERED chain (PCR
    mismatch) falls back to the recovery keyslot. Pick per threat model (see "Operational
    tension" below).
  - **The data members are passphrase-ONLY** — never TPM-bound, never keyfile-persisted. They
    stay locked (`noauto`) until the operator runs **`nixnas-unlock`** over SSH: the members
    open SERIALLY and systemd's own password cache (kernel keyring, the `cryptsetup` key) reuses
    the first entry for the rest — **one passphrase per boot for the whole data set**, entered
    into a channel authenticated by the stick's sealed/persisted host keys. A seized disk (or
    the whole box) yields nothing without the passphrase.
- **Build-time vs first-boot.** The image build enrolls only the **passphrase keyslot** on the
  store (hardware-independent; the TUI injects the passphrase file into the builder VM with
  `imageScript --pre-format-files` — it never touches the Nix store, and a build without it
  fails closed). The **TPM2 keyslot is enrolled on first boot on the real hardware**
  (`systemd-cryptenroll --tpm2-device=auto`) — PCRs are hardware-specific, so a build machine
  cannot seal to the target TPM. The operator enrolls their data-set passphrase on their
  self-built pools (nixnas never formats them).
- **Headless remote unlock (mandatory).** The box is **headless** — nobody can type at the
  console, so the in-initrd PIN prompt must be reachable over the network. nixnas ships this:
  - **Primary: initrd-SSH** (`boot.initrd.network.ssh` + `boot.initrd.systemd.enable`) — bring
    up the NIC in the initrd, SSH in, hand the PIN to the password agent. Works for the general
    distro (no special hardware). **Host key is TPM-sealed by default (DECIDED + built), via a
    systemd credential — no bespoke unseal code:** on first boot the key is generated and sealed
    with `systemd-creds encrypt --with-key=auto-initrd --tpm2-pcrs=7` (PCR 7 = Secure Boot state)
    straight into the ESP's `loader/credentials/` drop-in. From boot #2 on, **lanzaboote's stub**
    packs that `.cred` into the initrd (`.extra/global_credentials`) and **systemd auto-decrypts
    it** when the initrd sshd loads it (`LoadCredentialEncrypted=`), landing the plaintext only in
    the unit's `$CREDENTIALS_DIRECTORY` — never on the plaintext ESP. A tampered chain (PCR
    mismatch) makes the TPM refuse the key, so a stolen stick can't impersonate the unlock prompt —
    closing the one evil-maid wart of generic initrd-SSH, and reusing systemd's own credential
    plumbing rather than a hand-rolled mount/decrypt service. *Bootstrap:* the very first boot has
    no credential yet, so sshd doesn't start and that one unlock uses serial/IPMI-SOL; from boot #2
    onward initrd-SSH is available. Fallback for no-TPM boxes: `boot.remoteUnlock.sealHostKey =
    false` + a plaintext `hostKeyPath` (embedded in the initrd, lands on the ESP → LAN/tailnet-only).
    `modules/boot/remote-unlock.nix`; verified by `test/verify-sealed-hostkey.nix` (stage-2 seal +
    decrypt round-trip) **and `test/seal-2boot-test.sh`** (a real power-cycle: boot #1 seals, boot #2
    the initrd unseals → initrd-SSH comes up → network unlock → login).
  - **Where present: IPMI Serial-over-LAN** (boxes with a BMC) — separate trust domain, no SSH
    key on the ESP; the cleaner channel.
  - **Tailscale-in-initrd** (unlock from anywhere) is **exotic** (tailscaled + state + tun in the
    initrd) — a spike, not the baseline. Pragmatic "from anywhere" = initrd-SSH on the LAN reached
    *through* a Tailscale node elsewhere.
  The **running** system always ships **sshd + Tailscale** as appliance defaults (operator supplies
  the tailnet auth key) — headless admin once booted.
- **Operational tension (security-concept option).** Headless + PIN-every-boot means **every** boot
  needs a working remote path; if the network is down at boot, the NAS stays locked until reachable.
  The strict choice (the default) maximises evil-maid resistance. The alternative —
  **TPM2 PCR-only auto-unlock** (`requirePin = false`; the box self-recovers after a power cut and
  demands the recovery key only on tamper) — trades some OS-layer resistance for unattended
  resilience, and costs the DATA nothing: the data set is passphrase-gated either way, so the
  worst a thief gets from an auto-unlocking stick is the OS config. With data behind its own
  post-boot passphrase, auto-unlock is the natural NAS posture; strict remains the default.
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
     shim/bootkit bypasses operator keys). **DECIDED: the keyset is a STABLE IDENTITY, part of
     the config** — real hosts supply their own PK/KEK/db via sops (`boot.secureBoot.keysSops`),
     which the TUI decrypts (sops tar) and injects into the image at `/nix/lanzaboote/pki`
     (`imageScript --post-format-files`), so lzbt signs from day one and the SB identity does not
     change per box or per reflash. First-boot autogeneration is only the keyless *demo* fallback
     (`keysSops == null`), never a real host.
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
- **Break-glass recovery — escrowed to Vaultwarden (DECIDED + built).** The recovery keyslot is
  a **SEPARATE high-entropy key** (256-bit, `/dev/urandom`), distinct from the daily TPM2 PIN and
  independent of any one box's TPM — the last-resort key when the PIN is forgotten and the fTPM is
  cleared. It is generated, enrolled (`cryptsetup luksAddKey`, a new slot that never wipes the
  daily/TPM2 slots) and uploaded to Vaultwarden **on the HUB, never the node** ([build on hub]):
  the Vaultwarden API creds (`crypto.recovery.credsSops`) live only on the build machine; the box
  only ever *receives* a LUKS header that already carries the recovery slot. `modules/crypto/
  recovery-escrow.nix` ships the hub tool (`nixnas-escrow-recovery enroll`) + a box-side read-only
  `nixnas-recovery-status` (keyslot count). The keyslot mechanism is VM-verified on a loopback LUKS
  (`test/verify-recovery.nix`: 1→2 slots, opens with the recovery key AND the daily passphrase);
  the Vaultwarden upload is a hub-network path, validated on the hub, not in the sealed demo VM.
- **Future hardening (verity parity, no verity costs):** layer **dm-verity or
  dm-integrity/AEAD** on the persistent store, with the root hash **sealed into the
  already-signed UKI**. Captures verity's one genuine integrity edge without its
  version-density, flash-wear, and run-from-RAM costs.
- **No self-reboot.** Because the PIN is required every boot, `autoUpgrade` runs with
  `allowReboot = false`: a new generation is staged (`nixos-rebuild boot`) and only
  activates on the next operator-initiated, PIN-unlocked reboot. The box must never reboot
  itself into a PIN prompt no one is at.

## 7. The flake / TUI workflow

- **Build once, here.** The **Rust TUI** runs `nix build .#imageScript` against the operator's
  flake (a PURE eval — no secrets in the Nix store), then executes the disko image script with
  the LUKS passphrase injected into the builder VM (`--pre-format-files`) and, when configured,
  the Secure Boot PKI injected onto the finished image (`--post-format-files` →
  `/nix/lanzaboote/pki`). The result is the personalised `.raw` (LUKS store seeded with
  generation 1 + the SB keys); the TUI then flashes it (caligula + an independent post-write
  verification). The TUI is **install-only** — *not* in the update path.
- **After flashing, the box is autonomous** (`autoUpgrade`). Updating nixnas = committing
  to the operator's flake; the box pulls + rebuilds itself.
- **`nixnas.config`** (the TOML next to the operator's flake) holds only what the TUI itself
  consumes — where the flake is, the SB-PKI sops file, build-VM memory. The MACHINE's
  configuration is Nix: the operator's `nixnas.*` parameters + their own
  `services.k3s`/`hardware.amdgpu`/… — the whole closure is what gets installed.

## 8. What is nixnas-specific (everything else is stock NixOS)

1. The USB **GPT/disko layout** + the **impermanence (tmpfs-root)** packaging + the
   post-boot data-unlock plumbing (`nixnas-unlock` / `nixnas-storage.target`).
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
3. **Keyring reuse across switch-root** — ✅ **RESOLVED BY REDESIGN**: the data unlock no
   longer straddles the initrd→stage-2 boundary at all. Members are `noauto` and open
   post-boot inside ONE `nixnas-unlock` invocation, where systemd's password cache
   (serially chained members) makes one passphrase cover the set — no cross-switch-root
   keyring assumption left. (The initrd unlocks only the stick store, via TPM2.)
4. **The anti-rollback counter** — TPM2-NV implementation + the version policy.
5. **Generation count vs ESP size** on 8 GB (one ~80 MiB UKI per generation).
6. **TPM-sealed initrd-SSH host key** — ✅ **RESOLVED + built** (default `sealHostKey = true`),
   using the systemd **credential** mechanism (seal → ESP `loader/credentials/` → lanzaboote stub
   → `LoadCredentialEncrypted=` auto-decrypt), so there is no bespoke unseal service. Proven by a
   real power-cycle in the VM (`test/seal-2boot-test.sh`: persistent disk + per-boot swtpm so PCR 7
   matches; boot #1 seals, boot #2 the initrd unseals → initrd-SSH → network unlock → login).
   Remaining hardware spike: the same flow on a physical TPM (real PCR 7).

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
- **Mounting is native; nixnas doesn't reinvent it.** You mount your storage with plain
  `fileSystems` at `/hot`, `/cold`, or any nested path (an XFS drive *under* a ZFS tree, …),
  hooked to `nixnas-storage.target` (`"noauto" "x-systemd.wanted-by=nixnas-storage.target"` —
  the mappers don't exist until `nixnas-unlock`). nixnas adds only `storage.unlock` (open your
  LUKS members post-boot with one passphrase, non-fatally, at a stable `/dev/mapper/<name>`)
  and `storage.zfsPools` (per-pool `nixnas-import-<pool>` services; datasets self-mount at
  their `mountpoint` properties). Persisting heavy state off the tmpfs root = bind mounts from
  the pools, gated on the same target (identity is already on the stick). See `examples/host.nix`.
- **/nix location is a choice — `store.location = "usb" | "hot"` (see docs/HOT-MODE.md).** The
  DEFAULT, **`usb`**, is everything above: /nix on the stick, self-contained (boots even if a
  pool is missing) — the resilient appliance default, and for it the stick's OS content never
  relocates onto a data pool. **`hot`** is the deliberate opt-in for hub-class boxes that must
  install heavy software *system-wide* (beyond an 8 GiB stick): the MAIN system's /nix lives on
  your encrypted pool, and the stick is relegated to the ESP + a self-contained **RESCUE**
  system. The operator enters their key in the initrd (never auto), and a dead pool drops to the
  rescue rather than "boots reachable anyway". It is **not** a composed store (overlaying stick +
  pool into one /nix is structurally unsound — researched and rejected); it is two *independent*
  systems, the proven "root-on-ZFS + a USB rescue" pattern. (The earlier flat "never store-on-HOT"
  rule is exactly the `usb` default; `hot` makes the trade explicit and opt-in.)
- **Wear isolation (measured) — and why that's enough.** Cheap USB sticks have no SSD-grade flash
  management and die / go slow under a steady write *stream*. Impermanence removes that stream:
  logs (journald `volatile`), `/tmp`, coredumps and swap (zram) all live in RAM; stray writes hit
  the tmpfs root, never the stick. `test/verify-writes.nix` proves it — ~100 MiB of logs+files
  moved **60 KiB** to the stick. What's left is deliberate + rare: the **updates** (a new
  generation, a few hundred MB, ~a dozen a year — dominant, and irreducibly rw) plus a few hundred
  KB of per-boot metadata (the `booted-system` gcroot, boot-counting, the systemd-boot random seed).
  A few GB/year total → decades of headroom on any stick.
  - *Considered and rejected: mounting the store read-only + a deliberate `remount,rw` update
    window (with a `/nix/var/nix` split — gcroots/socket to tmpfs, db/profiles ro-except-update).*
    Impermanence already kills the write *stream*; the ro-mount would only shave the
    already-negligible per-boot/background bits — NOT the updates, which need rw — for a marginal
    accidental-write guardrail, at the cost of a fragile load-bearing update path. Not worth it.
  - Persistent "emergency" logs stay a **conscious opt-in** (`store.persistLogs`, built, default
    off): journald flips from `volatile` (RAM) to `persistent`, bind-mounted onto the **USB stick**
    store (`/nix/nixnas/journal`) — *the stick, not a pool* (logs are a boot/OS concern, and a pool
    may not be mounted when you need them). A temporary setting you'd only flip while chasing a
    problem, then flip back — the one deliberate write exception.
- **The rescue model (data pools are portable).** Only the **stick store** binds to the TPM.
  The data pools (HOT/COLD + any archive drives) carry a **plain LUKS2 passphrase keyslot** —
  entered once per boot at `nixnas-unlock` — and are **never TPM-bound**. So a pool member
  pulled into another machine unlocks with the passphrase alone; no specific box's TPM is
  required. (Use ONE shared passphrase across the members for the one-prompt unlock; it is the
  only thing protecting a seized disk, so give it real entropy.) nixnas only imports + unlocks
  them, never reformats.
