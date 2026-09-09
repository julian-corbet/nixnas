Checks are selected through `.ci/ccid.toml` and run by the pinned shared ccid runner on a trusted worker.

The default selection is `syntax,configuration,tui`. Native Linux success does not certify a foreign architecture, a separately selected image or hardware gate, or publication. Use `list` to inspect available native Nix checks, and select existing results or affected checks before scheduling more work.

Additional coverage limits:

- Image, Secure Boot, TPM-negative, power-cut, HOT ext4/ZFS, and soak gates require isolated disposable guests. Existing host-root disk/ZFS scripts must not run directly on shared Crow host.
- Release builds musl TUI and publishes GitHub release; preserve exact tag and publication trust.
