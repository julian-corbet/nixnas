//! Flash the built image to a USB stick: optionally back the current stick up first
//! (default: yes), then COMPLETELY overwrite it.
//!
//! The UI owns every safety gate: only whole disks are listed (removable/USB marked
//! prominently, internal disks marked scary), the operator must TYPE the bare device
//! name to arm the write, and the point of no return is ours — never buried in a
//! subprocess. The write itself is a plain in-process copy loop (progress by byte
//! counter), followed by an fsync and an independent header verification: the device
//! must actually START with the image before we ever report success.

use crate::config::config_dir;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Deserializer};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{Receiver, Sender};

/// How many bytes of prefix must match to call the write verified. 4 MiB covers the
/// GPT + ESP header region — a declined or failed write cannot fake it.
const VERIFY_PREFIX_LEN: usize = 4 * 1024 * 1024;

/// Copy chunk size; also the progress-report granularity.
const CHUNK: usize = 4 * 1024 * 1024;

#[derive(Debug, Deserialize)]
struct LsblkOut {
    blockdevices: Vec<LsblkDevice>,
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

/// Same defensiveness for SIZE: `-b` prints bytes, but old lsblk quotes numbers.
fn flexible_u64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        I(u64),
        S(String),
    }
    Ok(match Option::<Raw>::deserialize(d)? {
        None => None,
        Some(Raw::I(i)) => Some(i),
        Some(Raw::S(s)) => s.trim().parse().ok(),
    })
}

#[derive(Debug, Deserialize)]
struct LsblkDevice {
    name: String,
    #[serde(default, deserialize_with = "flexible_u64")]
    size: Option<u64>,
    #[serde(rename = "type", default)]
    dev_type: Option<String>,
    /// transport (usb, sata, nvme, …)
    #[serde(default)]
    tran: Option<String>,
    /// removable
    #[serde(default, deserialize_with = "flexible_bool")]
    rm: Option<bool>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    children: Vec<LsblkDevice>,
}

/// A whole disk as the FLASH screen presents it, with its partitions as context.
#[derive(Debug, Clone)]
pub struct Disk {
    /// Bare kernel name (`sda`) — exactly what the typed confirmation must match.
    pub name: String,
    pub size: Option<u64>,
    pub tran: Option<String>,
    pub removable: bool,
    pub model: Option<String>,
    pub parts: Vec<Part>,
}

#[derive(Debug, Clone)]
pub struct Part {
    pub name: String,
    pub size: Option<u64>,
    pub label: Option<String>,
}

impl Disk {
    pub fn dev_path(&self) -> PathBuf {
        PathBuf::from(format!("/dev/{}", self.name))
    }

    /// USB sticks are the intended target; anything else gets marked scary in the UI.
    pub fn looks_like_usb_stick(&self) -> bool {
        self.removable || self.tran.as_deref() == Some("usb")
    }
}

/// All whole disks on the system. The old TUI hid non-removable disks entirely; the
/// full-screen list shows them (marked as internal) so the operator understands what
/// lsblk sees — the typed-name confirmation remains the actual write gate.
pub fn list_disks() -> Result<Vec<Disk>> {
    let out = Command::new("lsblk")
        // `-b`: byte-exact sizes, needed for the image-fits-on-device check.
        .args(["-J", "-b", "-o", "NAME,SIZE,TYPE,TRAN,RM,MODEL,LABEL"])
        .output()
        .context("running lsblk")?;
    if !out.status.success() {
        bail!("lsblk failed");
    }
    let parsed: LsblkOut = serde_json::from_slice(&out.stdout).context("parsing lsblk output")?;
    Ok(parsed
        .blockdevices
        .into_iter()
        .filter(|d| d.dev_type.as_deref() == Some("disk"))
        .map(|d| Disk {
            name: d.name,
            size: d.size,
            tran: d.tran,
            removable: d.rm.unwrap_or(false),
            model: d.model.filter(|m| !m.trim().is_empty()),
            parts: d
                .children
                .into_iter()
                .filter(|c| c.dev_type.as_deref() == Some("part"))
                .map(|c| Part {
                    name: c.name,
                    size: c.size,
                    label: c.label,
                })
                .collect(),
        })
        .collect())
}

/// The built `.raw` next to the config (the image build output is a DIRECTORY).
pub fn find_image(config_path: &Path) -> Result<PathBuf> {
    let out_link = config_dir(config_path).join(".nixnas-image");
    std::fs::read_dir(&out_link)
        .ok()
        .and_then(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .find(|p| p.extension().is_some_and(|x| x == "raw"))
        })
        .context("no built image found — run `Build image` first")
}

/// `13.4 GiB`-style rendering (lsblk is queried with `-b` for exact bytes).
pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = bytes as f64;
    let mut unit = 0;
    while v >= 1024.0 && unit < UNITS.len() - 1 {
        v /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", UNITS[unit])
    }
}

