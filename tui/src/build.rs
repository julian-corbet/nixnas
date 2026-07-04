//! Build the personalised nixnas image LOCALLY via Nix.
//!
//! The image is built on THIS machine by design: it embeds your config and (with
//! `sb_keys_sops`) your own Secure Boot keys, so it can be neither pre-built
//! generically nor built on the infrastructure it will host (chicken-and-egg).
//! There is no remote build path.
//!
//! Pipeline (all secrets stay out of the Nix store):
//!   1. `nix build .#imageScript` — a PURE eval; the flake needs no secrets.
//!   2. The LUKS store passphrase (collected by the UI) → a 0600 file in RAM-backed tmp.
//!   3. If configured, `sops --decrypt` the Secure Boot PKI tar → RAM-backed tmp.
//!   4. Run the disko image script with `--pre-format-files <passphrase>
//!      /tmp/nixnas-luks.key` (used at luksFormat) and `--post-format-files <pki dir>
//!      /nix/lanzaboote/pki` (lands on the encrypted store). The .raw is written into
//!      `.nixnas-image/` next to the config.
//!   5. Zero + remove the secret temp files, regardless of success or failure.
//!
//! The pipeline runs on a worker thread and reports through [`BuildEvent`]s so the
//! full-screen UI can show a live step checklist and stream the child-process logs
//! without the worker ever touching the terminal itself.

use crate::config::{config_dir, Config};
use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, Sender};

/// Smallest stick "Build & flash a stick" (Pathway A) will size an image to. Below this a
/// device can't hold the ESP + a bootable closure + headroom. Not a rounding floor (Pathway A
/// is byte-EXACT), just the too-small refusal gate.
pub const MIN_IMAGE_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// Size of the MINIMAL reusable image ("Build image", Pathway B): the smallest that comfortably
/// holds the ESP (≤2 GiB) + a lean appliance closure (~2 GiB compressed) across ~2 kept
/// generations. Built ONCE and reflashed to any stick — grow-to-fill (`boot.usb.growToFill`)
/// then expands the store to the real device. A documented safe constant rather than a closure
/// eval (the TUI can't cheaply read the host's closure/`espSizeMiB`).
pub const MINIMAL_IMAGE_GIB: u32 = 6;

/// How the build sizes the disko image. disko bakes `disk.imageSize` into `qemu-img create` and
/// has no runtime size flag, so a non-`Fixed` size is applied by re-evaluating the host
/// (`host_attr`) with `extendModules` overriding the matching `nixnas.boot.usb.*` option.
#[derive(Debug, Clone, Copy)]
pub enum SizeOverride {
    /// No sizing: the fixed `.#<image_attr>` flake output (used when `host_attr` is None).
    Fixed,
    /// Minimal reusable image — override `imageSizeGiB` (whole GiB). Pathway B "Build image".
    Gib(u32),
    /// Exact device fit — override `imageSize` (byte-precise). Pathway A "Build & flash a stick".
    Bytes(u64),
}

/// The target device's EXACT byte size: `blockdev --getsize64` (authoritative for block
/// devices), falling back to `lsblk -b` when blockdev is unavailable. Used to size a Pathway-A
/// image to the byte and to assert the built `.raw` matches the device exactly.
pub fn device_bytes(name: &str) -> Option<u64> {
    let dev = format!("/dev/{name}");
    let via_blockdev = Command::new("blockdev")
        .args(["--getsize64", &dev])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .parse::<u64>()
                .ok()
        });
    via_blockdev.or_else(|| {
        Command::new("lsblk")
            .args(["-b", "-dno", "SIZE", &dev])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .parse::<u64>()
                    .ok()
            })
    })
}

/// Refuse a target that is simply too small to hold a bootable nixnas (Pathway A gate).
pub fn check_target_bytes(dev_bytes: u64) -> Result<(), String> {
    if dev_bytes < MIN_IMAGE_BYTES {
        return Err(format!(
            "stick too small: needs ≥ {}, this device is only {}",
            crate::flash::human_size(MIN_IMAGE_BYTES),
            crate::flash::human_size(dev_bytes)
        ));
    }
    Ok(())
}

