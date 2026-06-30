# nixnas — ARCHITECTURE.md

FOSS-clean: every site value is a parameter (a typed `nixnas.*` option), never a literal.

## 0. The model, in one line

nixnas is **standard NixOS — encrypted, Secure-Boot-signed, self-updating via
generations — packaged to install on a USB stick and boot into RAM, driven by a
flake.** Updates, rollback, multiple versions and signing are *not* bespoke: they are
NixOS's own `system.autoUpgrade`, generations, `lanzaboote`, and LUKS. nixnas adds only
three things: the **USB image/layout**, **copytoram**, and a **build+flash TUI**.

> **Supersedes** the earlier read-only dm-verity *image-appliance* model. That model
> requires building + signing + delivering each immutable version **externally**
> (`systemd-sysupdate` pulls from a source). nixnas has **no provisioning machine** and
> the box must **update itself autonomously** — so the image-appliance model is the
> wrong fit. v0 (verity erofs `/usr` + `image.repart`) was a useful boot-chain spike;
> the on-stick storage now pivots to an encrypted mutable store + native generations.

## 1. Why native self-update, not a verity image

| Requirement | Verity image | Native self-update (chosen) |
|---|---|---|
| Autonomous on-box update | ✗ needs external build+sign+deliver | ✓ `autoUpgrade` rebuilds on the box |
| Several versions on **8 GB** | ✗ no block sharing → ~2–5 | ✓ store-sharing → many cheap generations |
| Minimal custom software | ~ (sysupdate glue) | ✓ all native (autoUpgrade/generations/lanzaboote/LUKS) |
| Evil-Maid | ✓ block-integrity (verity) | ✓ integrity-by-**encryption** + signed boot (§6; weaker only vs a replay attack) |

The 8 GB constraint is non-negotiable (Unraid installs from 8 GB; low switching
barrier). Native generations are the only model that gives *several* versions on 8 GB
*and* autonomy *and* minimal custom — the price is integrity-by-encryption instead of
integrity-by-verity, weighed honestly in §6.

## 2. On-stick layout (8 GB USB, GPT)

```
#1  ESP        FAT32     ~768 MiB  lanzaboote-signed systemd-boot + one signed UKI per
                                    bootable generation + loader/ entries
#2  nixos      LUKS2     ~6.3 GiB  the NixOS system: /nix/store (mutable, all kept
                                    generations) + the nix profile/generation list +
                                    machine-id + the persisted SSH host key (sops age id)
```

Data lives on the operator's **separate** encrypted ZFS pools — never on the stick.
Each generation's UKI (kernel + minimal initrd) is ~60–90 MiB, so the **ESP** is the
tighter bound on generation count: ~8 in 768 MiB. The store side is cheap (base once +
deltas). Keep a sane limit (`boot.loader.systemd-boot.configurationLimit`).

## 3. Boot flow + copytoram

1. UEFI — **Secure Boot with the operator's own keys** + firmware setup password.
2. **lanzaboote-signed `systemd-boot`** shows the generation menu.
3. The selected generation's **signed UKI** runs; its **signed initrd** prompts the
   **single passphrase** → unlocks the LUKS `nixos` partition. *Secure Boot guarantees
   the prompt is trusted — a maid cannot phish the passphrase with a tampered initrd.*
4. **copytoram:** the initrd copies the *selected generation's* closure into a tmpfs
   `/nix/store`, pivots, and runs from RAM; the stick goes idle (spared at runtime).
5. The stateless OS comes up; the operator's **data pools** import **non-fatally**
   (same passphrase via kernel-keyring reuse).

## 4. Updates — autonomous, native

- **`system.autoUpgrade`** periodically pulls the operator's flake (their `infra` repo)
  and `nixos-rebuild boot`s a new generation — **built on the box**, written into the
  LUKS store. No provisioning machine, no external delivery.
- **`lanzaboote`** signs the new generation's UKI **on the box**; the Secure Boot `db`
  signing key lives inside the LUKS store (protected at rest by the same passphrase).
- **Rollback:** the generation menu is always there (manual rollback to any kept
  generation — its closure is in the store). Automatic rollback on a failed boot via
  systemd-boot **boot-counting** is the bonus (`boot.uki.tries`; verify lanzaboote wires
  it — §9). The "good" gate is **liveness-only** (network + `sshd`; pools imported *or
  skipped*) before the generation is blessed.
- **GC:** `nix.gc` + the generation limit keep the store inside 8 GB.

## 5. Multiple versions on 8 GB — the "snapshot" win, for free