/// Worker → UI protocol for a running flash.
pub enum FlashEvent {
    /// A new phase begins (backup / write / verify); resets the gauge.
    Phase(&'static str),
    Progress {
        done: u64,
        total: u64,
    },
    /// Terminal event: success message, or the rendered error chain.
    Done(Result<String, String>),
}

/// Spawn the flash worker: optional device backup, then image write + fsync +
/// header verification. All gates (typed confirmation, size check) have already
/// been passed by the UI at this point.
pub fn spawn_flash(
    image: PathBuf,
    dev: PathBuf,
    dev_size: Option<u64>,
    backup_to: Option<PathBuf>,
    grow: bool,
) -> Receiver<FlashEvent> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = run_flash(&image, &dev, dev_size, backup_to.as_deref(), grow, &tx);
        let _ = tx.send(FlashEvent::Done(result.map_err(|e| format!("{e:#}"))));
    });
    rx
}

fn run_flash(
    image: &Path,
    dev: &Path,
    dev_size: Option<u64>,
    backup_to: Option<&Path>,
    grow: bool,
    tx: &Sender<FlashEvent>,
) -> Result<String> {
    // Safety: back the current stick up first (the UI defaults this to ON), so a
    // wrong-device mistake stays recoverable. Reading is the safe direction.
    if let Some(dest) = backup_to {
        let _ = tx.send(FlashEvent::Phase("Backing up current device contents"));
        let src = std::fs::File::open(dev)
            .with_context(|| format!("opening {} for backup (run as root?)", dev.display()))?;
        let dst = std::fs::File::create(dest)
            .with_context(|| format!("creating backup image {}", dest.display()))?;
        let dst = copy_with_progress(src, dst, dev_size.unwrap_or(0), tx)
            .context("backup failed — aborting before any write")?;
        // The old flow used `dd conv=fsync`; keep the backup durable before the
        // destructive write begins.
        dst.sync_all().context("syncing the backup image")?;
    }

    // The overwrite: plain buffered copy, fsync'd before we even think of verifying.
    let _ = tx.send(FlashEvent::Phase("Writing image to device"));
    let image_size = std::fs::metadata(image)
        .with_context(|| format!("stat {}", image.display()))?
        .len();
    let src = std::fs::File::open(image).with_context(|| format!("opening {}", image.display()))?;
    let dst = std::fs::OpenOptions::new()
        .write(true)
        .open(dev)
        .with_context(|| {
            format!(
                "opening {} for writing (run as root, or with write access to the device?)",
                dev.display()
            )
        })?;
    let dst = copy_with_progress(src, dst, image_size, tx).context("writing the image")?;
    dst.sync_all()
        .context("syncing the device after the write")?;

    // Independent proof: the stick must now START with the image — never report
    // success on trust (a declined/failed write must not look like a flashed stick).
    let _ = tx.send(FlashEvent::Phase("Verifying device header"));
    if !same_prefix(image, dev, VERIFY_PREFIX_LEN).context("verifying the written device")? {
        bail!(
            "{} does not carry the image header — the write failed",
            dev.display()
        );
    }
    let mut summary = format!("{} is now a nixnas stick (header verified)", dev.display());

    // Grow-to-fill (Pathway B: a smaller/generic image on a bigger stick). Done AFTER the header
    // verify so that check stays a byte-faithful proof of the write; only the safe, secret-free
    // part happens here (extend the last GPT partition to the device end). The LUKS mapping needs
    // no resize — its dynamic segment spans the grown partition on the box's fresh unlock — and the
    // f2fs grows on first boot (boot.usb.growToFill). A grow failure never unmakes a verified
    // stick: it stays valid, just not filling the whole device.
    if grow {
        let _ = tx.send(FlashEvent::Phase(
            "Growing the last partition to fill the device",
        ));
        match grow_last_partition(dev) {
            Ok(()) => summary.push_str(
                " · partition grown to fill the device (the store resizes on first boot)",
            ),
            Err(e) => summary.push_str(&format!(
                " · WARNING: could not grow the partition ({e:#}) — the stick is valid but won't \
                 fill the whole device"
            )),
        }
    }
    Ok(summary)
}

/// Extend the LAST GPT partition (the LUKS store) to the true device end, preserving its identity
/// exactly (start, type GUID, unique GUID, name). Two deterministic `sgdisk` steps: relocate the
/// backup GPT header to the real device end (after a smaller image left it mid-disk), then
/// delete+recreate the last partition at its original start with the largest possible end.
fn grow_last_partition(dev: &Path) -> Result<()> {
    let n = last_partition_number(dev)?;
    let info = partition_info(dev, n)?;
    // 1. Move the backup GPT header (and the header's usable-area/alt-LBA) to the real device end,
    //    so step 2's "largest end" (0) computes against the whole device rather than the image.
    run_sgdisk(dev, &["--move-second-header".to_string()])?;
    // 2. Recreate #n at the same start, extended to the largest end, identity fully preserved.
    run_sgdisk(
        dev,
        &[
            format!("--delete={n}"),
            format!("--new={n}:{}:0", info.first_sector),
            format!("--typecode={n}:{}", info.type_guid),
            format!("--partition-guid={n}:{}", info.unique_guid),
            format!("--change-name={n}:{}", info.name),
        ],
    )
}

