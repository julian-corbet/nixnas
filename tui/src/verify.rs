//! VERIFY — read-only structural checks of a built `.raw` image or a flashed
//! device: is this actually a bootable nixnas stick?
//!
//! Pure Rust, no root needed for the image (a device needs read access to the
//! block node — that is a UNIX permission, not a tool limitation):
//!   - the GPT is parsed with the `gpt` crate (readonly config: one valid header
//!     suffices, so a flashed device whose backup header sits at the IMAGE end
//!     rather than the device end still parses),
//!   - the ESP is mounted in-process with `fatfs` through a read-only window
//!     over the partition's byte range (systemd-boot + the UKI inventory),
//!   - the LUKS2 header is a raw 8-byte read of the store partition,
//!   - the digest / flash-fidelity checks stream the bytes through SHA-256.
//!
//! NOTHING is ever written: every handle opens read-only and the FAT window
//! fails closed on any write attempt.
//!
//! The checks run on a worker thread and report through [`VerifyEvent`]s so the
//! full-screen UI can show a live checklist, finding lines and a progress gauge
//! without the worker ever touching the terminal (same pattern as build/flash).

use crate::build::StepState;
use crate::sudo::{DevReader, Elevation};
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;

/// The checklist as the UI presents it. Indices are the protocol between
/// `run_verify` and the VERIFY screen — keep them in sync (same rule as
/// build.rs). The two modes differ only in the final, whole-target item.
pub const STEP_NAMES_IMAGE: [&str; 5] = [
    "GPT partition table (ESP + store)",
    "systemd-boot on the ESP",
    "UKIs in EFI/Linux",
    "LUKS2 header on the store partition",
    "SHA-256 digest of the whole image",
];

pub const STEP_NAMES_INSTALL: [&str; 5] = [
    "GPT partition table (ESP + store)",
    "systemd-boot on the ESP",
    "UKIs in EFI/Linux",
    "LUKS2 header on the store partition",
    "Flash fidelity vs built image",
];

/// Hash/compare chunk size; also the progress-report granularity.
const CHUNK: usize = 64 * 1024 * 1024;

/// Worker → UI protocol for a running verification.
pub enum VerifyEvent {
    Step(usize, StepState),
    /// A finding under the running step (partition rows, UKI names, digests).
    Detail(String),
    /// A hashing pass begins; carries the gauge title and resets the gauge.
    Phase(&'static str),
    Progress {
        done: u64,
        total: u64,
    },
    /// Terminal event: the PASS summary, or the rendered issue list / error.
    Done(Result<String, String>),
}

/// Spawn the image verification on a worker thread. The built `.raw` is a user file, so this
/// never needs elevation ([`Elevation::Root`] = direct reads).
pub fn spawn_verify_image(image: PathBuf) -> Receiver<VerifyEvent> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = run_verify(&image, false, None, None, &Elevation::Root, &tx);
        // Render the anyhow chain here — the UI side only displays strings.
        let _ = tx.send(VerifyEvent::Done(result.map_err(|e| format!("{e:#}"))));
    });
    rx
}

/// Spawn the device verification. `image` (when built) is the flash-fidelity
/// reference; `skip` is the UI's live "waive the fidelity compare" flag ('s') —
/// the worker polls it between chunks, never blocking on the UI. `elev` elevates the
/// (read-only) device access via sudo when the tool is not root.
pub fn spawn_verify_install(
    dev: PathBuf,
    image: Option<PathBuf>,
    skip: Arc<AtomicBool>,
    elev: Elevation,
) -> Receiver<VerifyEvent> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = run_verify(&dev, true, image.as_deref(), Some(&skip), &elev, &tx);
        let _ = tx.send(VerifyEvent::Done(result.map_err(|e| format!("{e:#}"))));
    });
    rx
}

