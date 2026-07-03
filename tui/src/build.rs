//! Build the personalised nixnas image LOCALLY via Nix.
//!
//! The image is built on THIS machine by design: it embeds your config and (with
//! `sb_keys_sops`) your own Secure Boot keys, so it can be neither pre-built
//! generically nor built on the infrastructure it will host (chicken-and-egg).
//! There is no remote build path.
//!
//! Pipeline (all secrets stay out of the Nix store):
//!   1. `nix build .#imageScript` — a PURE eval; the flake needs no secrets.
//!   2. Prompt for the LUKS store passphrase → a 0600 file in RAM-backed tmp.
//!   3. If configured, `sops --decrypt` the Secure Boot PKI tar → RAM-backed tmp.
//!   4. Run the disko image script with `--pre-format-files <passphrase>
//!      /tmp/nixnas-luks.key` (used at luksFormat) and `--post-format-files <pki dir>
//!      /nix/lanzaboote/pki` (lands on the encrypted store). The .raw is written into
//!      `.nixnas-image/` next to the config.
//!   5. Zero + remove the secret temp files, regardless of success or failure.

use crate::config::{config_dir, Config};
use anyhow::{bail, Context, Result};
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// RAII guard: overwrite IN PLACE with zeros (no truncate — truncating first would
/// free the original blocks unzeroed), fsync, then unlink. Best-effort, and the
/// files live under /dev/shm when available, so nothing hits a disk to begin with.
struct ShredOnDrop(PathBuf);

impl Drop for ShredOnDrop {
    fn drop(&mut self) {
        if let Ok(meta) = std::fs::metadata(&self.0) {
            let len = meta.len() as usize;
            if len > 0 {
                if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open(&self.0) {
                    let _ = f.seek(SeekFrom::Start(0));
                    let _ = f.write_all(&vec![0u8; len]);
                    let _ = f.sync_all();
                }
            }
        }
        let _ = std::fs::remove_file(&self.0);
    }
}

/// RAII guard: shred every regular file under a directory, then remove the tree.
struct ShredDirOnDrop(PathBuf);

impl Drop for ShredDirOnDrop {
    fn drop(&mut self) {
        fn walk(dir: &Path) {
            if let Ok(rd) = std::fs::read_dir(dir) {
                for entry in rd.flatten() {
                    let p = entry.path();
                    if p.is_dir() {
                        walk(&p);
                    } else {
                        drop(ShredOnDrop(p));
                    }
                }
            }
        }
        walk(&self.0);
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// RAM-backed temp location when available (no disk residue for secrets).
fn secure_tmp() -> PathBuf {
    let shm = Path::new("/dev/shm");
    if shm.is_dir() {
        shm.to_path_buf()
    } else {
        std::env::temp_dir()
    }
}

/// Builds the image script from the operator's flake and runs it with the secrets
/// injected. Returns the path of the built `.raw`.
pub fn build_image(config_path: &Path, cfg: &Config) -> Result<PathBuf> {
    let base = config_dir(config_path);
    let flake_dir = cfg.resolved_flake_dir(config_path);
    let script_link = base.join(".nixnas-imagescript");
    let out_dir = base.join(".nixnas-image");

    // 1. Build the disko image script (pure eval — no secrets involved).
    let status = Command::new("nix")
        .args(["build", "--print-build-logs", "--accept-flake-config", ".#imageScript", "--out-link"])
        .arg(&script_link)
        .current_dir(&flake_dir)
        .status()
        .context("running `nix build .#imageScript` (is Nix installed locally?)")?;
    if !status.success() {
        bail!("nix build .#imageScript failed");
    }

    // 2. Prompt for the LUKS store passphrase (confirmed, not echoed) → 0600 RAM tmp.
    let passphrase = dialoguer::Password::new()
        .with_prompt("LUKS store passphrase (RAM-backed 0600 file; zeroed after the build)")
        .with_confirmation("Confirm passphrase", "Passphrases do not match")
        .interact()
        .context("reading LUKS passphrase")?;

    let key_path = secure_tmp().join(format!("nixnas-luks-{}", std::process::id()));
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&key_path)
            .with_context(|| format!("creating temp passphrase file {}", key_path.display()))?;
        f.write_all(passphrase.as_bytes())
            .context("writing passphrase to temp file")?;
    }
    let _key_guard = ShredOnDrop(key_path.clone());

    // 3. Optional: decrypt the Secure Boot PKI (sops tar) into a RAM tmp dir.
    let mut pki_dir: Option<PathBuf> = None;
    let mut _pki_guard: Option<ShredDirOnDrop> = None;
    if let Some(sops_file) = &cfg.sb_keys_sops {
        let sops_path = {
            let p = Path::new(sops_file);
            if p.is_absolute() { p.to_path_buf() } else { base.join(p) }
        };
        let dir = secure_tmp().join(format!("nixnas-sbpki-{}", std::process::id()));
        std::fs::create_dir(&dir).context("creating PKI temp dir")?;
        std::fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .context("restricting PKI temp dir")?;
        _pki_guard = Some(ShredDirOnDrop(dir.clone()));

        let decrypted = Command::new("sops")
            .arg("--decrypt")
            .arg(&sops_path)
            .output()
            .context("running sops (is it installed, with the age key available?)")?;
        if !decrypted.status.success() {
            bail!(
                "sops --decrypt {} failed:\n{}",
                sops_path.display(),
                String::from_utf8_lossy(&decrypted.stderr)
            );
        }
        let mut tar = Command::new("tar")
            .args(["-xf", "-", "-C"])
            .arg(&dir)
            .stdin(Stdio::piped())
            .spawn()
            .context("running tar")?;
        tar.stdin
            .as_mut()
            .context("opening tar stdin")?
            .write_all(&decrypted.stdout)
            .context("streaming PKI tar to tar")?;
        if !tar.wait().context("waiting for tar")?.success() {
            bail!("extracting the Secure Boot PKI tar failed");
        }
        pki_dir = Some(dir);
    }

    // 4. Run the image script; the .raw lands in out_dir (the script writes to CWD).
    std::fs::create_dir_all(&out_dir).context("creating image output dir")?;
    let mut run = Command::new(std::fs::canonicalize(&script_link).context("resolving image script")?);
    run.current_dir(&out_dir);
    if let Some(mem) = cfg.build_memory_mib {
        run.args(["--build-memory", &mem.to_string()]);
    }
    // The conventional in-VM path modules/boot/disk.nix reads at luksFormat time.
    run.arg("--pre-format-files").arg(&key_path).arg("/tmp/nixnas-luks.key");
    if let Some(pki) = &pki_dir {
        // Lands on the finished image's encrypted store; lanzaboote signs from day one.
        run.arg("--post-format-files").arg(pki).arg("/nix/lanzaboote/pki");
    }
    let status = run.status().context("running the disko image script")?;
    if !status.success() {
        bail!("image build failed");
    }

    // 5. Find the built .raw (disko names it after the disk's imageName).
    let raw = std::fs::read_dir(&out_dir)
        .with_context(|| format!("reading built image dir {}", out_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|x| x == "raw"))
        .context("no .raw file in the image output dir")?;
    Ok(raw)
}
