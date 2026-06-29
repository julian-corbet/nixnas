//! Build the personalised nixnas image LOCALLY via Nix.
//!
//! The image is built on THIS machine by design: it embeds your config and is signed
//! with your own Secure Boot keys, so it can be neither pre-built generically nor
//! built on the k3s it will host (chicken-and-egg). There is no remote build path.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Runs `nix build .#image` in the directory holding the host's `nixnas.config`
/// (your infra repo — its flake composes nixnas + this config) and returns the
/// out-link to the built image.
pub fn build_image(config_path: &Path) -> Result<PathBuf> {
    let dir = config_path.parent().unwrap_or_else(|| Path::new("."));
    let out_link = dir.join(".nixnas-image");

    let status = Command::new("nix")
        .args(["build", "--print-build-logs", ".#image", "--out-link"])
        .arg(&out_link)
        .current_dir(dir)
        .status()
        .context("running `nix build` (is Nix installed locally?)")?;

    if !status.success() {
        bail!("nix build failed");
    }
    Ok(out_link)
}