/// Run every check against `target`, collecting issues instead of stopping at
/// the first one (each checklist item is independent evidence). Only an
/// unopenable target aborts. Returns the PASS summary; issues become the error.
fn run_verify(
    target: &Path,
    is_device: bool,
    fidelity_image: Option<&Path>,
    skip: Option<&AtomicBool>,
    elev: &Elevation,
    tx: &Sender<VerifyEvent>,
) -> Result<String> {
    let step = |i: usize, s: StepState| {
        let _ = tx.send(VerifyEvent::Step(i, s));
    };
    let detail = |s: String| {
        let _ = tx.send(VerifyEvent::Detail(s));
    };
    let mut issues: Vec<String> = Vec::new();

    // One read-only handle up front (a plain File for the image; a sudo-elevated, seekable
    // reader for a device when we are not root). A missing device permission surfaces here with
    // an actionable message instead of a bare errno.
    let mut file = elev
        .open_reader(target)
        .with_context(|| format!("opening {}", target.display()))?;
    // Block devices stat as 0 bytes — measure by seeking to the end instead.
    let target_len = file
        .seek(SeekFrom::End(0))
        .with_context(|| format!("sizing {}", target.display()))?;

    // 1. GPT: expect exactly two partitions — the ESP (by type GUID) + the LUKS
    //    store. Their byte ranges feed every later step.
    step(0, StepState::Running);
    let lb = gpt::disk::DEFAULT_SECTOR_SIZE; // the image is built with 512-byte sectors
    let mut esp: Option<(u64, u64)> = None;
    let mut store: Option<(u64, u64)> = None;
    match gpt::GptConfig::new()
        .writable(false)
        .logical_block_size(lb)
        .open_from_device(file.try_clone().context("cloning the target handle")?)
    {
        Ok(disk) => {
            let used: Vec<_> = disk
                .partitions()
                .iter()
                .filter(|(_, p)| p.is_used())
                .collect();
            for (id, p) in &used {
                let (start, len) = (p.bytes_start(lb)?, p.bytes_len(lb)?);
                let is_esp = p.part_type_guid == gpt::partition_types::EFI;
                let type_txt = if is_esp {
                    "EFI System".to_string()
                } else {
                    p.part_type_guid.guid.to_string()
                };
                let name = format!("\"{}\"", p.name);
                detail(format!(
                    "p{id}  {name:<12} {:>10}  type {type_txt}",
                    crate::flash::human_size(len)
                ));
                // First of each kind wins; extras are caught by the count check.
                if is_esp && esp.is_none() {
                    esp = Some((start, len));
                } else if !is_esp && store.is_none() {
                    store = Some((start, len));
                }
            }
            let mut ok = true;
            if used.len() != 2 {
                issues.push(format!(
                    "expected 2 partitions (ESP + store), found {}",
                    used.len()
                ));
                ok = false;
            }
            if esp.is_none() {
                issues.push("no EFI System partition".into());
                ok = false;
            }
            if store.is_none() {
                issues.push("no store (non-ESP) partition".into());
                ok = false;
            }
            step(0, if ok { StepState::Ok } else { StepState::Fail });
        }
        Err(e) => {
            issues.push(format!("GPT unreadable: {e}"));
            detail(format!("✗ GPT: {e}"));
            step(0, StepState::Fail);
        }
    }

    // 2. + 3. Boot chain: one in-process FAT mount of the ESP window serves both
    //    the systemd-boot check and the UKI inventory.
    if let Some((start, len)) = esp {
        step(1, StepState::Running);
        let window = SliceCursor::new(
            file.try_clone().context("cloning the target handle")?,
            start,
            len,
        );
        match fatfs::FileSystem::new(window, fatfs::FsOptions::new()) {
            Ok(fs) => {
                let root = fs.root_dir();
                // systemd-boot: the removable-media path and/or the vendor dir —
                // a systemd-boot install writes both, either one is proof.
                let bootx64 = fat_file_len(&root, "EFI/BOOT", "BOOTX64.EFI");
                let systemd = root.open_dir("EFI/systemd").is_ok();
                detail(match bootx64 {
                    Some(n) => format!("EFI/BOOT/BOOTX64.EFI  {}", crate::flash::human_size(n)),
                    None => "EFI/BOOT/BOOTX64.EFI  missing".to_string(),
                });
                detail(format!(
                    "EFI/systemd/          {}",
                    if systemd { "present" } else { "missing" }
                ));
                if bootx64.is_some() || systemd {
                    step(1, StepState::Ok);
                } else {
                    issues.push("no systemd-boot on the ESP".into());
                    step(1, StepState::Fail);
                }

                step(2, StepState::Running);
                match root.open_dir("EFI/Linux") {
                    Ok(dir) => {
                        let mut ukis: Vec<(String, u64)> = dir
                            .iter()
                            .filter_map(|e| e.ok())
                            .filter(|e| {
                                !e.is_dir() && e.file_name().to_ascii_lowercase().ends_with(".efi")
                            })
                            .map(|e| (e.file_name(), e.len()))
                            .collect();
                        ukis.sort();
                        for (name, size) in &ukis {
                            detail(format!(
                                "EFI/Linux/{name}  {}",
                                crate::flash::human_size(*size)
                            ));
                        }
                        if ukis.is_empty() {
                            issues.push("no UKIs (*.efi) under EFI/Linux".into());
                            step(2, StepState::Fail);
                        } else {
                            step(2, StepState::Ok);
                        }
                    }
                    Err(_) => {
                        issues.push("EFI/Linux does not exist on the ESP".into());
                        step(2, StepState::Fail);
                    }
                }
            }
            Err(e) => {
                issues.push(format!("ESP not mountable as FAT: {e}"));
                step(1, StepState::Fail);
                step(2, StepState::Skipped);
            }
        }
    } else {
        // Without a located ESP these checks have nothing to look at; the GPT
        // step already recorded the underlying issue.
        step(1, StepState::Skipped);
        step(2, StepState::Skipped);
    }

    // 4. LUKS2: the on-disk header starts with magic "LUKS\xba\xbe" at offset 0
    //    and the version as a BIG-endian u16 at offset 6 — both fields of the
    //    primary binary header (the secondary lives deeper and carries a
    //    different magic; the primary is the one the kernel requires).
    if let Some((start, _)) = store {
        step(3, StepState::Running);
        let mut hdr = [0u8; 8];
        file.seek(SeekFrom::Start(start))
            .context("seeking to the store partition")?;
        file.read_exact(&mut hdr)
            .context("reading the LUKS header")?;
        let magic_ok = hdr[..6] == *b"LUKS\xba\xbe";
        let version = u16::from_be_bytes([hdr[6], hdr[7]]);
        detail(format!(
            "magic    {}",
            if magic_ok {
                "LUKS\\xba\\xbe ✓"
            } else {
                "not LUKS ✗"
            }
        ));
        detail(format!(
            "version  {version}{}",
            if version == 2 {
                " ✓"
            } else {
                " (expected 2) ✗"
            }
        ));
        if magic_ok && version == 2 {
            step(3, StepState::Ok);
        } else {
            issues.push("store partition carries no LUKS2 header".into());
            step(3, StepState::Fail);
        }
    } else {
        step(3, StepState::Skipped);
    }

    // 5. Whole-target check: the image gets its full digest; a device gets the
    //    flash-fidelity compare against the built image (skippable — hashing a
    //    whole device's IMAGE-length prefix takes real time on USB).
    if !is_device {
        step(4, StepState::Running);
        let _ = tx.send(VerifyEvent::Phase("SHA-256 over the whole image"));
        // skip=None: the image digest always runs to the end (never skippable).
        let digest =
            sha256_range(&mut file, target_len, None, tx)?.expect("unskippable hash was skipped");
        detail(format!("sha256  {digest}"));
        step(4, StepState::Ok);
    } else if let Some(img) = fidelity_image {
        step(4, StepState::Running);
        let img_len = std::fs::metadata(img)
            .with_context(|| format!("stat {}", img.display()))?
            .len();
        if target_len < img_len {
            issues.push(format!(
                "device ({}) is SMALLER than the image ({}) — the flash cannot be complete",
                crate::flash::human_size(target_len),
                crate::flash::human_size(img_len)
            ));
        }
        // Only the common prefix can carry the image; trailing device bytes are
        // whatever the stick held before and prove nothing either way.
        let common = img_len.min(target_len);
        let _ = tx.send(VerifyEvent::Phase(
            "Flash fidelity — hashing device vs image",
        ));
        let mut img_file = File::open(img).with_context(|| format!("opening {}", img.display()))?;
        file.seek(SeekFrom::Start(0))
            .context("rewinding the device")?;
        let mut dev_hasher = Sha256::new();
        let mut img_hasher = Sha256::new();
        let mut buf_dev = vec![0u8; CHUNK];
        let mut buf_img = vec![0u8; CHUNK];
        let mut done: u64 = 0;
        let mut skipped = false;
        while done < common {
            // The UI's 's' key lands here — between chunks, so a skip is prompt
            // but never tears a read in half.
            if skip.is_some_and(|s| s.load(Ordering::Relaxed)) {
                skipped = true;
                break;
            }
            let want = CHUNK.min((common - done) as usize);
            file.read_exact(&mut buf_dev[..want])
                .context("reading the device")?;
            img_file
                .read_exact(&mut buf_img[..want])
                .context("reading the image")?;
            dev_hasher.update(&buf_dev[..want]);
            img_hasher.update(&buf_img[..want]);
            done += want as u64;
            let _ = tx.send(VerifyEvent::Progress {
                done,
                total: common,
            });
        }
        if skipped {
            detail("(fidelity compare skipped by operator)".into());
            step(4, StepState::Skipped);
        } else {
            let dev_digest = hex(&dev_hasher.finalize());
            let img_digest = hex(&img_hasher.finalize());
            detail(format!("device  sha256 {dev_digest}"));
            detail(format!("image   sha256 {img_digest}"));
            if dev_digest == img_digest && target_len >= img_len {
                step(4, StepState::Ok);
            } else {
                if dev_digest != img_digest {
                    issues.push("device bytes DIFFER from the built image".into());
                }
                step(4, StepState::Fail);
            }
        }
    } else {
        detail("(no built image — nothing to compare against)".into());
        step(4, StepState::Skipped);
    }

    if issues.is_empty() {
        Ok(format!(
            "PASS — {} carries the expected nixnas layout",
            if is_device { "the device" } else { "the image" }
        ))
    } else {
        bail!("{}", issues.join(" · "))
    }
}

