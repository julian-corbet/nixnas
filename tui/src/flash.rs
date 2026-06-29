//! Flash the built image to a USB stick: optionally back the current stick up first
//! (default: yes), then COMPLETELY overwrite it.
//!
//! The dangerous block-device WRITE is delegated to `caligula` (a separate GPL-3.0
//! tool invoked as a subprocess — arm's-length, so nixnas stays Apache-2.0). It
//! brings disk detection, confirmation, and post-write verification. We only do the
//! safe READ (backup) ourselves.

use anyhow::{bail, Context, Result};
use dialoguer::{theme::ColorfulTheme, Confirm, Select};
use serde::Deserialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Deserialize)]
struct LsblkOut {
    blockdevices: Vec<BlockDevice>,
}

#[derive(Debug, Deserialize)]
struct BlockDevice {
    name: String,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    model: Option<String>,
    /// removable
    #[serde(default)]
    rm: Option<bool>,
    #[serde(rename = "type", default)]
    dev_type: Option<String>,
}

/// The candidate USB sticks: removable whole disks.
fn removable_devices() -> Result<Vec<BlockDevice>> {
    let out = Command::new("lsblk")
        .args(["-J", "-o", "NAME,SIZE,MODEL,RM,TYPE"])
        .output()
        .context("running lsblk")?;
    if !out.status.success() {
        bail!("lsblk failed");
    }
    let parsed: LsblkOut =
        serde_json::from_slice(&out.stdout).context("parsing lsblk output")?;
    Ok(parsed
        .blockdevices
        .into_iter()
        .filter(|d| d.rm.unwrap_or(false) && d.dev_type.as_deref() == Some("disk"))
        .collect())
}

pub fn flash(theme: &ColorfulTheme, config_path: &Path) -> Result<()> {
    let dir = config_path.parent().unwrap_or_else(|| Path::new("."));
    let image = dir.join(".nixnas-image");
    if !image.exists() {
        bail!("no built image found — run `Build image` first");
    }

    let devices = removable_devices()?;
    if devices.is_empty() {
        bail!("no removable USB devices found — plug the stick in and retry");
    }
    let labels: Vec<String> = devices
        .iter()
        .map(|d| {
            format!(
                "/dev/{}  {}  {}",
                d.name,
                d.size.clone().unwrap_or_default(),
                d.model.clone().unwrap_or_default()
            )
        })
        .collect();

    let idx = Select::with_theme(theme)
        .with_prompt("Target USB stick (will be OVERWRITTEN)")
        .items(&labels)
        .interact()?;
    let dev = format!("/dev/{}", devices[idx].name);

    // Safety: back the current stick up first (default yes).
    let backup = Confirm::with_theme(theme)
        .with_prompt(format!("Back up the current contents of {dev} to an image first?"))
        .default(true)
        .interact()?;
    if backup {
        let dest = dir.join("nixnas-backup.img");
        eprintln!("Backing up {dev} -> {} …", dest.display());
        let status = Command::new("dd")
            .arg(format!("if={dev}"))
            .arg(format!("of={}", dest.display()))
            .args(["bs=4M", "status=progress", "conv=fsync"])
            .status()
            .context("running dd for backup")?;
        if !status.success() {
            bail!("backup failed — aborting before any write");
        }
    }

    // Hand the dangerous overwrite to caligula (post-write verify included).
    let status = Command::new("caligula")
        .arg("burn")
        .arg(&image)
        .args(["-o", &dev, "--interactive", "never"])
        .status()
        .context("running `caligula burn` (is caligula installed?)")?;
    if !status.success() {
        bail!("caligula burn failed");
    }
    println!("Done — {dev} is now a nixnas stick.");
    Ok(())
}