/// The step checklist as the UI presents it. Indices are the protocol between the
/// pipeline and the BUILD screen — keep them in sync with `run_pipeline`.
pub const STEP_NAMES: [&str; 5] = [
    "Evaluate image script (nix build)",
    "LUKS store passphrase → RAM file",
    "Secure Boot PKI (sops decrypt + inject)",
    "disko builder VM (write .raw)",
    ".raw image ready",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepState {
    Pending,
    Running,
    Ok,
    /// The step does not apply to this config (no `sb_keys_sops`).
    Skipped,
    Fail,
}

/// Worker → UI protocol for a running build.
pub enum BuildEvent {
    Step(usize, StepState),
    Log(String),
    /// Terminal event: the built `.raw` path, or the rendered error chain.
    Done(Result<PathBuf, String>),
}

/// RAII guard: overwrite IN PLACE with zeros (no truncate — truncating first would
/// free the original blocks unzeroed), fsync, then unlink. Best-effort, and the
/// files live under /dev/shm when available, so nothing hits a disk to begin with.
/// Crate-visible: main.rs shreds the yazi chooser file with the same guard.
pub(crate) struct ShredOnDrop(pub(crate) PathBuf);

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
pub(crate) fn secure_tmp() -> PathBuf {
    let shm = Path::new("/dev/shm");
    if shm.is_dir() {
        shm.to_path_buf()
    } else {
        std::env::temp_dir()
    }
}

/// Forward every line of `r` into the UI's log pane. `\r`-style progress redraws
/// arrive as long single lines — acceptable for a log, and nothing is lost.
fn stream_lines<R: Read + Send + 'static>(
    r: R,
    tx: Sender<BuildEvent>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        for line in BufReader::new(r).lines().map_while(Result::ok) {
            if tx.send(BuildEvent::Log(line)).is_err() {
                break; // UI gone — stop forwarding, let the child run to completion
            }
        }
    })
}

/// Run a child with stdout+stderr piped into the log pane (never inherited — the
/// alternate screen belongs to the UI). Returns the exit status.
fn run_streamed(
    mut cmd: Command,
    tx: &Sender<BuildEvent>,
    what: &str,
) -> Result<std::process::ExitStatus> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().with_context(|| format!("running {what}"))?;
    let mut readers = Vec::new();
    if let Some(out) = child.stdout.take() {
        readers.push(stream_lines(out, tx.clone()));
    }
    if let Some(err) = child.stderr.take() {
        readers.push(stream_lines(err, tx.clone()));
    }
    let status = child
        .wait()
        .with_context(|| format!("waiting for {what}"))?;
    for r in readers {
        let _ = r.join(); // drain the tail of the output before reporting the status
    }
    Ok(status)
}

/// Spawn the build pipeline on a worker thread. The passphrase is collected by the
/// UI (masked modal, entered twice) BEFORE spawning, so the worker never prompts.
pub fn spawn_build(
    config_path: PathBuf,
    cfg: Config,
    passphrase: String,
    size: SizeOverride,
) -> Receiver<BuildEvent> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = run_pipeline(&config_path, &cfg, passphrase, size, &tx);
        // Render the anyhow chain here — the UI side only displays strings.
        let _ = tx.send(BuildEvent::Done(result.map_err(|e| format!("{e:#}"))));
    });
    rx
}

