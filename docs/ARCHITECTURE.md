# nixnas — ARCHITECTURE.md

FOSS-clean: every site value is a parameter (`<…>` / a typed `nixnas.*` option), never a literal.

## 0. Current state (v0)

`modules/boot/image.nix` boots a **single** read-only dm-verity **erofs `/usr`** image plus a UKI carrying `usrhash=<roothash>` in its cmdline, built via nixpkgs `image.repart` `verityStore`, launched from the removable-media fallback (`EFI/BOOT/BOOTX64.EFI`) with no bootloader and no SB signing yet. Single slot; `/` is tmpfs. **copytoram, Secure Boot signing, and multi-version rollback are the work this document decides.** Everything below is the N-slot extension of what v0 already proves.

---

## 1. The boot model — DECIDED

### 1.1 The keystone: verity, not LUKS, for the OS

The RAM-root is **dm-verity (integrity), never LUKS (confidentiality)**. Consequences that drive the whole design:

- The OS reaches a fully working state (network, `sshd`) with **zero secrets entered**.
- A missing/degraded data pool is *naturally* non-fatal — the OS isn't on it.
- No unlock secret ever sits on the unencrypted ESP.
- The single human action in normal operation is entering the **data** PIN once.

The verity roothash is **public** and lives **inside a Secure-Boot-signed UKI**, so Secure Boot transitively authenticates every block of the OS *with no on-disk secret*. The multi-version decision must preserve this keystone — it is the reason CoW is rejected.

### 1.2 Multi-version rollback: MULTIPLE SIGNED VERITY IMAGES — not CoW, not hybrid

**DECISION.** Each bootable version is an **independent read-only erofs `/usr` image + its own dm-verity hash tree**, pinned by a roothash baked into its **own** Secure-Boot-signed UKI. N such slots live on the stick; `systemd-boot` enumerates them; boot-counting rolls back. This is the upstream `systemd-sysupdate` A/B/C… model and the direct N-slot extension of v0.

**Rejected — CoW generations (btrfs/bcachefs, snapper/NixOS-generations style):**

- A mutable store has **no single static roothash to sign**. Secure Boot then covers only kernel+initrd, *not* `/nix/store` → an attacker who pulls the stick edits any store file offline and the validly-signed kernel boots it. That is exactly the evil-maid attack nixnas exists to defeat.
- Every retrofit costs the keystone: **dm-integrity** (HMAC) needs a *secret* key at mount time (a verity roothash is *public*) → either readable on the ESP or TPM-sealed, which puts a secret back on the **OS-boot critical path**; **fs-verity/IMA** is per-file, misses filesystem metadata (which files exist, symlinks, the generation pointer), and is Android-class bespoke, not appliance-grade.
- The "many cheap versions" win is mostly **Nix's store-path sharing, not btrfs CoW** — and nixnas has *no mutable OS state to snapshot* (`/` tmpfs, store immutable, data on separate ZFS). CoW would be near dead weight.
- **bcachefs is out of the mainline kernel as of 6.18 (Sept 2025), DKMS-only** — disqualifying for a minimal signed-kernel boot path. btrfs is the only viable CoW and buys little.

**The evil-maid tradeoff we accept, stated honestly.** Verity gives **unconditional, secret-free, signature-anchored integrity of the whole OS**, and pays with **zero block sharing** between versions — so the version count is a pure bytes game (§2). We choose maximal integrity over cheap version count. This is the deliberate inverse of CoW (which would give dozens of cheap generations but a mutable, evil-maid-exposed store). The hard requirement "at least two" is met unconditionally on 8 GB; "ideally several" is bought with compression + a slim base, not with sharing.

### 1.3 Slots, menu, rollback, boot-counting

- **Per version:** a `store_<v>` erofs partition + a `store-verity_<v>` hash partition + a signed UKI `EFI/Linux/nixnas_<v>+N.efi` whose **signed** cmdline carries `roothash=<that version's hash>`. The roothash is inside the PE signature → each UKI is cryptographically pinned to exactly its own store.
- **systemd-boot Automatic Boot Assessment** is the single mechanism for menu + counting + rollback: `+N` tries in the filename, decremented at each boot start, the entry marked bad and ordered last after N failures → automatic fallback to the previous version. A healthy boot has `systemd-bless-boot` strip the counter. **Manual rollback = pick an older entry** (its store is intact; only the oldest slot is recycled).
- **The "good" gate is liveness-only** (network + `sshd` up; data pools imported *or explicitly skipped*) before `bootctl good` — never "every service perfect," or a healthy slot burns its tries.
- **Tamper → rollback:** `verity.mode=panic` → a tampered block panics → failed boot → tries decrement → auto-rollback. Verity integrity is wired into the same machinery as a bad update.
- **Slots are fixed, pre-declared at build time** (`systemd-repart` cannot grow a slot). `systemd-sysupdate` (`InstancesMax=N`, suffix `@v`) rotates new versions into them and GCs the oldest. You commit to `N × max-image-size` up front.
- ⚠️ Pin/verify the boot-counting option name (`boot.loader.systemd-boot.bootCounting` / `boot.uki.tries`) against the pinned nixpkgs — it churned through renames and is the single most version-sensitive piece.

