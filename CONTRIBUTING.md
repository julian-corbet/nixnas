# Contributing to nixnas

nixnas is built to be adopted and extended by others, not just one machine. Contributions
are welcome under the project's [Apache-2.0](LICENSE) license.

## What nixnas is (so PRs stay in scope)

nixnas is the **appliance mechanism**: boot / crypto / the on-stick f2fs store / kernel
packaging, exposed through the typed `nixnas.*` options. It turns any `nixosConfiguration`
into a USB-bootable, RAM-resident, encrypted, rollback-safe appliance. The *workloads* a box
runs (k3s, containers, shares, GPU) are **plain NixOS the operator brings** — not nixnas. See
[`docs/SCOPE.md`](docs/SCOPE.md) for the exact boundary; a PR that pulls workload concerns into
the core will be asked to move them out.

## Ground rules

- **FOSS-clean core.** The public repo carries no hostname, IP, disk serial, URL, or other
  site-specific fact — not even in comments. Every site value is a typed `nixnas.*` option; real
  values live in the operator's *private* overlay (`templates/host/` scaffolds one). The
  `hosts/demo` host uses only RFC-5737 / RFC-2606 / `DEMO-*` placeholders.
- **Fail closed.** Security-relevant defaults must fail loudly, never silently degrade (e.g. a
  build without an injected LUKS passphrase must error, not fall back to a public one).
- **Docs track code.** `docs/` describes the *as-built* mechanism. A `⬢`-marked "appliance
  default" must be greppable in `modules/`; decided-but-unimplemented is marked `◇`.

## Before you open a PR

1. **Nix**: `nix flake check` (the demo evaluates with every assertion; CI runs the demo
   toplevel + imageScript drvPath eval).
2. **TUI**: in `tui/`, `cargo check --locked` and `cargo clippy --locked -- -D warnings`.
3. **Boot behaviour**: changes to the boot chain / crypto / storage should be exercised in the
   QEMU rig (`test/boot-vm.sh`, `test/seal-3boot-test.sh`) — it models UEFI + Secure Boot +
   swtpm + serial. Note what you ran in the PR.
4. **Commit style**: imperative subject, a body that says *why*. No AI attribution lines.

## Contributor agreement

By submitting a contribution, you agree to the
[Individual Contributor License Agreement](https://github.com/corbet-labs/.github/blob/cla-v1.0/CLA.md).
Include this exact affirmation in your pull request description:

<!-- markdownlint-disable MD034 -->
<!-- prettier-ignore -->
> I have read and agree to version 1.0 of the Individual Contributor License Agreement at https://github.com/corbet-labs/.github/blob/cla-v1.0/CLA.md.
<!-- markdownlint-enable MD034 -->

## Reporting security issues

Boot chain, crypto, or unlock-path issues: please disclose privately first (open a GitHub
security advisory) rather than a public issue, so a fix can land before disclosure.