/// Builds the image script from the operator's flake and runs it with the secrets
/// injected. Returns the path of the built `.raw`.
fn run_pipeline(
    config_path: &Path,
    cfg: &Config,
    passphrase: String,
    size: SizeOverride,
    tx: &Sender<BuildEvent>,
) -> Result<PathBuf> {
    let base = config_dir(config_path);
    let flake_dir = cfg.resolved_flake_dir(config_path);
    let script_link = base.join(".nixnas-imagescript");
    let out_dir = base.join(".nixnas-image");
    let step = |i: usize, s: StepState| {
        let _ = tx.send(BuildEvent::Step(i, s));
    };
    let log = |s: String| {
        let _ = tx.send(BuildEvent::Log(s));
    };

    // 1. Build the disko image script (pure eval — no secrets involved). Two shapes:
    //    * SIZED (host_attr set): disko bakes `disk.imageSize` into `qemu-img create` and has no
    //      runtime size flag, so re-evaluate the host with `extendModules` overriding the relevant
    //      `nixnas.boot.usb.*` size option. `lib.mkForce` so the override wins even when the host
    //      pins the size itself (e.g. the matrix `stick-*` examples). Needs `--impure` for the
    //      local `builtins.getFlake`.
    //    * FIXED (no host_attr, or SizeOverride::Fixed): the operator-chosen `.#<image_attr>`
    //      output (usb appliance by default, or a hot-mode RESCUE image — the hot MAIN is never
    //      flashed, HOT-MODE.md). Backward compatible.
    step(0, StepState::Running);
    let mut nix = Command::new("nix");
    // A sizing override only applies when we have a host attribute to extend; otherwise fall back
    // to the fixed output regardless of what was requested (the UI won't ask, but be safe).
    let override_expr = match (size, cfg.host_attr.as_deref()) {
        (SizeOverride::Gib(n), Some(host)) => Some((
            host.to_string(),
            format!("nixnas.boot.usb.imageSizeGiB = lib.mkForce {n};"),
            format!("minimal reusable image: {n} GiB"),
        )),
        (SizeOverride::Bytes(b), Some(host)) => Some((
            host.to_string(),
            format!("nixnas.boot.usb.imageSize = lib.mkForce \"{b}\";"),
            format!("exact-fit image: {b} bytes"),
        )),
        _ => None,
    };
    if let Some((host, assign, what)) = override_expr {
        // The override module is a FUNCTION so `lib` is in scope for mkForce.
        let expr = format!(
            "let f = builtins.getFlake (toString ./.); in \
             (f.nixosConfigurations.{host}.extendModules {{ modules = [ ({{ lib, ... }}: {{ {assign} }}) ]; }})\
             .config.system.build.diskoImagesScript"
        );
        log(format!(
            ">> building the {what} (host {host}, size-overridden via extendModules)"
        ));
        nix.args([
            "build",
            "--impure",
            "--print-build-logs",
            "--accept-flake-config",
            "--out-link",
        ])
        .arg(&script_link)
        .arg("--expr")
        .arg(&expr)
        .current_dir(&flake_dir);
    } else {
        let image_ref = format!(".#{}", cfg.image_attr);
        log(format!(">> building the stick image from {image_ref}"));
        nix.args([
            "build",
            "--print-build-logs",
            "--accept-flake-config",
            &image_ref,
            "--out-link",
        ])
        .arg(&script_link)
        .current_dir(&flake_dir);
    }
    let status = run_streamed(nix, tx, "`nix build` (is Nix installed locally?)")?;
    if !status.success() {
        step(0, StepState::Fail);
        bail!("the image build (nix build) failed");
    }
    step(0, StepState::Ok);

    // 2. Write the (already collected) LUKS passphrase to a 0600 RAM-backed file.
    step(1, StepState::Running);
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
    step(1, StepState::Ok);

    // 3. Optional: decrypt the Secure Boot PKI (sops tar) into a RAM tmp dir.
    //    sops output is the SECRET tar stream — captured, never sent to the log pane.
    let mut pki_dir: Option<PathBuf> = None;
    let mut _pki_guard: Option<ShredDirOnDrop> = None;
    if let Some(sops_file) = &cfg.sb_keys_sops {
        step(2, StepState::Running);
        let sops_path = {
            let p = Path::new(sops_file);
            if p.is_absolute() {
                p.to_path_buf()
            } else {
                base.join(p)
            }
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
            step(2, StepState::Fail);
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
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("running tar")?;
        tar.stdin
            .as_mut()
            .context("opening tar stdin")?
            .write_all(&decrypted.stdout)
            .context("streaming PKI tar to tar")?;
        if !tar.wait().context("waiting for tar")?.success() {
            step(2, StepState::Fail);
            bail!("extracting the Secure Boot PKI tar failed");
        }
        // The tar may carry the bundle bare (`keys/` at the top) or wrapped in a
        // single top-level directory (e.g. `pki/`). lanzaboote needs the sbctl
        // layout at the BUNDLE ROOT — descend into a lone wrapper directory, or
        // the keys would land at /nix/lanzaboote/pki/pki/... and the bootloader
        // install would fail deep inside the builder VM.
        let mut bundle = dir.clone();
        if !bundle.join("keys").is_dir() {
            let entries: Vec<PathBuf> = std::fs::read_dir(&bundle)
                .context("listing the extracted PKI tar")?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .collect();
            if let [only] = entries.as_slice() {
                if only.is_dir() && only.join("keys").is_dir() {
                    log(format!(
                        "(PKI tar wraps its bundle in {}/ — using that as the bundle root)",
                        only.file_name().unwrap_or_default().to_string_lossy()
                    ));
                    bundle = only.clone();
                }
            }
        }
        // Fail FAST on a malformed bundle: inside the builder VM this only
        // surfaces minutes later as a bootloader-install failure followed by a
        // kernel panic ("Attempted to kill init") and no exit code.
        for required in [
            "keys/PK/PK.pem",
            "keys/PK/PK.key",
            "keys/KEK/KEK.pem",
            "keys/KEK/KEK.key",
            "keys/db/db.pem",
            "keys/db/db.key",
        ] {
            if !bundle.join(required).is_file() {
                step(2, StepState::Fail);
                bail!(
                    "Secure Boot PKI bundle from {} is missing {required} — expected the \
                     sbctl layout (keys/{{PK,KEK,db}}/*.pem+*.key) at the tar root or \
                     inside one wrapper directory",
                    sops_path.display()
                );
            }
        }
        pki_dir = Some(bundle);
        step(2, StepState::Ok);
    } else {
        log(
            "(no sb_keys_sops configured — lanzaboote will autogenerate keys on first boot)".into(),
        );
        step(2, StepState::Skipped);
    }

    // 4. Run the image script; the .raw lands in out_dir (the script writes to CWD).
    step(3, StepState::Running);
    std::fs::create_dir_all(&out_dir).context("creating image output dir")?;
    let mut run =
        Command::new(std::fs::canonicalize(&script_link).context("resolving image script")?);
    run.current_dir(&out_dir);
    // The script's vm-run stage only adds `-smp` when a Nix build environment
    // says parallel building is on; run directly it would default to ONE vCPU
    // and the in-VM closure copy (`xargs -P $(nproc)`) crawls. Give the builder
    // VM the host's cores: stdenv's setup normalises an UNSET NIX_BUILD_CORES
    // to 1, but turns an explicit 0 into $(nproc).
    run.env("enableParallelBuilding", "1");
    run.env("NIX_BUILD_CORES", "0");
    if let Some(mem) = cfg.build_memory_mib {
        run.args(["--build-memory", &mem.to_string()]);
    }
    // The conventional in-VM path modules/boot/disk.nix reads at luksFormat time.
    run.arg("--pre-format-files")
        .arg(&key_path)
        .arg("/tmp/nixnas-luks.key");
    if let Some(pki) = &pki_dir {
        // Lands on the finished image's encrypted store; lanzaboote signs from day one.
        run.arg("--post-format-files")
            .arg(pki)
            .arg("/nix/lanzaboote/pki");
    }
    let status = run_streamed(run, tx, "the disko image script")?;
    if !status.success() {
        step(3, StepState::Fail);
        bail!("image build failed");
    }
    step(3, StepState::Ok);

    // 5. Find the built .raw (disko names it after the disk's imageName).
    step(4, StepState::Running);
    let raw = std::fs::read_dir(&out_dir)
        .with_context(|| format!("reading built image dir {}", out_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|x| x == "raw"))
        .inspect(|_| step(4, StepState::Ok))
        .context("no .raw file in the image output dir")
        .inspect_err(|_| step(4, StepState::Fail))?;
    log(format!(">> built image: {}", raw.display()));
    Ok(raw)
}