### 1.4 copytoram (orthogonal to N)

The **selected** version's erofs + hash images are copied into tmpfs/zram, then `losetup` both, `veritysetup open <data> store <hash> <roothash-from-signed-UKI>`, and `/usr` is mounted read-only from RAM; the stick goes idle/removable. dm-verity verifies the *compressed* blocks, so integrity survives the RAM copy; decompression is lazy at read. **RAM cost = one image (~1–3 GiB) regardless of how many versions are on the stick** — trivial on a NAS. Adding versions costs **stick bytes only**, never RAM and never boot complexity.

---

## 2. On-stick filesystem + GPT layout — DECIDED

### 2.1 What is FAT, what holds versions

- **ESP = FAT32, the only FAT** (UEFI mandates it). Holds signed `systemd-boot` + the N signed UKIs + `loader/` entries. Each UKI is just kernel + minimal initrd + cmdline (the heavy `/usr` is the *separate* verity image), so a UKI is ~60–90 MiB.
- **Version slots = raw GPT partition pairs** (`store_<v>` erofs + `hash_<v>` verity), **not** wrapped in any general-purpose filesystem. This is exactly nixpkgs `repart-verity-store`'s structure (v0 already emits it) and is what dm-verity + sysupdate partition-matching want. **DECISION:** drop the earlier "f2fs partition holding squashfs images" framing — bare partition pairs are cleaner and match the tooling.
- **One small writable `state` partition** (f2fs, flash-friendly; optionally LUKS) holds: `systemd-sysupdate` state, `machine-id`, TPM2 enrollment metadata, the encrypted recovery-key escrow blob, and **the persisted SSH host key that derives the sops age identity**. Tiny and non-boot-critical; its integrity comes from encryption + signing of what it points at, not verity.

### 2.2 Compression buys the version count

erofs + **zstd** (Linux ≥6.6, `-Ededupe -Efragments`) compresses a Nix/k3s closure ~2–2.5×. **Density, not block-sharing, is what fits several versions.** `squashfs`+dm-verity is a clean fallback with identical trust properties; erofs is preferred for flash random-read. **DECISION: erofs-zstd.**

### 2.3 The size reality (8 GB is a bytes game)

No sharing → N versions = N × full compressed image. Per-slot cost depends entirely on whether the operator's ROCm userspace + `linux-firmware` + container images live in `/usr`:

| Base | Per slot (erofs-zstd) | 8 GB (~7.45 GiB usable) |
|---|---|---|
| **Fat** (ROCm/firmware/images in `/usr`) | ~1.5–3 GiB | **2** (the A/B floor) |
| **Slim** (images + ROCm userspace on the ZFS pools) | ~0.7–1.2 GiB | **4–5** |

`linux-firmware` (amdgpu blobs) is a hard floor that keeps the base from shrinking arbitrarily. **"At least two" is met on 8 GB unconditionally; "ideally several" needs a slim base or a 16–32 GB stick** (4–6 fat / 8–12 slim). Slimming the base is the single highest-leverage knob — it roughly doubles the slot count at any stick size, with full verity integrity preserved.

### 2.4 Recommended GPT layout (8 GB, N=3 slim default)

```
GPT, 8 GB USB (~7.45 GiB usable)

#1  ESP        FAT32        1024 MiB  systemd-boot + N signed UKIs + loader entries
#2  store_v1   erofs-zstd  ~1900 MiB  read-only /usr v1 (sized for the LARGEST future image)
#3  hash_v1    raw           ~24 MiB  dm-verity Merkle tree for #2
#4  store_v2   erofs-zstd  ~1900 MiB  v2
#5  hash_v2    raw           ~24 MiB
#6  store_v3   erofs-zstd  ~1900 MiB  v3
#7  hash_v3    raw           ~24 MiB
#8  state      f2fs(+LUKS)  ~384 MiB  sysupdate state, machine-id, TPM enroll meta,
                                       recovery escrow, persisted host key
```

Slots #2–7 are created/rotated by `systemd-repart` + `systemd-sysupdate` (labels `store_@v` / `hash_@v`). `1024 + 3×(1900+24) + 384 ≈ 7.2 GiB` → fits. For a **fat** base, drop to **N=2**. Slot size is fixed for the largest image you will ever ship — **measure the real `image.repart` output before committing** (the dominant unknown; ROCm + firmware can push it higher).

**Boot/runtime flow per version:** UEFI (Secure Boot, operator keys) → signed `systemd-boot` → selected signed UKI → initrd does copytoram + `veritysetup` against the cmdline roothash → `/usr` read-only from RAM → stateless OS up → **single-passphrase LUKS/TPM2-PIN** unlock of the **separate** data pools (non-fatal). **Trust chain:** operator PK/KEK/db → signed UKI → roothash in cmdline → dm-verity Merkle tree → every `/usr` block. Nothing in that chain is mutable or CoW — that is the whole point.

