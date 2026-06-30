//! Build the personalised nixnas image LOCALLY via Nix.
//!
//! The image is built on THIS machine by design: it embeds your config and is signed
//! with your own Secure Boot keys, so it can be neither pre-built generically nor
//! built on the k3s it will host (chicken-and-egg). There is no remote build path.

use anyhow::{bail, Context, Result};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// RAII guard: best-effort single-pass overwrite then unlink on drop.
/// Ensures the passphrase temp file is shredded even if the build panics or fails.
struct ShredOnDrop(PathBuf);

impl Drop for ShredOnDrop {
    fn drop(&mut self) {
        // Overwrite with zeros (single pass — enough for SSD/tmpfs threat model).
        if let Ok(meta) = std::fs::metadata(&self.0) {
            let len = meta.len() as usize;
            if len > 0 {
                let _ = std::fs::write(&self.0, vec![0u8; len]);
            }
        }
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Runs `nix build .#image` in the directory holding the host's `nixnas.config`
/// (your infra repo — its flake composes nixnas + this config) and returns the
/// out-link to the built image.
///
/// Before invoking Nix, prompts for the LUKS store passphrase and writes it to a
/// 0600 temp file. The file is shredded (zeroed + removed) after the build,
/// regardless of success or failure. Nix is invoked with `--impure` so that
/// `builtins.getEnv "NIXNAS_LUKS_PASSPHRASE_FILE"` resolves inside host.nix.
pub fn build_image(config_path: &Path) -> Result<PathBuf> {
    let dir = config_path.parent().unwrap_or_else(|| Path::new("."));
    let out_link = dir.join(".nixnas-image");

    // Prompt for the LUKS store passphrase (confirmed, not echoed).
    let passphrase = dialoguer::Password::new()
        .with_prompt(
            "LUKS store passphrase (written to a transient 0600 file; shredded after build)",
        )
        .with_confirmation("Confirm passphrase", "Passphrases do not match")
        .interact()
        .context("reading LUKS passphrase")?;

    // Write to a temp file with mode 0600 from creation (no world-readable window).
    let tmp_path = std::env::temp_dir()
        .join(format!("nixnas-luks-{}", std::process::id()));
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp_path)
            .with_context(|| format!("creating temp passphrase file {}", tmp_path.display()))?;
        f.write_all(passphrase.as_bytes())
            .context("writing passphrase to temp file")?;
    }
    // Drop guard: zeroes + removes the file on scope exit, even on error.
    let _guard = ShredOnDrop(tmp_path.clone());

    let status = Command::new("nix")
        .args([
            "build",
            "--impure",
            "--print-build-logs",
            "--accept-flake-config",
            ".#image",
            "--out-link",
        ])
        .arg(&out_link)
        .env("NIXNAS_LUKS_PASSPHRASE_FILE", &tmp_path)
        .current_dir(dir)
        .status()
        .context("running `nix build` (is Nix installed locally?)")?;

    if !status.success() {
        bail!("nix build failed");
    }

    // `.#image` (disko diskoImages) produces a DIRECTORY containing the `.raw`; return the raw file.
    let raw = std::fs::read_dir(&out_link)
        .with_context(|| format!("reading built image dir {}", out_link.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().map_or(false, |x| x == "raw"))
        .context("no .raw file in the built image output")?;
    Ok(raw)
}
