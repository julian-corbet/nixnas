# nixnas — DESIGN.md

A bare-metal, fully declarative NixOS appliance that replicates the operating model of a USB-booted Unraid NAS: an OS that lives entirely in RAM, A/B signed images with automatic rollback, measured/encrypted-at-rest data, and a k3s + Podman + system-container compute layer — all delivered by a build hub, never built on the node.

> **Wording note.** This document is FOSS-clean. Every site-specific value (hostnames, IPs, disk serials, Tailscale node names, Vaultwarden URL, pool names) is a **parameter** (`<…>` or a typed option), never a literal. The private instantiation lives in a separate overlay flake (see "FOSS separation").

---

## 1. Architecture overview

nixnas is the **storage + compute anchor node** of a larger fleet. It is NOT the app host of record — identity/mail/secrets services already live off-box, and ~30 application workloads already run on an in-cluster k3s plane. nixnas replaces the *Unraid substrate* under that compute, not the apps themselves.

Four layers, bottom to top:

1. **Boot substrate** — 8 GB USB stick, GPT, FAT ESP + f2fs store. Two A/B slots, each one signed Unified Kernel Image (UKI). The OS root is a dm-verity-protected squashfs copied entirely into RAM (`copytoram`); the stick is read-only at runtime except the per-boot boot-counter rename and hub-pushed updates.
2. **Crypto / data-at-rest** — every data device is LUKS2 with the filesystem directly on the decrypted mapper (LUKS-under-ZFS for the two pools, LUKS-under-xfs/btrfs for the SMR disks). A single passphrase (which *is* the TPM2 PIN) unlocks all of them. The RAM-root itself holds **no** secret and is integrity-only (verity), so the OS boots to a fully working state — Tailscale up, sshd up, k3s control-plane up — **before** any passphrase is entered. The passphrase gates *data*, never *boot*.
3. **Compute** — native declarative k3s (the bulk of workloads), Podman/Quadlets (tier-0 host glue that must survive k3s being down), an Arch Linux system container (mutable pet userland + GPU desktop), and a minimal libvirt for the permanent Windows VM(s). Docker is retired.
4. **Delivery** — a build-sign-seal-escrow-deliver pipeline that runs exclusively on the build hub. The node receives a finished, signed A/B slot and flips a pointer.

### The architectural keystone

Because the RAM-root is **dm-verity (integrity), not LUKS (confidentiality)**, there is no encrypted root filesystem to unlock at boot. This single fact simplifies four downstream problems:

