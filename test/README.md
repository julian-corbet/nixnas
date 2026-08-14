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
(boot-counting × lanzaboote). A VM lets us force boot failures, inspect the firmware's
`LoaderBootCountPath`, and require the post-bless verifier to pass safely and repeatably. It needs
almost no resources: the appliance must run on small boxes anyway.

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
reboot. The TPM-sealed initrd-SSH host key does, and Secure Boot enrollment changes PCR 7 once.
`seal-3boot-test.sh` gives it a *persistent* disk copy, Secure-Boot-capable OVMF variables, and a
per-boot swtpm against one persistent TPM state dir. It drives the genuine three-boot lifecycle:

```sh
test/seal-3boot-test.sh nixnas.raw            # boot#1 enrolls → boot#2 seals under enforcement
                                              #   → boot#3 initrd unseals → network unlock (PASS)
test/seal-3boot-test.sh nixnas.raw --tamper   # boot#3 on a FRESH/wrong TPM: unseal MUST fail,
                                              #   sshd MUST NOT come up — fail-closed (PASS)
```

The positive run proves the box unlocks headlessly with a host key that was never plaintext on the
ESP; `--tamper` proves the key is genuinely bound to *this* box's TPM (a different SRK cannot unseal
it). Both are deterministic. swtpm PCRs still differ in implementation from real hardware, but
the test now proves the actual enrollment/enforcement transition and the declared PCR 7 policy.

## Known limits / next steps

- TPM2 is the swtpm emulator; PCR values differ from real hardware, so TPM2-sealing tests here
  prove the declared PCR policy and lifecycle against the emulator, not a particular physical
  board's measurements.
- OVMF proves owner-key Secure Boot plus the successful boot-count publication and blessing path.
  Exhausting a deliberately failed generation's tries and observing automatic previous-generation
  selection is not yet automated. A physical board can also have firmware-specific variable-storage
  or setup-password behaviour and needs its supervised acceptance boot.