/// Read-only window over a byte range of a file, presented as a stream that
/// starts at 0 — fatfs mounts the ESP through this without ever seeing the rest
/// of the disk. Reads seek absolutely on the shared handle, so the underlying
/// file offset never matters. `Write` is demanded by fatfs's storage trait but
/// must never happen on a verify: it fails closed with `Unsupported`.
struct SliceCursor {
    file: DevReader,
    start: u64,
    len: u64,
    pos: u64,
}

impl SliceCursor {
    fn new(file: DevReader, start: u64, len: u64) -> Self {
        SliceCursor {
            file,
            start,
            len,
            pos: 0,
        }
    }
}

impl Read for SliceCursor {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let remaining = self.len.saturating_sub(self.pos);
        if remaining == 0 {
            return Ok(0);
        }
        let want = (buf.len() as u64).min(remaining) as usize;
        self.file.seek(SeekFrom::Start(self.start + self.pos))?;
        let n = self.file.read(&mut buf[..want])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for SliceCursor {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        // i128 arithmetic: an i64 offset from End/Current cannot overflow it.
        let target = match pos {
            SeekFrom::Start(o) => o as i128,
            SeekFrom::End(o) => self.len as i128 + o as i128,
            SeekFrom::Current(o) => self.pos as i128 + o as i128,
        };
        if target < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "seek before the start of the ESP window",
            ));
        }
        self.pos = target as u64;
        Ok(self.pos)
    }
}