The thing that makes *several* versions fit is **Nix store-path sharing**, not a CoW
filesystem: N generations of one NixOS+k3s system share ~the whole base (kernel,
systemd, k3s, containerd, glibc…) — only changed paths add bytes. This is exactly the
"snapper feel" — and it is simply **how NixOS's store already works**. No btrfs, no
bcachefs (out of mainline 6.18 anyway), no custom snapshot logic.

## 6. Crypto / Evil-Maid

- **LUKS2** on the OS store **and** the operator's data pools; **single passphrase that
  *is* the TPM2 PIN**; one **recovery keyslot** escrowed off-box. `systemd-cryptsetup`
  reuses the entered secret across devices via the kernel keyring → entered **once**.
- **Evil-Maid posture = encryption + signed boot.** The OS store is encrypted (a maid
  can neither read the config nor inject a payload); `lanzaboote` Secure-Boot-signs the
  boot chain (no unsigned kernel runs); the firmware password blocks disabling SB.
- **Honest delta vs verity:** verity cryptographically pins the *exact* OS bytes via a
  signed roothash; encryption does not, so a sophisticated maid with an *old* encrypted
  store image could attempt a **rollback/replay** attack. Mitigation: a monotonic
  anti-rollback counter (TPM NV / the state partition); for a home NAS the residual risk
  is low. **This is the one place native self-update is weaker than the verity image —
  the deliberate price of autonomy + many versions on 8 GB.**
- **TPM2 + PIN**, PCR 7 baseline (stable across updates), recovery keyslot mandatory
  (AMD fTPM is wiped by a BIOS/NVRAM clear), SHA-256 bank. Non-fatal pool import
  (`Wants`-only, off `local-fs.target`, `boot.zfs.devNodes=/dev/disk/by-id`). nixnas
  **imports + unlocks** operator-built pools; it never creates/formats/destroys.
- **Remote unlock:** the OS store is encrypted, so the *first* unlock happens in the
  **initrd**. Initrd-SSH-over-Tailscale is therefore on the table for headless remote
  boot (§9 weighs initrd-ssh vs BMC/SOL); a full stage-2 unlock no longer applies to the
  OS store (only to data pools, if those are deferred).

## 7. The flake / TUI workflow

- **Build once, here.** A capable machine (the cluster) evaluates the operator's
  `nixosConfiguration` and `lib.mkImage` produces the initial USB image (LUKS store
  seeded with generation 1 + the lanzaboote keys + the signed UKI). The **Rust TUI**
  flashes it. The TUI is **install-only** — it is *not* in the update path.
- **After flashing, the box is autonomous** (`autoUpgrade`). Updating nixnas =
  committing to the operator's flake; the box pulls + rebuilds itself.
- **`nixnas.config`** = the operator's `nixnas.*` parameters + their own
  `services.k3s`/`hardware.amdgpu`/… — the whole closure is what gets installed.

## 8. What is nixnas-specific (everything else is stock NixOS)

1. The USB **GPT/disko layout** + `lib.mkImage`.
2. **copytoram** — the initrd copy-to-RAM + pivot. *The one genuinely custom mechanism.*
3. The **Rust TUI** (build the initial stick + flash + edit `nixnas.config`).
4. Packaging Secure Boot (lanzaboote keys) + the LUKS-store-on-USB into a flashable image.

Generations, rollback, self-update, and signing are **stock NixOS** — `autoUpgrade`,
the bootloader's generation list, `lanzaboote`, LUKS. nixnas is a thin packaging of a
well-trodden encrypted-Secure-Boot-autoUpgrade NixOS onto USB + RAM + a flake workflow.

## 9. Open questions — the steelman targets

1. **copytoram × a self-updating mutable store.** Does "copy the active generation's
   closure to tmpfs + run from RAM, while `autoUpgrade` writes new generations to the
   persistent LUKS store" compose cleanly? (Store-on-tmpfs + persistent store for writes.)
2. **lanzaboote boot-counting.** Does lanzaboote wire systemd-boot `+tries` for
   automatic rollback, or is only the manual generation menu guaranteed?
3. **The encrypted-store replay attack.** Is an anti-rollback counter worth it, or is
   the residual risk acceptable for a home NAS?
4. **First-unlock location.** OS store is encrypted → first unlock is in initrd: local
   passphrase (BMC/SOL) vs initrd-SSH-over-Tailscale for headless remote boot.
5. **The on-box Secure Boot signing key.** Acceptable that the `db` key lives in the
   LUKS store (so the box can self-sign generations), or does that weaken Evil-Maid?
6. **Generation count vs ESP size** on 8 GB (one ~80 MiB UKI per generation).
7. **autoUpgrade against a private flake** (pull auth) + whether a rebuild that writes
   the persistent store while running from a tmpfs store behaves.
