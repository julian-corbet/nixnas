## Two-repo boundary (privacy = flake-input boundary, not .gitignore)

The PUBLIC repo is the generic, thin appliance core. Your machine's real disks, keys,
and secrets live in a SEPARATE PRIVATE repo that imports nixnas as a flake input
(`templates/host/` scaffolds one). The public core never references the private overlay.

```
# ── PUBLIC: github.com/<you>/nixnas ─────────────────────────────────
nixnas/
├── flake.nix                 # inputs: nixpkgs (unstable) + nixpkgs-stable (image-builder VM),
│                             #   disko, lanzaboote, nix-cachyos-kernel — NO private input
├── flake.lock
├── LICENSE                   # Apache-2.0
├── README.md
├── docs/                     # ARCHITECTURE, SCOPE, STORAGE, KERNEL, OPTIMIZATIONS, REPO-LAYOUT
│
├── modules/                  # → nixosModules.nixnas (default.nix imports all below)
│   ├── default.nix
│   ├── options.nix           # the WHOLE public API surface (typed `nixnas.*`, no literals)
│   ├── boot/
│   │   ├── disk.nix           # disko GPT on the stick: ESP + LUKS2 f2fs-zstd:22 store; tmpfs root
│   │   ├── image.nix          # UEFI + systemd-initrd glue, serial console, initrd modules
│   │   ├── impermanence.nix   # tmpfs root — only /nix + the ESP persist (RAM-resident, not copytoram)
│   │   ├── kernel.nix         # the CachyOS kernel (pkgs.cachyosKernels) + zfs_cachyos + lantian cache
│   │   ├── secureboot.nix     # lanzaboote Secure Boot: operator-owned PK/KEK/db, signed UKIs
│   │   ├── remote-unlock.nix  # headless store unlock — initrd-SSH; host key TPM-sealed by default
│   │   └── rollback.nix       # kept generations (configurationLimit) + lanzaboote boot-counting
│   ├── crypto/
│   │   ├── tpm2.nix           # TPM2+PIN store unlock (crypttab) + first-boot `nixnas-enroll-tpm2`
│   │   └── recovery-escrow.nix # break-glass recovery keyslot → Vaultwarden (hub tool + box status)
│   ├── storage/
│   │   └── connect.nix       # stage-2 LUKS unlock + optional ZFS import (thin; mounting is native)
│   └── appliance/
│       ├── base.nix           # stable hostName + Tailscale
│       ├── ssh.nix            # headless admin sshd (key-only root)
│       ├── auto-upgrade.nix   # self-update: stage-only, never self-reboot
│       └── optimizations.nix  # appliance defaults: zram, journald→RAM, no swap, store.preload
│
├── lib/default.nix           # mkImage — the TUI's build entry (host → diskoImages); pure, hub-side
│
├── hosts/demo/default.nix    # FAKE zero-secrets host so the public repo builds standalone
│                             #   (DEMO-* / RFC-5737 / .invalid placeholders; demo LUKS pass `nixnas-demo`)
│
├── templates/host/{flake,host}.nix   # scaffold a private overlay (the operator copies + fills in)
│
├── test/                     # boot-vm.sh (QEMU+OVMF+swtpm); seal-2boot-test.sh (power-cycle:
│   │                         #   seal→unseal→initrd-SSH→unlock, + --tamper wrong-TPM fail-closed);
│   │                         #   DEV self-checks baked into the demo: verify-image / verify-tpm2 /
│   │                         #   verify-sealed-hostkey / verify-recovery / verify-writes; ssh/ (demo keys)
│   └── …
└── tui/                      # the Rust TUI: build the image locally + flash (caligula)

# flake outputs (public core):
#   nixosModules.nixnas
#   lib.mkImage
#   packages.x86_64-linux.{image, imageScript}   (the TUI builds `.#image`)
#   nixosConfigurations.demo                      (proves the core stands alone)
#   checks.<sys>.demo-toplevel

# ── PRIVATE: github.com/<you>/nixnas-config (never open-sourced) ─────
nixnas-config/
├── flake.nix                 # inputs.nixnas.url = "github:<you>/nixnas"; mirrors the demo's
│                             #   image machinery (disko + lanzaboote + cachyos overlay + stable builder)
├── host.nix                  # imports nixnas.nixosModules.nixnas; sets EVERY option literal here
├── initrd_host_ed25519_key   # the box's initrd-SSH host key (git-tracked; flakes only see tracked files)
└── secrets/                  # sops+age: Tailscale authkey, Vaultwarden escrow creds, etc.
                              # (the LUKS passphrase is NOT stored — the TUI prompts + shreds it)
```

### The only file pairing the generic module with private literals
`nixnas-config/host.nix` (see `templates/host/host.nix`):
```nix
{ lib, ... }: {
  nixnas = {
    enable   = true;
    hostName = "nas";                                    # private literal
    admin.authorizedKeys = [ "ssh-ed25519 …" ];          # your keys
    boot.remoteUnlock.hostKeyPath = ./initrd_host_ed25519_key;
    boot.usb.device = "/dev/disk/by-id/usb-…";           # the ONLY device nixnas partitions
    storage.unlock.hot0           = "/dev/disk/by-id/ata-…";      # serials, private
    boot.secureBoot.enable = true;
    crypto.tpm2.enable     = true;
    autoUpgrade.flake      = "github:you/nas-config#nas";
    # all BEHAVIOUR comes from the public module; only DATA lives here.
    # k3s / GPU / Samba / VMs are plain NixOS you add ALONGSIDE — NOT nixnas.* (see SCOPE.md).
  };
  system.stateVersion = "25.05";
}
```

### Public/private delineation rule
- **Public core holds:** every mechanism, every typed option, the build library, the demo
  host with fake values. No hostname, IP, serial, URL, or fleet-topology fact — not even in
  comments or git history.
- **Private overlay holds:** all literals (serials/IPs/hostnames/URLs), all sops ciphertext,
  the initrd host key, the real `nixosConfigurations`. It *imports* the public core; the
  public core never references it.