- The box reaches a fully working OS with zero secrets — so a degraded/missing data pool is *naturally* non-fatal (the OS isn't on it).
- "Remote unlock" no longer *requires* the fragile initrd-SSH path; data can be unlocked from a full stage-2 userland over normal Tailscale SSH.
- No unlock secret ever sits on the unencrypted ESP.
- The one deliberate human action in normal operation is entering the LUKS PIN once. Everything else is zero-touch — satisfying the PRIME DIRECTIVE: *if you are typing anything other than the PIN, something has gone wrong.*

### Grounding in the current system (recon)

The current machine already implements the hardest storage decisions nixnas keeps, which de-risks the migration:

- **Both ZFS pools are already LUKS2-under-ZFS** (`sdX1 → crypto_LUKS → crypt → zfs_member`): a HOT SSD pool (3× mirror) and a COLD HDD pool (5-wide raidz1). aes-xts-plain64, argon2id, 512-bit. No TPM2 binding exists today — that is greenfield.
- **The single-passphrase-unlocks-all model already exists** for the 5 whole-disk-LUKS SMR drives (sector 4096), unlocked by serial via a watcher that captures the array passphrase into tmpfs, opens all five, then shreds the key. nixnas replicates this exact serial map declaratively.
- **k3s already runs** (single control-plane node, ZFS snapshotter, zfs-localpv PVs, MetalLB, Tailscale operator, Argo CD, GitOps spine) — currently nested inside an LXC under Unraid. nixnas lifts it onto the metal. This is the strongest argument for the whole project: k3s already *wants* NixOS; the LXC was a workaround for running it under Unraid.
- **The board is confirmed** GIGABYTE (MC12-LE0 family), AMI firmware, IPMI 2.0 + ASPEED BMC at a parameterized LAN IP, SOL on `ttyS0@115200` already wired into the current boot. TPM2 binding is not yet present.

---

## 2. Boot chain

### 2.1 RAM-root (copytoram + verity squashfs)

- **Mechanism.** Reuse the nixpkgs live-image building blocks but emit a *custom* image, not a live ISO and not `not-os` (which is systemd-less and would forfeit `services.k3s`, systemd-initrd, UKI tooling). Root `/` is `tmpfs`; `/nix/store` is an overlay of a read-only squashfs lower layer + a tmpfs upper layer.
  - `config.system.build.squashfsStore` packs the toplevel closure into a reproducible zstd squashfs.
  - `boot.initrd.systemd.enable = true` (mandatory — the verity-setup generator, TPM unlock, and SSH-in-initrd are all far cleaner under systemd-initrd).
  - `boot.kernelParams = [ "copytoram" "console=ttyS0,115200" "console=tty0" "verity.mode=panic" … ]`.
  - Build the image with `image.repart` (`system.image`) so the partition layout — FAT ESP + f2fs store + optional persist — is declarative and can emit verity data+hash partitions with a stable roothash.

- **The custom initrd step (the one genuinely bespoke piece).** Stock `copytoram` knows neither verity nor the loop/veritysetup dance. nixnas ships a small systemd-initrd service that:
  1. mounts the f2fs store read-only;
  2. copies `squashfs_<slot>.img` **and** `hash_<slot>.img` into a tmpfs (trivial on 128 GB);
  3. unmounts the USB store (stick now idle/removable);
  4. `losetup` both RAM files, `veritysetup open <data-loop> store <hash-loop> <roothash>` (roothash from the **signed** UKI cmdline);
  5. mounts `/dev/mapper/store` read-only as the overlay lower layer.

  This order is load-bearing: it keeps verity's per-block re-reads in RAM (sparing the stick) while still enforcing integrity. `verity.mode=panic` means a tampered block → panic → boot-count decrement → automatic A/B rollback (ties verity tamper to the rollback machinery).

### 2.2 A/B slots + automatic rollback

- **Mechanism.** systemd-boot "Automatic Boot Assessment" — UKIs in `EFI/Linux/` named with a `+<tries-left>-<tries-done>` suffix; systemd-boot renames on each boot and skips an exhausted entry for the next-best one. Boot counting was reinstated in nixpkgs mid-2026.
  - `boot.uki.tries` sets the initial count per slot.
  - `boot.loader.systemd-boot.bootCounting` (**verify the exact option name against the pinned nixpkgs** — it churned through several renames; this is the single most version-sensitive option in the design).
- **Slots are not NixOS generations.** The hub delivers finished signed UKIs, so the ESP simply holds two: `nixnas_A+3.efi` and `nixnas_B+3.efi`, with a glob `default`. The hub writes the new UKI into the *inactive* slot, flips `default`, reboots. The old slot stays bootable.
- **"Good" = nixnas's own health gate, not "kernel booted."** A oneshot reaches a custom `boot-complete.target` only when the box is liveness-healthy (network up, data pools imported *or explicitly skipped*, k3s control-plane up) and then runs `bootctl … good` to strip the counter. Keep the gate **liveness-only** — if it can hang on "every service perfect," a healthy slot will burn tries and roll back.

### 2.3 Signed UKIs with the user's own SecureBoot keys — **no lanzaboote**

- **Decision: do NOT use lanzaboote here.** Lanzaboote is architected around NixOS generations + the bootspec document; it *owns* the ESP layout and the generation→entry mapping, and it cannot be handed two pre-built A/B UKIs to "just sign and place." With only two slots, the ESP-bloat problem lanzaboote solves does not exist, so self-contained systemd-stub UKIs are simpler and stronger.
- **Build + sign (hub-side).**
  1. `boot.uki` → `config.system.build.uki`, default stub = systemd-stub, assembled via `ukify`. The cmdline (`init=… copytoram roothash=<R> …`) is **inside** the signed PE, so the verity roothash is covered by the signature and measured into PCR 11.
  2. Generate own keys with `sbctl create-keys` (PK/KEK/db); private db key stays on the hub only. Microsoft keys are NOT enrolled. Enroll PK/KEK/db into AMI firmware in Custom mode + set the firmware admin/setup password so the keys can't be cleared.
  3. `sbctl sign` / `sbsign --key db.key --cert db.crt` the UKI **and** the systemd-boot binary (and `BOOTX64.EFI` fallback).
- **Chain of trust.** firmware (own PK/KEK/db) → signed systemd-boot → signed UKI (sig covers kernel+initrd+cmdline+roothash) → initrd sets up dm-verity against that roothash. Tamper anywhere breaks a signature or the roothash.

### 2.4 USB layout (8 GB)

```
GPT:
  p1  ESP    FAT32  ~1.0–1.5 GiB  signed systemd-boot + EFI/Linux/nixnas_{A,B}+3.efi (signed UKIs)
  p2  store  f2fs   ~5.5–6.0 GiB  squashfs_{A,B}.img + hash_{A,B}.img  (read-only at runtime)
  p3  persist f2fs  optional ~256–512 MiB  (see "persistent state" below)
```
- **What MUST be FAT:** everything the firmware/systemd-boot reads — the bootloader, `loader.conf`, and the UKIs (systemd-boot must *rename* them for boot counting). UEFI mandates FAT on the ESP.
- **What CAN be f2fs:** the squashfs + verity-hash images (read only by the Linux initrd, which has the f2fs module). f2fs is log-structured/flash-friendly; mount `noatime,lazytime,background_gc=on`. Wear is near-zero anyway because the partition is read-only at runtime.
- **8 GB is tight.** Two self-contained UKIs dominate the ESP; two squashfs+hash pairs fill the store. Keep the base OS store minimal (push bulky workloads to k3s/podman images on the ZFS pools, not into the base image); measure `squashfsStore` output early.
- **Persistent state goes on ZFS, not the stick.** The OS is in RAM and pool-independent. The only state that must survive *before* pools unlock is essentially nothing — except the SSH host key used to derive the sops age identity (see "Secrets"), which needs a tiny persisted location or a pool that unlocks before activation. Keep the stick read-only except (a) the per-boot tries rename and (b) hub-pushed updates.

---

## 3. Crypto / TPM

### 3.1 Single passphrase → all LUKS devices

- **Recommended: same-secret keyring reuse.** Every LUKS device (the 2 ZFS-vdev member sets + 5 SMR disks) carries the *same* TPM2+PIN enrollment; systemd-cryptsetup caches the entered secret in the kernel keyring and tries it against subsequent devices before re-prompting → entered **once**. Per-device tuning via `boot.initrd.luks.devices.<name>.crypttabExtraOpts`. Do **not** rely on the legacy scripted-initrd `reusePassphrases` flag (known-flaky, and scripted initrd is retiring). **Verify** keyring reuse actually fires across all devices in your build.
- **Never bake a static keyfile.** The UKI/initrd sits unencrypted on the ESP and the verity squashfs is a to-be-published FOSS image — a keyfile in either is readable by anyone who pulls the stick and defeats encryption-at-rest. If a keyfile cascade is ever used, the keyfile must be *derived at runtime* from a LUKS device the human secret opened, never embedded.

### 3.2 TPM2 + PIN binding

- **Enrollment (per device, hub-side):**
  ```
  systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes \
    --tpm2-pcrs=7 --wipe-slot=tpm2 /dev/disk/by-id/<luks-partition>
  ```
  NixOS: `boot.initrd.systemd.enable = true` + `boot.initrd.systemd.tpm2.enable`. The PIN *is* the single passphrase; `--tpm2-with-pin=yes` folds it into the TPM2 policy session, so a phished PIN is useless without the physical TPM whose PCRs match.
- **PCR choice — baseline PCR 7 + PIN.** Because you enroll your own SecureBoot keys and don't enroll Microsoft keys, PCR 7 (SecureBoot state) is sufficient to gate unlock, and crucially **PCR 7 does NOT change across an A/B UKI update** → **no reseal on normal OS/kernel updates** (a major automation win). PCR 7's classic weakness (the evil-maid fake-LUKS bypass) is exactly what the mandatory PIN closes: the attacker's fake partition triggers a PIN prompt they can't answer.
- **Phase 2 hardening — signed PCR 11 policy.** Bind to a *signature of expected PCR 11 values* (the measured UKI) rather than literal values, so the keyslot survives UKI changes without re-enrollment:
  ```
  # hub, at each image bake, after building the new UKI:
  systemd-measure sign --public-key=pcr-pub.pem --private-key=pcr-priv.pem \
    --bank=sha256 --phase=… > pcr-sig.json
  # enroll ONCE against the public key (not literal PCRs):
  systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes \
    --tpm2-public-key=pcr-pub.pem --tpm2-public-key-pcrs=11 \
    --tpm2-signature=pcr-sig.json /dev/…
  ```
  The `.pcrsig`/`.pcrpkey` sections are embedded in the UKI via ukify; the hub re-signs expected PCR 11 at every bake; the keyslot is enrolled once. This adds initrd/kernel-content attestation PCR 7 lacks. **Flag:** there is no turnkey path for this; budget custom hub tooling and watch the still-sharp systemd signed-policy edge cases.

### 3.3 AMD fTPM caveats (this board)

- fTPM state lives in SPI/BIOS NVRAM: a BIOS update or CMOS/NVRAM clear **wipes the fTPM**, losing all sealed keyslots. This makes the recovery keyslot **mandatory**, not optional — treat fTPM-loss as a *when*.
- Bind explicitly to the **SHA-256** bank; some AMD fTPMs expose a SHA-1 bank that trips signed-policy bugs. **Verify** `tpm2_pcrread` bank list and whether fTPM vs a discrete TPM module is active (`systemd-cryptenroll --tpm2-device=list`).
- Dictionary-attack lockout on repeated wrong PINs is annoying but not fatal — the recovery key bypasses the TPM entirely.

### 3.4 Recovery keyslot + Vaultwarden escrow

- **Generate** a purpose-built break-glass key per device with `systemd-cryptenroll --recovery-key …`; use the **same** recovery key (fixed slot index) on all devices so one secret opens everything.
- **Escrow (hub-side, fire-and-forget).** Vaultwarden lives **off the NAS** (on the fleet's small cloud box, reachable at a parameterized `<vaultwarden-url>` via its public tunnel), so the escrow target survives total NAS loss — correct for a recovery secret. Push via the Bitwarden-compatible CLI using a **personal API key** (`BW_CLIENTID`/`BW_CLIENTSECRET` → `bw login --apikey` → `BW_SESSION` from `bw unlock`), with an **idempotent search-then-edit/create** upsert into a type-2 secure note. Run in an ephemeral `HOME` and `bw logout` after, so no logged-in profile leaks. Creds come from sops; the recovery key and creds are never logged.
- **Self-reference hazard:** escrow is a *backup* path only. The TPM2+PIN passphrase (and the stage-2 Tailscale remote unlock) is primary. If the *only* unlock path depended on reaching `<vaultwarden-url>`, an outage there would stall recovery. Treat the escrow write as belt-and-braces.
- **When:** at initial enroll and on an explicit `rotate-recovery` operation only — **never** per A/B update (A/B touches only the UKI/PCR signature; data keyslots are untouched).

### 3.5 Non-fatal pool import

- `boot.zfs.devNodes = "/dev/disk/by-id"` (stable; avoids FAULTED/DEGRADED-on-`sdX` churn).
- Unlock data LUKS in **stage-2** (after the OS is up), mark devices `nofail` + a short `x-systemd.device-timeout`.
- Import pools via a dedicated post-boot service (`boot.zfs.extraPools` style) that is **`Wants`-only, never `Requires`**, and **kept off the `local-fs.target` critical path** — a degraded pool imports degraded, a missing pool simply doesn't import, the box is up regardless. **Verify** the exact unit graph under a pulled-disk test; ZFS+systemd ordering routinely bites here (a `nofail` mount can still block via `RequiresMountsFor`).
- k3s/Podman/libvirt workloads that need pool data are `Wants`/`After` the pool, never `Requires` — degrade gracefully.

### 3.6 Remote unlock + the single manual gate

- **Primary (recommended): stage-2 sshd over Tailscale.** The OS boots fully into RAM with no secret, Tailscale + sshd come up normally, and you SSH in over the tailnet and answer the data-LUKS prompt with `systemd-tty-ask-password-agent --query`. This uses the full robust userland network stack, keeps **no secret in the unencrypted UKI**, and keeps the FOSS core clean.
- **Documented fallback: SSH-in-initrd over Tailscale** (the literal locked capability). systemd-initrd ships sshd (`boot.initrd.network.ssh`); Tailscale-in-initrd is community-only and stages `tailscaled` + a node key into the initrd — which means a secret on the public boot medium and extra FOSS-split complexity. Keep it documented and available, but the RAM-root makes the stage-2 path strictly more robust. (See Decisions — this is the one place the locked design admits a cleaner mechanism.)
- **The single manual gate:** enter the LUKS PIN once — locally at the BMC/SOL console or remotely via Tailscale SSH. Everything else (escrow, hub-side reseal-signing, pool import, service start) is zero-touch.

---

## 4. Compute layer

### 4.1 Three engines, one host

| Engine | NixOS mechanism | Runtime | Network |
|---|---|---|---|
| **k3s** | `services.k3s` (in-tree) | bundled containerd + runc | flannel, default `10.42.0.0/16` |
| **Podman/Quadlets** | `virtualisation.quadlet.*` (quadlet-nix flake) | crun/runc under systemd generator | netavark + podman bridge `10.88.0.0/16` |
| **Arch system container** | `virtualisation.incus` (recommended) | LXC | `incusbr0`, operator-chosen subnet |
| **Windows VM(s)** | `virtualisation.libvirtd` + NixVirt | KVM/QEMU | libvirt `192.168.122.0/24` |

- **The real coexistence hazard is L3, not cgroups.** cgroup v2 + systemd give each its own sub-tree, no conflict. But four things rewrite host firewall/forwarding tables. Mitigations baked into the core:
  - Standardize on **nftables** (`networking.nftables.enable = true`) so all backends share one table.
  - Every bridge a non-overlapping subnet; document them; only the Arch container's subnet is yours to pick — keep it off all defaults and off the LAN.
  - `boot.kernel.sysctl."net.ipv4.ip_forward" = 1` once; don't let `networking.firewall` blanket-drop FORWARD; add the bridges to `trustedInterfaces` where appropriate.

### 4.2 Division of labor

- **k3s** — the default home for all orchestrated app workloads (self-healing, GitOps-versioned, GPU-scheduled). New services land here.
- **Host-level Quadlets** — tier-0 glue that must survive k3s being down: a pull-through registry/cache mirror, a status/heartbeat or escrow-helper sidecar, anything that must be up before/independent of the cluster control plane. Quadlets are plain systemd units → up with the host, not the cluster.
- **Native NixOS host services (never containerized, never behind k3s)** — the storage/identity/health floor: `services.samba`, `services.nfs.server`, `services.smartd`, `services.zfs.*`, node-exporter/smartctl-exporter, Tailscale, the LUKS/TPM/escrow boot path. These touch the kernel/ZFS directly and must be the last things to fail.
- **Arch Incus container** — full mutable Arch userland NixOS can't cheaply provide: `pacman`/AUR/`makepkg`, GPU desktop streaming, "pet" continuity.

quadlet-nix surface: `virtualisation.quadlet.containers.<name>` with `containerConfig` (maps `[Container]` keys incl. `AddDevice=`/`GroupAdd=`/`AutoUpdate=registry`), `serviceConfig`, `unitConfig`, `autoStart`, `rawConfig` escape hatch. **Flag:** the exact camelCase for device/group passthrough is unverified — fall back to `rawConfig` with the authoritative quadlet keys if needed.

### 4.3 The Arch container — recommend Incus

`virtualisation.lxd` was removed from nixpkgs; **Incus** is the sanctioned replacement and the best fit for a pet, mutable, full-userland Arch system: declarative bootstrap via `virtualisation.incus.preseed` (profiles, networks, storage pools, the GPU device), snapshots, AppArmor confinement, first-class GPU device passthrough. **Caveat:** preseed is create-only (idempotent seed, never reconciles deletions). systemd-nspawn is lighter but its NixOS `containers.*` path assumes a NixOS guest and gives weaker GPU ergonomics for an Arch rootfs. (Recon note: today's box runs a *privileged, no-idmap* LXC via an Unraid plugin — Incus is the clean declarative successor; the no-systemd mount-race guard that plugin needs simply evaporates on NixOS.)

### 4.4 GPU — one card shared into both the Arch container and k3s

Host baseline (generic core): `boot.initrd.kernelModules = [ "amdgpu" ]`, `hardware.graphics.enable{,32Bit} = true`, ROCm userspace, `linux-firmware`. Device nodes: `card0` (display, **video** group), `renderD128` (render/compute, **render** group), `kfd` (ROCm compute, **render** group).

- **Pin the render GID** (`users.groups.render.gid`) and reuse the *same numeric GID* everywhere — containers map by number. This is the #1 silent "permission denied on /dev/kfd" cause.
- **Into the Arch container** (`card0` + `renderD128`): an Incus `gpu`-type device in the profile/preseed, plus a GID idmap so the in-container consumer group maps to the host render/video GID.
- **Into k3s** (`renderD128` + `kfd`): the shared-single-card contract is served best by **direct hostPath device mounts** (`renderD128` + `kfd` + `securityContext.supplementalGroups = <render GID>`) into the specific pods, rather than the ROCm k8s-device-plugin's whole-GPU exclusive-allocation model. The device-plugin DaemonSet remains an option for count-based advertising. AMD needs no special containerd runtime (unlike NVIDIA) — the plugin just bind-mounts char devices; health-checks need `privileged: true`.
- **Concurrency reality (existing field knowledge):** display (`card0`) and compute (`renderD128`/`kfd`) are largely independent engines; the Arch container holding `card0` and k3s pods holding `renderD128`+`kfd` coexist on one card. The constraint is **VRAM/dmem**, not device-node contention — keep the watcher-KILL preempt as the backstop. **Flag:** the *simultaneous* combination on bare metal has no single documented blueprint; render-GID pinning and the dmem cap are the load-bearing details.

### 4.5 Shares + health/monitoring (replace the Unraid web UI)

- **SMB:** `services.samba` with the structured `settings` schema (global = `settings.global`, each share = `settings.<name>`) exporting ZFS dataset mountpoints; pair `services.samba-wsdd` for Windows discovery. The dangerous Unraid "delete share = `zfs destroy` the dataset" failure class disappears — shares are nix config, decoupled from dataset lifecycle. Order `After` ZFS import so exports don't race the pool.
- **NFS:** `services.nfs.server.exports` (keep the existing posture — exported only to specific fleet peers; NFSv4-only needs just port 2049).
- **Health:** `services.smartd` (notifications) is the direct Unraid-SMART replacement (don't schedule long self-tests on SMR drives during writes). For the at-a-glance panel: **Cockpit** (`services.cockpit` + storaged/podman/machines plugins) or **Netdata**. For history/alerts: **node-exporter + smartctl-exporter on the host** (so health survives k3s down) → Prometheus → Grafana (host or k3s).

### 4.6 VMs

Keep `virtualisation.libvirtd` — minimally. Windows has no container substitute, so the permanent Windows VM stays a domain; the LUKS-under-ZFS pools present `/dev/zvol/<pool>/…` exactly as libvirt's `dev`-type disk expects. Declare domains via the **NixVirt** flake (takes libvirt XML, points `<disk>` at existing zvol paths, toggles run state) so the do-not-delete VMs are reproducible without `virsh` snowflakes. New Linux workloads go to containers/k3s, not VMs. The protected/do-not-delete zvols (Windows active/headless + placeholder zvols, the harvested desktop zvol, k3s datastore/token/PV datasets) carry over as KEEP and are never in a destroy batch.

### 4.7 HOT/COLD: explicit placement (shfs / FUSE union removed)

Unraid's tiering is three coupled proprietary pieces with no NixOS drop-in. The contract to reproduce:

1. **Union namespace** — Unraid's shfs FUSE unions the nested HOT (`<ssd-pool>/<tree>`) + COLD (`<hdd-pool>/<tree>`) child datasets into one path so apps see a single location regardless of which pool a file currently sits on.
2. **The mover** — must be: in-use-safe (skip open files via `fuser`/`lsof`), copy-verify-delete (never delete source before the destination verifies), **mtime-preserving** (transparent to apps), and **recordsize-re-blocking** (the rsync-style rewrite makes the cold copy adopt the COLD dataset's recordsize — load-bearing for landing data at the right block size per tier).
3. **Per-share AGE policy** — "cool after N days," NOT a pool-fill threshold, plus a **PINNED exclude-list**: certain children (S3/versitygw objects, IPFS blocks) must **never** be tiered, because moving them changes their key/endpoint and desyncs the object store's metadata.

**nixnas replacement — shfs OUT, no FUSE union; explicit per-dataset placement.**

The Unraid union was only a *presentation veneer*: the data already lives on explicit single-pool datasets; shfs merely made HOT+COLD look like one path. nixnas drops the union concept rather than re-implementing it (no shfs, **no mergerfs**).

- **Placement is an operator decision, per dataset.** Each dataset lives on exactly one pool — **HOT = the SSD pool, COLD = the HDD pool** — and the path is self-describing. There is no automatic mover and no transparent union; "tiering" is design-time placement set per dataset. Both pools are created **fresh** via `disko` and data is laid back down onto them, so placement is decided at build time, not migrated in place.
- **Optional speed-without-motion: a redundant ZFS `special` vdev** on the HDD pool (metadata + small blocks land on SSD) — most of the "hot data is fast" benefit with zero file motion and zero namespace tricks. Mirror it (`special`-vdev loss = dataset loss).
- **If lifecycle motion is ever wanted for a specific dataset**, it is an explicit, observable `systemd.timer` job (`rsync -aHAX`/`syncoid`, copy-verify-delete, never-auto-delete-on-doubt, with a PINNED exclude-list for S3/versitygw objects + IPFS blocks whose keys must not move). Placement *policy*, off by default — not a union.
- **sanoid/syncoid** are for snapshots + backup/offsite, never tiering (syncoid keeps the source).

---

## 5. The build-sign-seal-deliver HUB pipeline

**Doctrine: build on hub, never on node.** Every CPU-heavy or key-bearing step runs on the build hub; the node receives bytes and flips a pointer. nixnas as a 128 GB Ryzen box *can* itself be a build-capable `fat`-class machine, but the law is that a node never rebuilds *itself in place* past its class ceiling, and node-side convergence (autoUpgrade/Comin) is forbidden (it wedges constrained boxes). Updates are hub-pushed (deploy-rs over Tailscale) or image-routed.

```
┌────────────────────  BUILD HUB  ────────────────────┐
1 BUILD   nix build .#nixosConfigurations.<host> → toplevel
          mkImage: mksquashfs root → veritysetup format → root hash R
2 SIGN    ukify build --cmdline "init=… copytoram roothash=R …" → uki.efi
          sbsign --key db.key --cert db.crt uki.efi   (db.key sops-decrypted, shred after)
3 SEAL    predict PCRs for the new UKI (PCR 7 + signed PCR 11);
          systemd-measure sign → policy shipped with the slot
4 ESCROW  ensure recovery keyslot exists; idempotent upsert to <vaultwarden-url> (token from sops)
5 STAGE   assemble inactive-slot bundle {signed uki.efi, verity hash img, policy}
└──────────────┬──────────────────────────────────────┘
               │  deliver: ssh/scp over Tailscale, write the INACTIVE slot only
┌──────────────▼──────  NAS NODE (receives only)  ─────┐
6 WRITE   drop signed UKI into ESP  EFI/Linux/nixnas_<slot>+3.efi
7 SWITCH  set systemd-boot default → new slot; reboot
8 ROLLBACK boot-counting decrements tries on each failed boot;
          health gate reached → bootctl good; tries exhausted → auto-fallback to previous slot
└──────────────────────────────────────────────────────┘
```

- The two delivery paths mirror the fleet GUARD model: **in-place (deploy-rs, magic-rollback)** for a small closure delta under the class ceiling, vs the **image/full path** (the A/B UKI swap + automatic rollback) for a disk-layout change or oversized delta. A class-driven GUARD chooses per node: `nix eval --json` (never `--raw`), gate on the `gated` bool first, **fail-CLOSED** (empty policy → route to image), per-node marker so one image-routed host never freezes the fleet. The MC12-LE0 A/B slots *are* the image path for this machine.
- **The node is dumb and replaceable.** Signing keys, the sops master age key, and the Vaultwarden token exist only on the hub; the node receives a signed UKI + verity + policy + a recovery slot it can't read back.
- **Magic-rollback tmpfiles lesson:** any custom rollback/health temp path must be guaranteed by `systemd.tmpfiles`, or a reimage silently breaks rollback.

### Tooling forks to evaluate (see Decisions)
- **`systemd-sysupdate`** is the closest upstream concept for versioned, verity-backed, boot-counted A/B image delivery — it may replace much of the bespoke deliver step.
- **mkosi** builds exactly this class of signed+verity UKI image and integrates with systemd-repart/sysupdate — wrapping it may be far less code than a hand-rolled `mkImage`.
- A/B at UKI granularity on bare metal has **no turnkey NixOS module** today; `boot.uki` + boot-counting + verity exist as pieces but the stitching is custom `lib/` + `modules/boot/` code.

---

## 6. FOSS-clean core vs private overlay

Privacy is a **flake-input boundary**, not a `.gitignore` afterthought — git history is forever, and one accidental `git add -A` burns a serial number into public history permanently. Three concentric tiers, two git boundaries:

| Tier | Content | Repo | Visibility |
|---|---|---|---|
| **Core** | Reusable appliance: boot chain, A/B, crypto, k3s/podman/incus scaffolding, image builder, hub pipeline. 100% parameterised — no literals. | `nixnas` | **Public FOSS** |
| **Overlay** | Host instantiations: which disks (by-id serials), Tailscale node, `<vaultwarden-url>`, hostnames, the actual `nixosConfigurations`. | `nixnas-hosts` | Forever private |
| **Secrets** | sops+age ciphertext: LUKS recovery key, Vaultwarden token, TS auth key, SecureBoot private keys. | `nixnas-hosts/secrets/` | Forever private |

The public repo **never imports** the private one; the private one imports the public core as a flake input. Open-sourcing later is "flip `nixnas` to public" with zero private context ever having touched its history.

- **Secrets** reuse the existing sops+age convention (per-machine age recipients, `.yml`, `sops updatekeys` on recipient change). The NAS self-decrypts at activation by deriving its age key from its **persistent** SSH ed25519 host key (`sops.age.sshKeyPaths`). **Caveat:** the RAM-root regenerates `/etc/ssh/ssh_host_ed25519_key` each boot unless it is pinned to a persisted/encrypted location — flag this in `crypto/recovery-escrow.nix` docs.
- **What never appears in cleartext anywhere:** the boot PIN (lives only in your head + the Vaultwarden recovery slot), SecureBoot private keys (sops-encrypted), Vaultwarden token, TS auth key, k3s token, recovery LUKS key. Real hostnames/IPs/serials/URLs are not cryptographic secrets but ARE private context → only in `nixnas-hosts`, never in `nixnas` even encrypted.
- **initrd unlock is NOT sops-nix.** sops-nix decrypts at *activation*; LUKS unlock happens earlier, in initrd, handled by `systemd-cryptenroll` (TPM2+PIN) + the escrowed keyslot. The TPM is the initrd secret store.
- **Demoable standalone:** a fake `hosts/demo` host with RFC-5737/RFC-2606 placeholders (`203.0.113.x`, `demo.invalid`, `by-id/DEMO-*`) lets CI build the toplevel and the image with zero secrets. CI can't test real TPM/SecureBoot in GH runners — cover with a documented manual hub-side checklist + an optional swtpm VM check.

---

## 7. GitOps lane (avoid the inherited split-brain)

The current fleet has both Argo CD App-of-Apps *and* `services.k3s.manifests` reconciling — a split-brain to avoid inheriting. nixnas picks one lane: **Argo CD App-of-Apps for application workloads; `services.k3s.manifests` only for cluster-bootstrap addons** (CNI/LB/operators that must exist before Argo can reconcile). System config is deploy-rs/image from the hub; **never `nixos-rebuild` on the node.**

Exposure follows the three-door model: PUBLIC via the in-cluster tunnel (proxied), PRIVATE-web via one reverse-proxy pod on a tailnet LB pinned to a `.<octet>` matching its tailnet octet (grey/unproxied), PRIVATE-data via per-engine octet-pinned tailnet LBs. **Storage/SMB/ZFS-management surfaces stay tailnet/LAN-only, never public.** Service IPs honor the LAN-octet == tailnet-octet convention; nixnas's own management IPs slot into the on-host node range and don't collide.

---

## 8. Unraid-function → nixnas-replacement table

| Unraid function (today) | nixnas replacement | Status |
|---|---|---|
| Boot OS off USB (Ventoy 3-partition) | Signed UKI per A/B slot, copytoram verity squashfs, stick written only on update | replaced (LOCKED) |
| License / flash-GUID registration | none — NixOS is free; entire licensing failure class gone | retired |
| `md` parity array (SMR) | retiring; 5 SMR = standalone whole-disk-LUKS + xfs/btrfs, write-once, no parity | retired/host-bound |
| Two ZFS pools, LUKS-under-ZFS | native ZFS, LUKS-under-ZFS, non-fatal import; **both pools recreated fresh** via disko, data re-laid (not in-place) | rebuilt |
| LUKS unlock at array start (webUI passphrase) | single passphrase = TPM2 PIN, all devices; recovery escrow | replaced |
| Remote unlock (none today) | stage-2 Tailscale SSH (primary) / initrd-SSH-over-Tailscale (fallback) | new |
| SMB shares (`.cfg`, delete=destroy hazard) | `services.samba` `settings` — decoupled from dataset lifecycle | replaced |
| NFS (restricted) | `services.nfs.server.exports`, same posture | kept (scoped) |
| shfs union `/mnt/user/…` | **REMOVED** — no FUSE union; data already on explicit single-pool datasets, apps point at the dataset mountpoint | replaced |
| HOT⇄COLD mover-tiering | **explicit per-dataset placement** (HOT=SSD `hot`, COLD=HDD `cold`), operator-set; optional ZFS `special` vdev for speed-without-motion | replaced |
| VMs (libvirt) | `virtualisation.libvirtd` + NixVirt, scoped to Windows | kept (minimal) |
| LXC desktops (Unraid plugin) | Incus Arch container; no-systemd mount-race guard evaporates | replaced |
| k3s control-plane (in LXC) | native `services.k3s` on metal | lifted onto metal |
| GPU passthrough + shared-GPU platform | `hardware.amdgpu` + ROCm, render-GID pinned, hostPath into pods + Incus gpu device | host-bound |
| Docker (15 bridges, cloudflared) | Podman/Quadlets + k3s; Docker retired | retired |
| Backup receiver + User Scripts | ZFS auto-import + `systemd.services`/`.timers`; sources still push | replaced |
| Unraid kernel-module stripping/kmod-sync | `boot.kernelPatches`/`extraModulePackages` in the closure — whole dance gone | retired |
| Cloudflare Tunnel (host + cluster) | in-cluster cloudflared on k3s; host-tier → `services.cloudflared` or fold into k3s | kept |
| Array auto-start = NO (at-rest encryption) | OS-from-RAM always; data pools wait for the single PIN, now TPM2-gated + remotely unlockable | kept, better |

---

## 9. Cross-cutting doctrine nixnas must honor

- **No quotas / ARC is reclaimable** — never cap RAM away from ZFS ARC or set refquota to fence churn; contain runaway use at the workload boundary (pod limits, Nix `max-jobs`/`cores`), never the host/storage boundary.
- **No data footguns** — `zfs destroy`/`rm`/`wipe` are human-gated, verify-and-REPORT; never batch unapproved/protected paths into an `rm` loop. The protected-zvol KEEP list carries over.
- **ZFS dataset checklist** — honor the four creation-immutable axes (casesensitivity/normalization/utf8only/encryption) and the content-vs-byte-exact encoding classes on any new dataset.
- **SMR caution** applies to the SMR archive disks ONLY (not the CMR HDD pool); thermal pacing pauses transfers, never power-cycles.
- **Local-first storage** — native ZFS/hostPath/bind; decouple to S3 only on explicit signal. nixnas is THE anchor: storage stays put, compute floats.

---

## 10. Bench-verification checklist (flagged unknowns)

1. Exact `boot.loader.systemd-boot.bootCounting` option name in the pinned nixpkgs (renamed several times).
2. This board's AMI firmware actually supports enrolling custom PK/KEK/db **and** removing Microsoft keys, plus admin-password persistence.
3. fTPM vs discrete TPM active; SHA-256 PCR bank present (`tpm2_pcrread`); PCR 7 stability across a real A/B UKI swap.
4. systemd keyring PIN-reuse unlocks all devices from one entry in the exact build.
5. The ZFS `zfs-import-*` / `local-fs.target` unit graph stays non-blocking under a pulled-disk test.
6. f2fs + dm-verity + loop modules present and ordered in the trimmed systemd initrd.
7. 8 GB USB budget under the real OS-store size — measure `squashfsStore` output early.
8. AMD ROCm k8s GPU passthrough against k3s's bundled containerd on the chosen kernel (the historically-broken path, reported fixed ~2025).
9. quadlet-nix camelCase for device/group passthrough (fall back to `rawConfig`).
10. signed PCR 11 automation has no turnkey path; budget custom hub tooling and watch sharp systemd edge cases.
11. swtpm-in-CI is only an approximation of the real fTPM reseal correctness.

