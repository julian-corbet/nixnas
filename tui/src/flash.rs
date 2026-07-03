//! Flash the built image to a USB stick: optionally back the current stick up first
//! (default: yes), then COMPLETELY overwrite it.
//!
//! The dangerous block-device WRITE is delegated to `caligula` (a separate GPL-3.0
//! tool invoked as a subprocess — arm's-length, so nixnas stays Apache-2.0). It
//! brings disk detection, confirmation, and post-write verification. We only do the
//! safe READ (backup) ourselves, and we independently VERIFY the device afterwards —
//! caligula exits 0 when its confirmation is declined, so its exit code alone must
//! not be trusted as "written".

use crate::config::config_dir;
use anyhow::{bail, Context, Result};
use dialoguer::{theme::ColorfulTheme, Confirm, Input, Select};
use serde::{Deserialize, Deserializer};
use std::io::Read;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Deserialize)]
struct LsblkOut {
    blockdevices: Vec<BlockDevice>,
}

/// lsblk emits real JSON booleans on current util-linux but "0"/"1" strings on
/// older releases — accept both instead of failing the parse.
fn flexible_bool<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        B(bool),
        I(i64),
        S(String),
    }
    Ok(match Option::<Raw>::deserialize(d)? {
        None => None,
        Some(Raw::B(b)) => Some(b),
        Some(Raw::I(i)) => Some(i != 0),
        Some(Raw::S(s)) => Some(s == "1" || s.eq_ignore_ascii_case("true")),
    })
}

#[derive(Debug, Deserialize)]
struct BlockDevice {
    name: String,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    model: Option<String>,
    /// removable
    #[serde(default, deserialize_with = "flexible_bool")]
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

/// Compare the first `len` bytes of two files. Used to prove the device actually
/// carries the image after caligula returns (its exit code can't be trusted alone).
fn same_prefix(a: &Path, b: &Path, len: usize) -> Result<bool> {
    let read_prefix = |p: &Path| -> Result<Vec<u8>> {
        let mut f = std::fs::File::open(p).with_context(|| format!("opening {}", p.display()))?;
        let mut buf = vec![0u8; len];
        let mut got = 0;
        while got < len {
            let n = f.read(&mut buf[got..]).with_context(|| format!("reading {}", p.display()))?;
            if n == 0 {
                break;
            }
            got += n;
        }
        buf.truncate(got);
        Ok(buf)
    };
    let pa = read_prefix(a)?;
    let pb = read_prefix(b)?;
    Ok(!pa.is_empty() && pa.len() == pb.len().min(pa.len()) && pb[..pa.len()] == pa[..])
}

pub fn flash(theme: &ColorfulTheme, config_path: &Path) -> Result<()> {
    let dir = config_dir(config_path);
    // The image build output is a DIRECTORY holding the `.raw`; find the raw file
    // (caligula burns the file, not the directory).
    let out_link = dir.join(".nixnas-image");
    let image = std::fs::read_dir(&out_link)
        .ok()
        .and_then(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .find(|p| p.extension().is_some_and(|x| x == "raw"))
        })
        .context("no built image found — run `Build image` first")?;

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

    // The point of no return is OURS, typed in full — not buried in a subprocess.
    let typed: String = Input::with_theme(theme)
        .with_prompt(format!("Type the device path ({dev}) to confirm the overwrite"))
        .interact_text()?;
    if typed.trim() != dev {
        bail!("confirmation did not match {dev} — nothing written");
    }

    // Hand the write to caligula (its own prompt + post-write verify still apply).
    let status = Command::new("caligula")
        .arg("burn")
        .arg(&image)
        .args(["-o", &dev])
        .status()
        .context("running `caligula burn` (is caligula installed?)")?;
    if !status.success() {
        bail!("caligula burn failed");
    }

    // Independent proof: the stick must now START with the image (caligula exits 0
    // even when its confirmation is declined — never report success on trust).
    if !same_prefix(&image, Path::new(&dev), 4 * 1024 * 1024)
        .context("verifying the written device")?
    {
        bail!("{dev} does not carry the image header — the write was declined or failed");
    }
    println!("Done — {dev} is now a nixnas stick (header verified).");
    Ok(())
}