impl Write for SliceCursor {
    fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "verification is read-only",
        ))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        // fatfs flushes on unmount even when nothing was written — a no-op is
        // the correct read-only answer (write() above guards the actual bytes).
        Ok(())
    }
}

/// Size of `name` inside `dir` on the FAT volume, or None when absent. FAT name
/// matching is case-insensitive, so compare accordingly.
fn fat_file_len<T: Read + Write + Seek>(
    root: &fatfs::Dir<'_, T>,
    dir: &str,
    name: &str,
) -> Option<u64> {
    root.open_dir(dir)
        .ok()?
        .iter()
        .filter_map(|e| e.ok())
        .find(|e| !e.is_dir() && e.file_name().eq_ignore_ascii_case(name))
        .map(|e| e.len())
}

/// Stream the first `len` bytes of `f` through SHA-256, reporting progress.
/// Polls `skip` between chunks; a skip request aborts the pass and returns None.
fn sha256_range(
    f: &mut DevReader,
    len: u64,
    skip: Option<&AtomicBool>,
    tx: &Sender<VerifyEvent>,
) -> Result<Option<String>> {
    f.seek(SeekFrom::Start(0))
        .context("rewinding for hashing")?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; CHUNK];
    let mut done: u64 = 0;
    while done < len {
        if skip.is_some_and(|s| s.load(Ordering::Relaxed)) {
            return Ok(None);
        }
        let want = CHUNK.min((len - done) as usize);
        f.read_exact(&mut buf[..want])
            .context("reading for hashing")?;
        hasher.update(&buf[..want]);
        done += want as u64;
        let _ = tx.send(VerifyEvent::Progress { done, total: len });
    }
    Ok(Some(hex(&hasher.finalize())))
}

/// Lowercase hex of a digest (sha2's output type has no hex formatter itself).
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
