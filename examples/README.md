# examples

Reference configs. These are **illustrative** — they show the patterns; they are not
built by CI (the zero-secrets host that IS built lives in `hosts/demo/`).

- **`host.nix`** — a fully worked operator host config. It shows the whole storage story
  end to end: unlocking your LUKS members (`nixnas.storage.unlock`), importing ZFS pools,
  a **nested foreign filesystem** (an XFS archive drive mounted *under* a ZFS pool tree),
  directing container images onto a pool (so the tiny USB stick never fills), and persisting
  service state off the RAM root with the impermanence module. Plus your actual workloads as
  plain NixOS.

## Where things live

| | |
|---|---|
| **This repo (public)** | the appliance *mechanism* + these *examples*. No real device-ids, keys, or topology. |
| **Your repo (private)** | your real host config — the actual `host.nix` with your disks, keys, pools, and workloads. Scaffold it with `nix flake init -t github:julian-corbet/nixnas#host`. |

The one thing to keep straight: the USB stick only holds the OS (loaded into RAM). Container
images, databases, media, and service state all get directed onto your **pools** — never the
stick. Mounting is native NixOS; nixnas only unlocks your LUKS members and never
creates, formats, or destroys anything.
