# Demo host — proves the public nixnas core evaluates standalone, with ZERO secrets.
#
# Every value is an RFC-5737 (203.0.113.0/24) / RFC-2606 (.invalid) / DEMO-*
# placeholder. This host ships in the PUBLIC repo; the real machine lives in a
# separate, private overlay (see ../../templates/host).
{ lib, pkgs, ... }:
{
  # The memory subsystem is nixram's (composed into nixosModules.nixnas). nixnas
  # sets enable + mode = "zram"; `level` is the one value nix evaluation cannot
  # derive, because it cannot read the target machine's /proc/meminfo -- so every
  # host declares it once, from `nix run <nixram>#detect-level`, and nixram
  # asserts rather than guessing. 8G is the demo box's placeholder.
  nixram.level = "8G";

  nixnas = {
    enable = true;
    hostName = "demo";

    # DEMO ONLY — an explicit, visible opt-in to the PUBLIC demo passphrase
    # ("nixnas-demo"), so the sandbox image build works with zero secrets. A real
    # host leaves this at null: the TUI then injects the operator's passphrase into
    # the builder VM and a build without it fails (fail-closed).
    boot.usb.luksPassphraseFile = toString (pkgs.writeText "nixnas-demo-luks" "nixnas-demo");

    # Throwaway DEMO key (test/ssh/demo_key) — for the test VM only. A real host lists the
    # operator's own keys here; they authorise BOTH the initrd remote-unlock and admin sshd.
    admin.authorizedKeys = [ (lib.fileContents ../../test/ssh/demo_key.pub) ];
    # The initrd-SSH host key is generated and TPM2-sealed after the first successful local
    # boot; no plaintext key or TPM-backed disk key exists. The first unlock therefore happens
    # at the machine (monitor by default, serial/IPMI-SOL in CI).

    # Reference-box kernel tuning (a generic adopter would leave march at the x86_64-v1
    # default; we build for a known x86-64-v3 CPU). variant=latest, lto=thin, eevdf are defaults.
    kernel.march = "x86_64-v3";

    boot.secureBoot.enable = true;
    # QEMU's virtual boot chain advertises an OptionROM in the TPM event log. The demo test
    # enrolls that exact measured image rather than Microsoft vendor certificates; production
    # hosts keep the strict "none" default unless the operator makes this same explicit choice.
    boot.secureBoot.opromPolicy = "tpm-eventlog";

    # CI/QEMU: the test suites observe (and drive) the VM ONLY through the serial
    # port, so ttyS0 must stay /dev/console here — systemd status lines, the
    # verify-* marker blocks, and the emergency shell must land in the captured
    # serial log. Every test nixosConfiguration (demo-hot, demo-hot-zfs,
    # demo-upgrade-soak, matrix-*) layers on top of this host, so this single pin
    # covers the whole CI board. A REAL host keeps the "video" default: first boot
    # asks for the store passphrase on the attached monitor.
    boot.consolePrimary = "serial";

    # The 8 GiB-stick guard (see modules/store/budget.nix): fail the build if the host
    # closure exceeds this. The demo is a minimal appliance (no k3s/docker); 4 GiB is a
    # generous bound that demonstrates the mechanism. A real host sets its own ceiling —
    # a lean base+k3s+runtime hub targets ~5 GiB (≈2 GiB compressed on the stick and in
    # the preload RAM). `system.build.storeClosureBudget` is wired into checks in flake.nix.
    store.maxClosureBytes = 4 * 1024 * 1024 * 1024;

    # Your LUKS members as name → device; each opens at /dev/mapper/<name> (non-fatal, so
    # these non-existent DEMO devices don't block the test boot). An SMR/XFS archive drive
    # is just another entry — no special handling. You mount the results with native
    # `fileSystems` and persist state with `environment.persistence` (see examples/host.nix).
    storage.unlock = {
      demossd0 = "/dev/disk/by-id/DEMO-ssd-0";
      demohdd0 = "/dev/disk/by-id/DEMO-hdd-0";
      demoarchv = "/dev/disk/by-id/DEMO-smr-0";
    };
    storage.zfsPools = [ "demohot" "democold" ];

    tailscale.enable = true;

    # Tier-1 identity persistence (modules/appliance/identity.nix): the box must rejoin
    # its mesh BEFORE the data pools unlock, so tailscale's /var/lib/tailscale is bound
    # from the encrypted stick, not tmpfs. Demonstrates the generic overlay-client loop
    # with the one overlay client this demo actually runs.
    persist.overlayClients = [ "tailscale" ];

    # Build-time enforcement (modules/appliance/persist-enforce.nix) walks every
    # StateDirectory-bearing systemd service. `linger-users` (nixpkgs'
    # `systemd.services.linger-users`, StateDirectory = "systemd/linger") is a
    # declarative marker: it is fully recreated from `users.users.*.linger` on every
    # boot (nixos/modules/config/users-groups.nix), so losing it is genuinely
    # inconsequential — a deliberate, checked opt-in, not a default.
    persist.explicitlyEphemeral = [ "linger-users" ];

    # DEMO placeholder so the demo exercises the self-update wiring (never pulled here).
    # A real host points this at its own flake; private flakes add pull auth.
    autoUpgrade.flake = "github:DEMO/nas-config#demo";
  };

  # Console login for the test VM, via the product auth model (modules/appliance/auth.nix):
  # root's password is the PUBLIC demo passphrase "nixnas", as a store-path yescrypt hash —
  # the same explicit, visible opt-in as the demo LUKS passphrase above (this overrides the
  # module's mkDefault runtime path). A real host keeps the runtime file instead: the TUI
  # injects the hash of the operator's store passphrase at build time, never the Nix store.
  users.users.root.hashedPasswordFile = toString (
    pkgs.writeText "nixnas-demo-root-hash"
      "$y$j9T$8NCrqqcsinELEJMoMypD/1$6ZP7.dytN5dIPPXqX16PU4DmnhSfodZjJuIdWCgtKl8\n"
  );

  # ZFS (the operator's data pools) requires a stable host id; a real host sets its own.
  networking.hostId = "deadbeef";

  system.stateVersion = "25.05";
}
