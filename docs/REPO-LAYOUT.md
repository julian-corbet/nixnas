## Two-repo boundary (privacy = flake-input boundary, not .gitignore)

```
# ── PUBLIC: github.com/<you>/nixnas ─────────────────────────────────
nixnas/
├── flake.nix                 # inputs: nixpkgs, disko, sops-nix, flake-parts,
│                             #   (systemd-stub/ukify via nixpkgs) — NO private input
├── flake.lock
├── LICENSE                   # MIT | Apache-2.0 | AGPL-3.0  ← user's pick
├── README.md  CONTRIBUTING.md
├── docs/{architecture,porting,threat-model,boot-chain,crypto}.md
├── .github/workflows/ci.yml  # nix flake check + build demo toplevel + build image + swtpm smoke
│
├── modules/                  # → nixosModules.nixnas (imports all below)
│   ├── default.nix
│   ├── options.nix           # the WHOLE public API surface (typed knobs, no literals)
│   ├── boot/
│   │   ├── ram-root.nix       # copytoram + verity squashfs overlay (custom initrd service)
│   │   ├── uki.nix            # boot.uki / ukify, one self-contained signed UKI per slot
│   │   ├── secureboot.nix     # own PK/KEK/db, MS keys NOT enrolled (sbctl/sbsign) — no lanzaboote
│   │   ├── ab-slots.nix       # A/B layout + systemd-boot boot-counting + health-gate "good"
│   │   └── remote-unlock.nix  # stage-2 Tailscale-SSH unlock (primary) + initrd-SSH fallback
│   ├── crypto/
│   │   ├── luks.nix           # LUKS-direct-on-mapper, single-secret keyring fan-out
│   │   ├── tpm2.nix           # systemd-cryptenroll TPM2+PIN, PCR7 baseline / signed-PCR11 phase2
│   │   └── recovery-escrow.nix# recovery keyslot → Vaultwarden API (URL is an OPTION)
│   ├── storage/
│   │   ├── zfs-pools.nix      # LUKS-under-ZFS, non-fatal Wants-only import, by-id devNodes
│   │   ├── smr-disks.nix      # LUKS-under-xfs/btrfs, whole-disk, serial-keyed (param map)
│   │   ├── disko-profiles.nix # reusable disko layout FUNCTIONS (no serials)
│   │   ├── shares.nix         # services.samba (settings schema) + samba-wsdd + nfs.server
│   │   └── tiering.nix        # mergerfs union + custom systemd-timer mover (age + pinned-exclude)
│   ├── compute/
│   │   ├── k3s.nix            # native services.k3s (+ bootstrap manifests only)
│   │   ├── podman.nix         # virtualisation.quadlet tier-0 host glue (Docker retired)
│   │   ├── arch-container.nix # virtualisation.incus + preseed (Arch pet, GPU device)
│   │   ├── libvirt.nix        # virtualisation.libvirtd + NixVirt (Windows/keep VMs)
│   │   └── gpu.nix            # amdgpu + ROCm, render-GID pinning, hostPath/device split
│   ├── observability/
│   │   └── monitoring.nix     # smartd + node-exporter + smartctl-exporter (+ cockpit/netdata opt)
│   ├── network/
│   │   └── nftables.nix       # single nft backend, per-bridge subnets, ip_forward, trusted ifaces
│   └── appliance/
│       ├── tailscale.nix      # tailscaled, auth-key from sops (option path)
│       └── hardening.nix      # firmware-password expectation, read-only-root posture
│
├── lib/                       # → lib.* (the HUB pipeline, pure; never runs on node)
│   ├── default.nix
│   ├── mkImage.nix            # build one A/B slot: squashfs + verity + roothash  (eval mkosi fork)
│   ├── signUki.nix            # ukify + sbsign/sbctl wrapper
│   ├── verity.nix             # veritysetup format → roothash → embed in signed cmdline
│   ├── sealTpm.nix            # systemd-measure sign → PCR policy for cryptenroll
│   ├── escrow.nix             # idempotent recovery-key upsert to Vaultwarden (bw CLI)
│   └── deliver.nix            # write INACTIVE slot over Tailscale + arm switch (eval sysupdate)
│
├── packages/
│   ├── image.nix             # packages.<sys>.image : function over a nixosConfiguration
│   └── hub-cli.nix           # `nixnas-hub build|sign|seal|escrow|deliver|switch`
│
├── hosts/demo/               # FAKE host so the public repo builds standalone
│   ├── default.nix           #   RFC-5737/2606 placeholders (203.0.113.x, demo.invalid)
│   └── disko-demo.nix        #   /dev/disk/by-id/DEMO-* placeholders
│
├── templates/host/{flake,host}.nix   # scaffold a private overlay
└── checks/{build-demo,eval-options}.nix

# flake outputs (public core):
#   nixosModules.nixnas / .default
#   lib                          (mkImage/signUki/verity/sealTpm/escrow/deliver)
#   packages.<sys>.{image, hub-cli, default=hub-cli}
#   nixosConfigurations.demo     (proves the core stands alone)
#   checks.<sys>.{build-demo, eval-options}
#   devShells.<sys>.default      (sbsigntools, tpm2-tools, ukify, sops, age, jq, bw)
#   templates.host

# ── PRIVATE: github.com/<you>/nixnas-hosts (never open-sourced) ──────
nixnas-hosts/
├── flake.nix                 # inputs.nixnas.url = "github:<you>/nixnas";
├── flake.lock
├── .sops.yaml                # SAME per-machine-age-recipient format as the fleet's existing setup
├── hosts/nas/
│   ├── default.nix           # imports nixnas.nixosModules.nixnas; sets EVERY option literal here
│   ├── disko.nix             # real /dev/disk/by-id/ata-… serials live ONLY here
│   └── hardware.nix          # nixos-generate-config output for the real board
├── secrets/
│   ├── nas.yml               # sops+age: luks recovery key, vaultwarden token, TS authkey, k3s token
│   └── secureboot/{pk,kek,db}.yml   # SecureBoot PRIVATE keys, sops-encrypted (public certs may be plain)
└── modules/                  # rare host-private glue
```

### The only file pairing generic module with private literals
`nixnas-hosts/hosts/nas/default.nix`:
```nix
{ nixnas, config, ... }: {
  imports = [ nixnas.nixosModules.nixnas ./disko.nix ./hardware.nix ];
  nixnas = {
    hostName                   = "…";                       # private literal
    tailscale.tags             = [ "tag:nas" ];
    crypto.vaultwardenUrl      = "https://…";               # private literal
    storage.zfs.ssdPool.disks  = [ "/dev/disk/by-id/…" ];   # serials, private
    storage.smr.disks          = { "<label>" = "/dev/disk/by-id/…"; };
    boot.secureboot.keysSops   = config.sops.secrets."secureboot/db".path;
    # all BEHAVIOUR comes from the public module; only DATA lives here.
  };
}
```

### Public/private delineation rule
- **Public core holds:** every mechanism, every typed option, the hub pipeline, the demo host with fake values. No hostname, IP, serial, URL, or fleet-topology fact — not even in comments or git history.
- **Private overlay holds:** all literals (serials/IPs/hostnames/URLs), all sops ciphertext, the real `nixosConfigurations`. It *imports* the public core; the public core never references it.