/// The details of one GPT partition we must preserve across a delete+recreate.
struct PartInfo {
    first_sector: u64,
    type_guid: String,
    unique_guid: String,
    name: String,
}

/// Run `sgdisk` with the given args against `dev`, surfacing a helpful error if sgdisk is missing.
fn run_sgdisk(dev: &Path, args: &[String]) -> Result<()> {
    let out = Command::new("sgdisk")
        .args(args)
        .arg(dev)
        .output()
        .context("running sgdisk (is gptfdisk installed?)")?;
    if !out.status.success() {
        bail!(
            "sgdisk {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// The highest partition number on `dev` — the LAST partition (the store), from `sgdisk -p`.
fn last_partition_number(dev: &Path) -> Result<u32> {
    let out = Command::new("sgdisk")
        .arg("-p")
        .arg(dev)
        .output()
        .context("running sgdisk -p (is gptfdisk installed?)")?;
    if !out.status.success() {
        bail!("sgdisk -p failed: {}", String::from_utf8_lossy(&out.stderr));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    // The partition table rows are those whose first token parses as a number; the largest wins.
    text.lines()
        .filter_map(|l| {
            l.split_whitespace()
                .next()
                .and_then(|t| t.parse::<u32>().ok())
        })
        .max()
        .context("sgdisk -p listed no partitions")
}

/// Parse `sgdisk --info=<n>` for the fields we preserve when recreating the partition.
fn partition_info(dev: &Path, n: u32) -> Result<PartInfo> {
    let out = Command::new("sgdisk")
        .arg(format!("--info={n}"))
        .arg(dev)
        .output()
        .context("running sgdisk --info (is gptfdisk installed?)")?;
    if !out.status.success() {
        bail!(
            "sgdisk --info={n} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let after = |label: &str| -> Option<String> {
        text.lines()
            .find_map(|l| l.trim().strip_prefix(label).map(|r| r.trim().to_string()))
    };
    // "Partition GUID code: <TYPE-GUID> (Linux LUKS)" — the type GUID is the first token.
    let type_guid = after("Partition GUID code:")
        .and_then(|s| s.split_whitespace().next().map(str::to_string))
        .context("sgdisk -i: no partition type GUID")?;
    let unique_guid =
        after("Partition unique GUID:").context("sgdisk -i: no partition unique GUID")?;
    // "First sector: <N> (at ...)" — the sector is the first token.
    let first_sector = after("First sector:")
        .and_then(|s| {
            s.split_whitespace()
                .next()
                .and_then(|t| t.parse::<u64>().ok())
        })
        .context("sgdisk -i: no first sector")?;
    // "Partition name: 'nixos'" — strip the surrounding single quotes.
    let name = after("Partition name:")
        .map(|s| s.trim_matches('\'').to_string())
        .unwrap_or_default();
    Ok(PartInfo {
        first_sector,
        type_guid,
        unique_guid,
        name,
    })
}

/// Read `src` to EOF into `dst`, reporting a byte counter against `total` (0 =
/// unknown, the gauge shows bytes only). Returns `dst` so the caller can fsync it.
fn copy_with_progress(
    mut src: std::fs::File,
    mut dst: std::fs::File,
    total: u64,
    tx: &Sender<FlashEvent>,
) -> Result<std::fs::File> {
    let mut buf = vec![0u8; CHUNK];
    let mut done: u64 = 0;
    loop {
        let n = src.read(&mut buf).context("reading source")?;
        if n == 0 {
            break;
        }
        dst.write_all(&buf[..n]).context("writing destination")?;
        done += n as u64;
        let _ = tx.send(FlashEvent::Progress { done, total });
    }
    Ok(dst)
}

/// Compare the first `len` bytes of two files. Used to prove the device actually
/// carries the image after the write.
fn same_prefix(a: &Path, b: &Path, len: usize) -> Result<bool> {
    let read_prefix = |p: &Path| -> Result<Vec<u8>> {
        let mut f = std::fs::File::open(p).with_context(|| format!("opening {}", p.display()))?;
        let mut buf = vec![0u8; len];
        let mut got = 0;
        while got < len {
            let n = f
                .read(&mut buf[got..])
                .with_context(|| format!("reading {}", p.display()))?;
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

/// Default backup destination, next to the config (same as the old TUI).
pub fn backup_path(config_path: &Path) -> PathBuf {
    config_dir(config_path).join("nixnas-backup.img")
}
