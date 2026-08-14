# nixnas — test environment

A deliberately **tiny** rig to validate a built nixnas image, without touching real hardware.
The split mirrors the product: **build on the capable machine, boot in a small VM.**

```
   cluster (heavy Nix build)                 this machine (lean QEMU VM)
   ┌────────────────────────┐   .raw    ┌──────────────────────────────┐
   │ nix build .#image      │ ───────▶  │ test/boot-vm.sh image.raw     │
   │  (no-local-compute)    │           │  UEFI + SecureBoot + TPM2     │
   └────────────────────────┘           │  serial console, virtio disk  │
                                         └──────────────────────────────┘
```

## Why a VM at all

We need to exercise the *real* boot chain — UEFI → (Secure Boot) → signed UKI → initrd →
passphrase-only LUKS unlock → f2fs `/nix` → impermanence — and, above all, the **rollback** behaviour
(boot-counting × lanzaboote), which is the load-bearing, still-UNVERIFIED piece
(`docs/ARCHITECTURE.md` §9). A VM lets us force boot failures and watch recovery safely and
repeatably. It needs almost no resources: the appliance must run on small boxes anyway.

## Prerequisites (already present here)

`qemu-system-x86_64`, `swtpm`, and OVMF (`edk2-ovmf`, incl. the `OVMF_CODE.secboot.4m.fd`
variant for Secure Boot). The script finds the firmware automatically.

## 1. Build the image (on the cluster — not here)

The image is heavy to build, so it runs on the build machine (the cluster), never on the
laptop/workstation:

```sh
# on the cluster build pod:
nix build .#image          # -> result/…​.raw   (flake output: packages.<system>.image)
# copy the .raw back to this machine, e.g.:
kubectl cp <pod>:/nixnas/result/nixnas.raw ./nixnas.raw
```

## 2. Boot it here (lean VM)

```sh
test/boot-vm.sh nixnas.raw                 # plain UEFI + TPM2, serial console
test/boot-vm.sh nixnas.raw --secboot       # enforce Secure Boot
test/boot-vm.sh nixnas.raw --ssh 2222      # forward host :2222 -> guest :22 (reach initrd-SSH / sshd)
test/boot-vm.sh nixnas.raw --mem 4096 --smp 4
```

- Disk is attached as **virtio** with `snapshot=on` → the `.raw` is never modified; re-run freely.
- Console is **serial-only** (`-nographic`) — matches the headless appliance (`console=ttyS0`).
  Quit with `Ctrl-a x`; QEMU monitor with `Ctrl-a c`.
- A per-run swtpm + a writable copy of the UEFI vars live in a temp dir, cleaned up on exit.

## 3. The sealed initrd-SSH host key — real power-cycle proof

`boot-vm.sh` uses `snapshot=on` + a fresh swtpm, so it cannot test anything that must survive a
reboot. The TPM-sealed initrd-SSH host key does: it is sealed on boot #1 and must be **unsealed by
the initrd on boot #2**. `seal-2boot-test.sh` gives it a *persistent* disk copy + a per-boot swtpm
against one persistent TPM state dir (so PCR 7 matches across boots), and drives a genuine two-boot
cycle:

```sh
test/seal-2boot-test.sh nixnas.raw            # boot#1 seals → boot#2 initrd unseals → initrd-SSH
                                              #   comes up → store unlocked over SSH → login  (PASS)
test/seal-2boot-test.sh nixnas.raw --tamper   # boot#2 on a FRESH/wrong TPM: unseal MUST fail,
                                              #   sshd MUST NOT come up — fail-closed  (PASS = no unlock)
```

The positive run proves the box unlocks headlessly with a host key that was never plaintext on the
ESP; `--tamper` proves the key is genuinely bound to *this* box's TPM (a different SRK cannot unseal
it). Both are deterministic. (swtpm PCRs still differ from real hardware — these prove the
*mechanism*; the production PCR policy is a hardware spike, `docs/ARCHITECTURE.md` §9.)

## Known limits / next steps

- **`--secboot` enforces signatures but with the firmware's default key set.** Testing
  lanzaboote with *our own* Secure Boot keys needs those keys enrolled into the UEFI vars
  (PK/KEK/db) first — a follow-up using lanzaboote's key-enrollment path. Until then `--secboot`
  validates that a signed chain boots; own-key evil-maid testing is the next increment.
- TPM2 is the swtpm emulator; PCR values differ from real hardware, so TPM2-sealing tests here
  prove the *mechanism*, not the production PCR policy.
