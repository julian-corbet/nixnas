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
LUKS/TPM2 unlock → f2fs `/nix` → impermanence — and, above all, the **rollback** behaviour
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

## Known limits / next steps

- **`--secboot` enforces signatures but with the firmware's default key set.** Testing
  lanzaboote with *our own* Secure Boot keys needs those keys enrolled into the UEFI vars
  (PK/KEK/db) first — a follow-up using lanzaboote's key-enrollment path. Until then `--secboot`
  validates that a signed chain boots; own-key evil-maid testing is the next increment.
- TPM2 is the swtpm emulator; PCR values differ from real hardware, so TPM2-sealing tests here
  prove the *mechanism*, not the production PCR policy.
