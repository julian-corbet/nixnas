# nixnas

A fully declarative, RAM-resident NixOS appliance that brings the Unraid operating
model to NixOS.

- **Boots from a USB stick** and copies itself entirely into RAM (`copytoram`) — the
  stick is spared and only touched on updates.
- **A/B updates**: a new signed system image is written to the inactive slot and
  atomically switched, with automatic rollback if it fails to boot.
- **Survives storage trouble**: the OS lives in RAM, fully independent of the data
  pools — the box boots even if a pool is degraded or missing.
- **Encrypted at rest**: every data disk is LUKS, with the filesystem directly on the
  decrypted mapper; a single passphrase unlocks everything at boot.
- **Evil-Maid hardened**: UEFI Secure Boot with *your own* keys, signed Unified Kernel
  Images, a dm-verity-protected root, a firmware setup password, and LUKS bound to
  TPM2 + PIN — a tampered boot chain can neither boot nor surrender the disk key.
- **Hands-off**: everything except the one boot passphrase is automated — build, sign,
  seal, roll out, recovery-key escrow, rollback. *If you have to think about it,
  something has gone wrong.*

## What runs on it

- **k3s**, declaratively, as the workload orchestrator.
- **Podman + Quadlets** for host-level system containers.
- An **Arch Linux system container** for interactive/desktop workloads.

## Design

The architecture is built on a strict split: a **generic, reusable core** (the
`nixnas` module + image builder + the build-sign-seal-deliver pipeline) and a
**private overlay** (host config + secrets) that never enters this repo's public
history. All heavy work (build, sign, verity, TPM-reseal, escrow, image bake) runs on
a separate **build hub** — the appliance node only *receives* finished, signed
artifacts.

See [`docs/DESIGN.md`](docs/DESIGN.md).

## Status

Early design.

## License

To be released as FOSS. License not yet chosen.
