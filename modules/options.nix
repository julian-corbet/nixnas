# nixnas — the public option surface.
#
# Every site-specific value a host provides lives under `nixnas.*`. This file
# DECLARES the API; the implementation modules (boot/crypto/storage/…) READ it.
# It is FOSS-clean: no literals, only typed options with descriptions.
#
# SCOPE: nixnas owns boot / crypto / the USB store / kernel-packaging only.
# k3s, GPU, Samba/NFS, the Arch LXC, the Office VM, the apps are NOT nixnas —
# they are plain NixOS the operator declares in their own repo. See docs/SCOPE.md.
{ config, lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types literalExpression;

  diskById = types.strMatching "/dev/disk/by-id/.+";
in
{
  options.nixnas = {
    enable = mkEnableOption "the nixnas appliance (USB-boot, impermanence, generations + rollback, encrypted data pools)";

    hostName = mkOption {
      type = types.str;
      example = "nas";
      description = ''
        Machine hostname. Keep it stable across re-images: node identity and
        host-pinned workloads key off it.
      '';
    };

    ## ── Boot: rollback, Secure Boot, USB layout ───────────────────────────
    boot = {
      tries = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          Boot-counting attempts a new generation gets before it is judged bad and the
          bootloader falls back to the previous one. Each boot decrements the counter;
          reaching `boot-complete.target` clears it (the generation is blessed). This is the
          AUTOMATIC failsafe layer — the manual generation menu is the guaranteed fallback.
        '';
      };
      keepGenerations = mkOption {
        type = types.ints.positive;
        default = 4;
        description = ''
          Number of normal boot entries to retain. On a Secure-Boot Lanzaboote host,
          NixBoot keeps the booted generation plus the newest alternatives within this
          count, collects unreferenced boot artifacts before installation, and reserves
          write space. The default is sized for a 512 MiB ESP alongside three protected
          rescue UKIs; increase it only with a matching ESP budget.
        '';
      };
      lanzabootePackage = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = ''
          Exact upstream `lzbt` package from the Lanzaboote flake composed by
          this host. Required when Secure Boot is enabled: NixBoot's
          capacity-aware installer wraps this package so the installer, signing
          stub, and Lanzaboote module always come from one pinned release.
        '';
      };
      consolePrimary = mkOption {
        type = types.enum [ "video" "serial" ];
        default = "video";
        description = ''
          Which console becomes `/dev/console` — i.e. which one is the LAST `console=`
          kernel parameter:

            "video" (default): tty0 last → the attached DISPLAY is `/dev/console`.
              The first-boot LUKS passphrase prompt, systemd's boot status messages,
              and the emergency shell all appear on the monitor — the right default
              for a human standing at the machine with a monitor + keyboard and no
              IPMI. (First boot cannot use initrd-SSH: the TPM-sealed host key does
              not exist yet, so the very first unlock happens at the machine.)

            "serial": ttyS0 last → the SERIAL port is `/dev/console`. For genuinely
              headless boxes administered over IPMI-SOL/BMC serial — and for the
              QEMU CI suite, which observes the VM only through the serial port.

          BOTH consoles always stay on the kernel command line
          (`console=ttyS0,115200` + `console=tty0`) regardless of this setting, so
          kernel logs reach both, a getty runs on both, and systemd's password agent
          prompts for (and accepts) the passphrase on BOTH. This option only decides
          which one is `/dev/console`: where systemd's boot status stream and the
          emergency shell land.
        '';
      };
      secureBoot = {
        enable = mkEnableOption "UEFI Secure Boot with the operator's OWN keys via lanzaboote (Microsoft keys not enrolled)";
        keysSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path (provided by sops, build-machine only) to the Secure Boot `db` signing key. Never on the node.";
        };
        opromPolicy = mkOption {
          type = types.enum [ "tpm-eventlog" "microsoft" "none" ];
          default = "none";
          description = ''
            How `nixnas-enroll-sb` (the operator-run firmware key enrollment, see
            modules/boot/secureboot.nix) treats Option ROMs.

            OpROMs are firmware blobs that PCI(e) peripherals carry on board — GPU
            VBIOS/GOP drivers, NIC PXE ROMs, storage-HBA ROMs — and that the UEFI
            firmware EXECUTES during POST. Once Secure Boot enforces, the firmware
            verifies OpROM signatures against the enrolled `db`. Vendors sign them
            (if at all) with Microsoft's 3rd-party UEFI CA — never with YOUR keys —
            so enrolling ONLY operator keys on a board with signed OpROMs can brick
            the boot chain: the firmware refuses its own peripherals' ROMs at POST
            (dead GPU output at best, no POST at worst).

              "tpm-eventlog": operator keys AND the CHECKSUMS of the
                OpROMs the firmware actually loaded this boot, as recorded in the
                TPM event log (`sbctl enroll-keys --tpm-eventlog`). This is the
                no-Microsoft mandate without bricking the boot chain: no vendor CA
                enters `db`, but exactly the observed OpROM images stay bootable.
                Caveat: a peripheral firmware update changes the checksum — re-run
                `nixnas-enroll-sb` (in firmware Setup Mode) after such updates.

              "microsoft": also enroll Microsoft's vendor certificates
                (`sbctl enroll-keys --microsoft`) — the pragmatic fallback for
                boards whose OpROMs demand the Microsoft 3rd-party CA. WEAKENS the
                evil-maid story: anything Microsoft ever signed (shims, older
                Windows boot managers) boots on this box again.

              "none" (default): operator keys ONLY, strictest posture. `nixnas-enroll-sb`
                runs a plain `sbctl enroll-keys`, which itself REFUSES when it
                detects OpROMs in the TPM event log. On such a board the operator
                must consciously bypass it by hand (`sbctl enroll-keys
                --yes-this-might-brick-my-machine`) — nixnas never wraps the brick
                flag. Safe on OpROM-free boards (typical headless/VM boxes).
          '';
        };
      };
      remoteUnlock = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            TPM-gated initrd SSH for a headless passphrase unlock. The NIC comes up in the
            initrd; you `ssh root@<box>` with a key from `admin.authorizedKeys` and hand the
            disk passphrase to the password agent. The SSH host identity is a per-device
            encrypted systemd credential sealed to TPM PCR 7. It is created only after a
            successful local/IPMI boot and never has an ephemeral or plaintext fallback.

            A machine without a usable TPM must set this false and unlock through its local
            console or IPMI serial channel. TPM is never used for a LUKS keyslot.
          '';
        };
      };
      # GEOMETRY of nixnas's own stick only — device path, sizes, ESP size, the
      # passphrase-file handoff. The MECHANISM of booting from removable media (the
      # kernel modules that let the initrd find a USB-attached device at all) moved to
      # `nixboot.media.usb.enable` (composed in ./boot/image.nix) — a number belongs
      # here because no other host could reuse it verbatim; a mechanism does not.
      usb = {
        device = mkOption {
          type = types.str;
          default = "/dev/vda";
          example = "/dev/disk/by-id/usb-…";
          description = ''
            The target USB device. The default `/dev/vda` is what the disko image
            builder sees inside its build VM; the TUI overrides it with the real
            stick path when flashing a physical device. This is the ONLY device
            nixnas ever partitions.
          '';
        };
        imageSizeGiB = mkOption {
          type = types.ints.positive;
          default = 8;
          description = "Total image/stick size in GiB. The ESP takes `espSizeMiB`; the f2fs store takes the rest. Overridden byte-precisely by `imageSize` when that is set.";
        };
        imageSize = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "8053063680";
          description = ''
            BYTE-PRECISE total image size, overriding the whole-GiB `imageSizeGiB` when set. A raw
            byte count (or any qemu-img size string) handed to disko's `disk.main.imageSize`, so the
            `.raw` is EXACTLY this many bytes and its f2fs `100%` store fills to the last usable
            sector. The TUI's "Build & flash a stick" path sets this to the target stick's exact
            `blockdev --getsize64`, so the image fits the device to the byte (no whole-GiB stranding,
            no grow-to-fill needed). Null (the default) = size from `imageSizeGiB`.
          '';
        };
        espSizeMiB = mkOption {
          type = types.ints.positive;
          default = 1024;
          description = "FAT ESP size: capacity-accounted Lanzaboote normal generations, protected rescue UKIs, a write reserve and fixed loader metadata.";
        };
        # NOTE: there is deliberately NO first-boot grow option. Growing a flashed image to
        # fill a bigger stick is a FLASH-TIME job (the TUI's "workbench grow": partition extend
        # + `cryptsetup open` + offline `resize.f2fs` + close, with the operator's passphrase) —
        # done where the operator sits, with logs and retries. A first-boot self-modification
        # was shipped once and REMOVED: `resize.f2fs` cannot resize a mounted filesystem (it
        # hangs unkillably and wedges /nix), and first boot on a slow stick / headless box is
        # the worst possible place to discover any of that.
        luksPassphraseFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path INSIDE the image-builder VM of the file holding the store's LUKS
            passphrase, used ONCE to `luksFormat` the store at image-build time. It remains
            the mandatory boot keyslot; no TPM disk token is enrolled. Null (the default)
            means the conventional path
            `/tmp/nixnas-luks.key`, which the TUI injects into the builder VM with
            `imageScript --pre-format-files` — the passphrase never touches the Nix store,
            and a build WITHOUT the injected file FAILS (fail-closed: no silent fallback).
            The public demo host instead points this at a store-path file holding the
            published demo passphrase `nixnas-demo` — an explicit, visible opt-in.
          '';
        };
      };
    };

    ## ── Kernel: the CachyOS kernel, tuned (see docs/KERNEL.md) ─────────────
    kernel = {
      variant = mkOption {
        type = types.enum [ "latest" "lts" "server" "hardened" ];
        default = "latest";
        description = "CachyOS kernel line from the xddxdd/nix-cachyos-kernel flake.";
      };
      march = mkOption {
        type = types.enum [ "x86_64-v1" "x86_64-v2" "x86_64-v3" "x86_64-v4" "zen4" "znver3" "native" ];
        default = "x86_64-v1";
        description = ''
          Microarchitecture build target. Default `x86_64-v1` boots anywhere (the safe
          general-distro default). For a known CPU pick the highest **cache-available** level so
          the box pulls a pre-built kernel instead of recompiling: the lantian cache carries
          `x86_64-v3/-v4` and `zen4` (`x86_64-v2` variants are flagged "no binary cache"
          upstream). A Zen 3 CPU (Ryzen 5000) is `x86_64-v3`; Zen 4 is `zen4`. `znver3`/`native`
          are NOT pre-built — selecting them forces a from-source kernel build on the box
          (avoid; kernel.nix errors early if the combo is absent from the pinned set).
        '';
      };
      lto = mkOption {
        type = types.enum [ "none" "thin" "full" ];
        default = "thin";
        description = "Link-time optimisation. `thin` is cheap + measurable; `full` is RAM-heavy for little gain.";
      };
      # (No cpusched option: the pre-built cachyosKernels variants bake eevdf in; a
      # scheduler knob here would be a silent no-op. Pick via `variant` if the flake
      # ever exposes scheduler variants.)
    };

    ## ── Network: ONE stack — systemd-networkd from initrd through stage 2 ──
    network = {
      dhcp = mkOption {
        type = types.bool;
        default = true;
        description = ''
          DHCP on every PHYSICAL ethernet link in stage 2, via a networkd catch-all
          (`99-nixnas-ethernet-dhcp` — the same match shape as nixpkgs' translation of
          `networking.useDHCP`: Type=ether, Kind=!*, so veths/bridges/bond members from
          k3s/containers are never grabbed). nixnas runs systemd-networkd as the ONE
          network stack from initrd to stage 2 (see appliance/base.nix): the initrd
          already uses networkd for the remote-unlock NIC, and the first real deployment
          (2026-07-04) showed what the stock dhcpcd stage 2 does instead — two DHCP
          stacks on one interface, stage-2 dhcpcd failing its first start while the
          initrd lease kept answering. The catch-all is numbered 99-, so any
          more-specific `.network` the host declares (lower lexical name) wins
          per-interface; static-IP or bonded hosts just declare theirs. Set false to
          declare ALL stage-2 networking yourself.

          MULTI-NIC boxes (field-proven the same day): two DHCP'd NICs on ONE LAN is a
          lease/ARP war — the DHCP server juggles the host across two MACs between
          boots, and the kernel answers ARP for either port (SSH froze mid-command).
          Either BOND the ports (`systemd.network.netdevs` Kind=bond; active-backup
          needs no switch support) or keep the spare port down (a lower-numbered
          `.network` matching it with `linkConfig.ActivationPolicy = "down"`), or leave
          it unplugged. Never leave two DHCP'd ports on the same broadcast domain.
        '';
      };
    };

    ## ── Crypto: passphrase-only data; TPM is reserved for SSH identity ──
    crypto = {
      recovery = {
        vaultwardenUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://vault.example.com";
          description = ''
            Vaultwarden/Bitwarden base URL to escrow a SEPARATE high-entropy recovery key to
            at provision time. This key is a distinct LUKS keyslot (break-glass), independent
            of the daily passphrase and of any specific box's TPM. Null = no escrow (the
            passphrase keyslot is then the only recovery).
          '';
        };
        credsSops = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Build-machine sops path to the Vaultwarden API client id/secret used for the escrow upload.";
        };
      };
    };

    ## ── ZFS: which OpenZFS to use for the operator's data pools ───────────
    zfs = {
      source = mkOption {
        type = types.enum [ "cachyos" "upstream" ];
        default = "cachyos";
        description = ''
          `cachyos`: the CachyOS ZFS fork that matches `kernel.variant = latest`
          (newer than upstream's cap). `upstream`: stock `zfs_2_4`, which then pins the
          kernel at/under the OpenZFS cap. Safety is structural (rollback + scrub),
          not the source — see docs/KERNEL.md §5.
        '';
      };
    };

    ## ── Storage: connect your existing storage. THIN by design ──────────────
    ## nixnas does NOT reinvent mounting — that is native NixOS (`fileSystems`,
    ## `boot.zfs`, `boot.initrd.luks.devices`). It adds only the one fiddly bit:
    ## unlocking your LUKS members with the SINGLE shared secret, non-fatally. It
    ## NEVER creates, formats, or destroys your storage; the only device it ever
    ## partitions is the USB boot stick.
    storage = {
      unlock = mkOption {
        type = types.attrsOf diskById;
        default = { };
        example = literalExpression ''{ archive0 = "/dev/disk/by-id/ata-…"; }'';
        description = ''
          LUKS data members to unlock POST-boot, as `name → /dev/disk/by-id/…`. Each opens
          as `/dev/mapper/<name>` (a STABLE mapper name you then reference in
          `fileSystems`). Members are `noauto`: the OS boots fully with no data secret, and
          the operator runs `nixnas-unlock` (over SSH/Tailscale), which raises
          `nixnas-storage.target` — members open SERIALLY with ONE passphrase (systemd's
          kernel-keyring cache covers the rest), NON-fatally (a missing disk never fails
          the set). Data members are passphrase-only by design: never TPM-bound, never
          keyfile-persisted — a seized disk yields nothing, and a disk pulled into another
          machine opens with the passphrase alone. Storage-agnostic: LUKS-under-ZFS /
          btrfs / xfs are all the same here. nixnas only OPENS these; you MOUNT the result
          with native NixOS `fileSystems` (add `"noauto"
          "x-systemd.wanted-by=nixnas-storage.target"` to their options) and gate
          dependent services on `nixnas-storage.target`. No `luksFormat`, ever.
        '';
      };
      zfsPools = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "hot" "cold" ]'';
        description = ''
          Optional convenience: ZFS pool names to import as part of the post-boot unlock.
          Each pool gets a `nixnas-import-<pool>` service (ordered after the LUKS unlocks,
          scanning `/dev/mapper`) pulled in by `nixnas-storage.target`; datasets self-mount
          at their `mountpoint` properties. Also enables ZFS support in the image
          (`boot.supportedFilesystems.zfs`). Non-ZFS storage needs nothing here — mount it
          with plain `fileSystems` hooked to the same target.
        '';
      };
    };

    ## ── Store location: OS /nix on the stick (usb) or on the operator's hot storage (hot) ──
    store = {
      location = mkOption {
        type = types.enum [ "usb" "hot" ];
        default = "usb";
        description = ''
          Where the OS's `/nix` store lives (see docs/HOT-MODE.md):
            "usb" (default): the whole OS store is on the USB stick (LUKS2+f2fs). Small
              appliances, max resilience — the OS boots from the stick even with the data
              pool down. The stick is the size ceiling.
            "hot": the MAIN system's `/nix` AND `/` (root — `store.root.*`, REQUIRED, no
              default) live on the operator's own encrypted storage — unlimited, install
              anything system-wide, and an ORDINARY persistent root (no tmpfs, no
              impermanence: a main accumulates operational state and losing it silently on
              reboot is the failure this mode exists to end — see docs/ARCHITECTURE.md §3).
              The stick holds only the ESP + a self-contained RESCUE system (`rescue.*`,
              which DOES keep a tmpfs root — impermanence is right for a rescue, wrong for
              a main). The operator ENTERS THEIR KEY in the initrd to unlock it (never
              auto/TPM). Hub-class boxes. NOT a composed store — two independent systems.
        '';
      };
      hot = {
        device = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot/nixnas/nix";
          description = ''
            `hot` mode: the `fileSystems."/nix".device` for the MAIN system — the store that
            holds the full OS closure. A ZFS dataset name (with `fsType = "zfs"`), or a
            `/dev/mapper/<name>` for LUKS+ext4/btrfs/f2fs. Mounted by the initrd (neededForBoot)
            after `store.hot.unlock` opens the encryption.
          '';
        };
        fsType = mkOption {
          type = types.str;
          default = "zfs";
          example = "ext4";
          description = "Filesystem of `store.hot.device` (zfs/ext4/btrfs/f2fs/…). `zfs` pulls ZFS into the initrd; others don't.";
        };
        zfsMountpoint = mkOption {
          type = types.enum [ "legacy" "property" ];
          default = "legacy";
          example = "property";
          description = ''
            For `fsType = "zfs"`: which of the two root-on-ZFS mount shapes
            `store.hot.device` uses. This is NOT cosmetic — the two are mutually
            exclusive at mount(8), so the module has to be told which one the dataset
            actually carries (a property is runtime state; nothing can detect it at
            eval time).

            - `"legacy"` — the dataset has `mountpoint=legacy`. ZFS declines to manage
              it and the mount is issued plainly. The conventional root-on-ZFS shape.
            - `"property"` — the dataset carries a real `mountpoint` path plus
              `canmount=noauto`, and the mount is issued with `-o zfsutil` so
              `mount.zfs` consults the dataset's own properties. Makes an imported pool
              self-describing (`zfs list` shows where each dataset belongs) at the cost
              of a flag `mount.zfs(8)` documents as private.

            Mixing them fails loudly rather than silently: `-o zfsutil` against a
            `mountpoint=legacy` dataset is refused outright, and a property-mountpoint
            dataset cannot be mounted without it.
          '';
        };
        unlock = mkOption {
          type = types.attrsOf (types.strMatching "/dev/disk/by-[a-z]+/.+");
          default = { };
          example = literalExpression ''{ tank0 = "/dev/disk/by-id/ata-…"; }'';
          description = ''
            The LUKS members the INITRD must open (with the OPERATOR'S key — never TPM auto) to
            reach the hot store, as `name → /dev/disk/by-id/…` (opens at `/dev/mapper/<name>`).
            The operator enters the passphrase over initrd-SSH / console; the box blocks here
            until they do (data stays sealed). Same shape as `storage.unlock`, but in stage-1.
          '';
        };
        zpool = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot";
          description = "For `fsType = \"zfs\"`: the pool the initrd imports (via /dev/mapper) before mounting `store.hot.device`.";
        };
      };
      root = {
        device = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot/nixnas/root";
          description = ''
            `hot` mode: the `fileSystems."/".device` for the MAIN system — an ORDINARY
            persistent root filesystem. REQUIRED, no default: hot mode has no tmpfs root
            (see docs/ARCHITECTURE.md §3, docs/HOT-MODE.md) — the MAIN's `/` must be a real
            device on the operator's own encrypted storage, same as any root-on-ZFS NixOS
            box. A ZFS dataset name (with `fsType = "zfs"`, typically a sibling of
            `store.hot.device` — e.g. `hot/nixnas/root` beside `hot/nixnas/nix`; pick each
            one's mount shape with `zfsMountpoint`), or a `/dev/mapper/<name>` for
            LUKS+ext4/btrfs/f2fs.
            Mounted by the initrd, after the LUKS members that reach it are open.
          '';
        };
        fsType = mkOption {
          type = types.str;
          default = "zfs";
          example = "ext4";
          description = "Filesystem of `store.root.device` (zfs/ext4/btrfs/f2fs/…). `zfs` pulls ZFS into the initrd (merged with `store.hot.fsType`'s own need); others don't.";
        };
        zfsMountpoint = mkOption {
          type = types.enum [ "legacy" "property" ];
          default = "legacy";
          example = "property";
          description = ''
            For `fsType = "zfs"`: which of the two root-on-ZFS mount shapes
            `store.root.device` uses — see `store.hot.zfsMountpoint` for the full
            mechanism. Root and /nix are set independently; they need not match.

            One caution specific to `/`: switching an existing dataset from `legacy` to
            `"property"` is a two-step operation, because a plain
            `zfs set mountpoint=/ <dataset>` MOUNTS IT IMMEDIATELY at the new location —
            which for a root dataset means over the running system's `/`. Set
            `canmount=noauto` FIRST, then use `zfs set -u` (update the property, do not
            mount). See docs/MIGRATE-HOT-ROOT.md.
          '';
        };
        zpool = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "hot";
          description = ''
            For `fsType = "zfs"`: the pool the initrd imports (via /dev/mapper) before
            mounting `store.root.device`. Leave null when it derives from the device name
            (`"hot/nixnas/root"` → pool `hot`) — set it only when that derivation is wrong,
            exactly like `store.hot.zpool`. Usually the SAME pool as `store.hot.zpool` (root
            and /nix as sibling datasets); the initrd imports each distinct pool exactly once.
          '';
        };
        unlock = mkOption {
          type = types.attrsOf (types.strMatching "/dev/disk/by-[a-z]+/.+");
          default = { };
          example = literalExpression ''{ tank0 = "/dev/disk/by-id/ata-…"; }'';
          description = ''
            EXTRA LUKS members the INITRD must open to reach the root filesystem, beyond
            whatever `store.hot.unlock` already opens — same shape, same one-passphrase
            chain (merged with `store.hot.unlock` ∪ `storage.unlock` into ONE serialised
            keyring unlock; see modules/store/location.nix). Leave empty when root and
            `/nix` live on the SAME encrypted pool/members (the common case — root is just
            a sibling dataset); set members here only when the root device lives on disks
            `store.hot.unlock` does not already cover.
          '';
        };
      };
      preload = mkOption {
        type = types.bool;
        default = config.nixnas.store.location == "usb";
        defaultText = literalExpression ''store.location == "usb"'';
        description = ''
          Warm the booted generation's closure into the (compress-)cache after boot, so
          runtime reads come from RAM and the slow stick is untouched — "copytoram done
          right" (compressed in RAM, self-update intact). Defaults ON in `usb` mode; OFF in
          `hot` mode, where /nix is already on the fast pool so warming it into RAM only
          wastes memory. Turn off on very RAM-constrained boxes. See docs/OPTIMIZATIONS.md §5.
        '';
      };
      maxClosureBytes = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = literalExpression "5 * 1024 * 1024 * 1024"; # ~5 GiB uncompressed
        description = ''
          Build-time BUDGET for the host's toplevel closure, in uncompressed bytes. When set,
          `system.build.storeClosureBudget` FAILS the build if the closure exceeds it — wire
          that attribute into your flake `checks` so CI (and every rebuild) enforces it.

          Why ONE number bounds everything: the on-stick f2fs store holds this closure per
          kept generation (compressed ~2.3× by zstd), and `store.preload` warms it into RAM.
          So a single budget caps BOTH the USB fit (`usb.imageSizeGiB` minus the ESP, across
          `boot.keepGenerations`) AND the preload RAM. A lean base+k3s+container-runtime host
          is ~4 GiB uncompressed (~1.8 GiB compressed / ~1.8 GiB RAM); heavy things — dev
          toolchains, agents, container images, data — belong in build pods / containers on
          your pool, NEVER the host OS. The budget makes "it stays lean" structural: an
          accidental fat package fails the build instead of silently overflowing the stick.
        '';
      };
      persistLogs = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Persist the journal to the USB stick instead of RAM. DEFAULT OFF — normally logs
          are volatile (RAM) so the stick takes ~no writes. Turn this on only TEMPORARILY, to
          debug a problem whose evidence must survive a reboot/crash (e.g. an unlock or boot
          failure, where the data pools aren't up yet). It writes the stick, so turn it back
          off when done.
        '';
      };
      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Extra packages for a USB-resident nixnas appliance. Fleet recovery belongs to the
          separate nixrescue boot role; this option does not create or maintain one.
        '';
      };
    };

    ## ── Appliance plumbing ────────────────────────────────────────────────
    admin = {
      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "ssh-ed25519 AAAA… you@host" ]'';
        description = ''
          SSH public keys that may log in as root — for BOTH the running system (headless
          admin once booted) and the initrd (remote store unlock). SSH is key-only:
          password login over SSH is off, so at least one key is required for remote
          access. (CONSOLE login is separate: root — and `auth.adminUser`, if set — log
          in at the console with the ONE store passphrase; see modules/appliance/auth.nix.)
        '';
      };
    };

    ## ── Product auth: console login with the ONE store passphrase ─────────
    auth = {
      adminUser = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "julian";
        description = ''
          Optional NORMAL admin user (wheel, default sudo-with-password). Its console
          password is the SAME single secret as root's: the store passphrase, via the
          runtime hash file the TUI injects at build time
          (`/nix/nixnas/auth/passphrase.hash` — on the encrypted store, never in the Nix
          store). Its SSH login uses `admin.authorizedKeys` (key-only, like root). Null
          (the default) = no extra user; root is the only account. See
          modules/appliance/auth.nix for the full access model and its fail-closed
          behaviour when the hash file is absent.
        '';
      };
    };

    tailscale = {
      enable = mkEnableOption "Tailscale — headless management plane + remote LUKS unlock path";
      authKeySops = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path (sops) to the Tailscale auth key.";
      };
    };

    ## ── Tier-1 persistence: identity that must survive reboot BEFORE the data pools unlock ──
    ## USB MODE ONLY. `hot` mode has no tmpfs root to route state around (store.root.* is an
    ## ordinary persistent filesystem — see modules/store/location.nix), so these two options
    ## are inert there: modules/appliance/identity.nix and modules/appliance/persist-enforce.nix
    ## both gate on `store.location == "usb"`, and location.nix's own hot-mode assertions
    ## REFUSE a hot-mode host that still sets either one non-empty (see its assertions) —
    ## a silently-ignored persistence option is exactly the footgun this whole area exists to
    ## prevent.
    persist = {
      overlayClients = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "tailscale" "netbird" ]'';
        description = ''
          `usb` mode only (see the section note above). Names of overlay/mesh-VPN clients
          whose `/var/lib/<name>` state directory must survive a reboot for the box to be
          REACHABLE before the data pools unlock — the same problem `admin.authorizedKeys` +
          `boot.remoteUnlock` solve for SSH, but for the mesh identity the operator actually
          connects over. Each name gets a Tier-1 bind mount (`/var/lib/<name>` →
          `/nix/persist/var/lib/<name>`), created and mounted in stage-1 (see
          modules/appliance/identity.nix) alongside machine-id and the SSH host keys — small,
          rarely-written identity state, kind to the stick. Losing one of these on every
          reboot means the client re-provisions (or never rejoins) its mesh — the exact
          failure class this option exists to prevent. In `hot` mode this need never arises:
          the persistent root already keeps `/var/lib/<name>` across a reboot, the same as
          any ordinary NixOS box — leave this at its default `[ ]` there.
        '';
      };
      explicitlyEphemeral = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''[ "systemd-timesyncd" "unbound" ]'';
        description = ''
          `usb` mode only (see the section note above). Systemd service names (as in
          `config.systemd.services.<name>`) whose declared `serviceConfig.StateDirectory` is
          a DELIBERATE, first-class acknowledgment that losing that state every reboot is
          fine — self-healing caches, regenerated keys, scratch/lock directories. This is
          NOT a default or a fallback: it is the explicit opt-in half of the build-time
          enforcement in modules/appliance/persist-enforce.nix, which fails the build for any
          StateDirectory-bearing service that is neither backed by a real `fileSystems`
          entry (from this module's own Tier-1 bind mounts, or the operator's own
          Tier-2/Tier-3 persistence) nor listed here. Only list a service once its state
          has been checked and genuinely found disposable — an unlisted, unbacked service
          is meant to fail the build until that check happens.
        '';
      };
    };

    ## ── Self-update (autoUpgrade) ─────────────────────────────────────────
    autoUpgrade = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let the box self-update from `autoUpgrade.flake` (no effect until that is set).
          It STAGES a new generation for the next boot — it never reboots itself (see
          `flake`). Updating the appliance = committing to the operator's flake.
        '';
      };
      flake = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "github:you/nas-config#nas";
        description = ''
          The operator's flake (their config that `imports = [ nixnas ]`). Null = no
          self-update. Private flakes need pull auth the operator supplies (deploy key /
          netrc); that, and update-on-the-8 GiB-target, is the autoUpgrade spike (ARCH §9.2).
        '';
      };
      schedule = mkOption {
        type = types.str;
        default = "04:40";
        description = "systemd `OnCalendar` schedule for the self-update check.";
      };
    };
  };
}