---

## 3. Crypto — DECIDED (keystone unchanged)

- **Single passphrase → all LUKS.** Every data LUKS device (the operator's pool members + SMR disks) carries the *same* TPM2+PIN enrollment; `systemd-cryptsetup` caches the entered secret in the kernel keyring and reuses it across devices → entered **once**. **Never bake a static keyfile** — the ESP is unencrypted and the image is published FOSS; any embedded keyfile defeats encryption-at-rest. Verify keyring reuse actually fires across all devices.
- **TPM2 + PIN.** `systemd-cryptenroll --tpm2-with-pin=yes`; the PIN *is* the passphrase, folded into the TPM2 policy session → a phished PIN is useless without the physical TPM. **Baseline PCR 7** (Secure Boot state): stable across A/B UKI updates → **no reseal on normal updates**; PCR 7's classic fake-LUKS weakness is closed by the mandatory PIN. **Phase-2:** bind to a *signature* of expected **PCR 11** (the measured UKI), re-signed by the hub at each bake, enrolled once → adds initrd/kernel attestation. No turnkey path; budget custom hub tooling.
- **AMD fTPM caveat.** A BIOS update or NVRAM/CMOS clear **wipes the fTPM** and all sealed keyslots → the **recovery keyslot is mandatory**, treat fTPM-loss as a *when*. Bind the **SHA-256** bank explicitly (some fTPMs expose a SHA-1 bank that trips signed-policy bugs).
- **Recovery keyslot + escrow.** One break-glass recovery key (fixed slot index) on all devices; idempotent upsert to an **off-box** Vaultwarden (survives total NAS loss) via the Bitwarden CLI from sops creds, **at enroll / rotate only — never per update** (A/B touches only the UKI/PCR signature; data keyslots are untouched).
- **Non-fatal import.** Unlock data LUKS in **stage-2** (after the OS is up), `nofail` + short `x-systemd.device-timeout`; import pools via a **`Wants`-only** post-boot service kept **off `local-fs.target`** — a missing pool simply doesn't import, a degraded pool imports degraded, the box is up regardless. `boot.zfs.devNodes = "/dev/disk/by-id"`. nixnas **imports + unlocks** operator-built pools; it never creates/formats/destroys. Verify the unit graph under a pulled-disk test.
- **Remote unlock.** PRIMARY = **stage-2 `sshd` over Tailscale** (full userland, no secret in the UKI). The verity RAM-root makes this strictly more robust than initrd-SSH (which would stage a node key onto the public boot medium). The single manual gate is the PIN, once — at the BMC/SOL console or over the tailnet.

---

## 4. The flake / TUI workflow — DECIDED

- **`nixnas.config`.** The operator sets `nixnas.*` (`hostName`, `boot.*`, `crypto.*`, `storage.{pools,smrDisks}`, `tailscale`) and imports their *own* k3s/GPU/shares; the whole `toplevel` closure is what gets baked into the verity `/usr`.
- **`lib.mkImage host = host.config.system.build.image`** — the entry point that returns the signed, verity, multi-slot image.
- **The Rust TUI (`tui/`) runs the pipeline LOCALLY**, on a trusted machine holding the signing keys. The image is personalised (the operator's config) **and** signed with the operator's *own* Secure Boot keys → it can be neither pre-built generically nor built on the k3s it will host (chicken-and-egg). Stages, install-only:
  1. **BUILD** — `nix build .#nixosConfigurations.<host>` → erofs `/usr` → `veritysetup format` → roothash `R`.
  2. **SIGN** — `ukify` with `init=… copytoram roothash=R …` inside the PE → `sbsign --key db.key` the UKI **and** `systemd-boot`. `db.key` is sops-decrypted then shredded; Microsoft keys are not enrolled.
  3. **SEAL** — predict PCR 7 (and, phase-2, `systemd-measure sign` PCR 11) → ship the policy with the slot.
  4. **ESCROW** — ensure the recovery keyslot exists; idempotent upsert to `<vaultwarden-url>` from sops creds.
  5. **FLASH** — write the `.raw` (install) to the stick.
- **Updates run nix-side on the running box.** No TUI, no re-flash: a new `toplevel` → new signed UKI + verity image → written to the **inactive** slot (`systemd-sysupdate`-style) → reboot → boot-counting rolls back if the new slot fails its health gate. The live slot, `state` partition, and config are never touched.
- **Keys never leave the provisioning machine.** FOSS-core (`nixnas`, parameterised) ← consumed as a flake input by the private overlay (`nixnas-hosts`: serials, URLs, the `nixosConfigurations`) ← secrets (sops). The public repo never imports the private one.
- **Demo host** (`hosts/demo`, RFC-5737/RFC-2606 placeholders) proves the core evaluates and the image builds with zero secrets in CI; real TPM/SecureBoot need a manual hub checklist (+ optional swtpm VM check).
