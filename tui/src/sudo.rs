//! Privilege elevation for the device-touching steps.
//!
//! nixnas runs as the INVOKING USER — the build needs the user's identity (the sops age key, the
//! user's nix), so the tool must never be `sudo nixnas` nor wrapped. But the FLASH writes a raw
//! block device and VERIFY-INSTALL reads one, which need root. So we elevate ONLY those steps,
//! from inside the tool: prompt once for the sudo password, validate + cache the sudo timestamp,
//! then run each privileged op via `sudo`. When already root (euid 0) there is no prompt and every
//! command runs directly. When `sudo` is absent we say so plainly (device access then falls back
//! to whatever the invoking user's own permissions allow).
//!
//! The write command (`dd of=<device>`, whose stdin carries the IMAGE) can't also be fed the
//! password on stdin, so it uses `sudo -n` and leans on the just-validated timestamp (a flash is
//! fast). READ commands (device reads, sgdisk, blockdev) use `sudo -S` and are fed the cached
//! password on stdin — harmless to a command that ignores stdin, it refreshes the timestamp, and
//! it survives a long verify that would otherwise outlive the timestamp window.

use anyhow::{bail, Context, Result};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;

/// A password held only for the lifetime of a privileged action, then zeroized. Not perfect (a
/// `String` may have reallocated), but it overwrites the live buffer before free and never lands
/// in a log, an env var, or a command line.
pub struct Secret(String);

impl Secret {
    pub fn new(s: String) -> Self {
        Secret(s)
    }
    /// The password followed by a newline, as `sudo -S` expects it on stdin.
    fn line(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(self.0.len() + 1);
        v.extend_from_slice(self.0.as_bytes());
        v.push(b'\n');
        v
    }
    /// The raw secret bytes, NO trailing newline. For secrets that are NOT a sudo
    /// password — e.g. the LUKS store passphrase fed to `cryptsetup --key-file=-`,
    /// which reads stdin VERBATIM (a trailing newline would become part of the key
    /// and fail the unlock — verified against cryptsetup 2.8.6).
    pub fn bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        // Overwrite the heap bytes in place before the String frees them.
        unsafe {
            for b in self.0.as_bytes_mut() {
                *b = 0;
            }
        }
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<sudo password>")
    }
}

/// Shared so the several device handles a verify opens can all feed the same password without
/// copying it around; zeroized once, when the last handle drops.
type SharedSecret = Arc<Secret>;

/// How the privileged device ops for one action are run.
#[derive(Clone, Debug)]
pub enum Elevation {
    /// Already root — run device commands directly, no sudo.
    Root,
    /// Non-root — prefix with sudo; `secret` validated the timestamp and feeds read commands.
    Sudo(SharedSecret),
}

/// What has to happen before a privileged action can start.
pub enum Preflight {
    /// euid 0 — no prompt, elevate to [`Elevation::Root`].
    Root,
    /// Non-root with `sudo` on PATH — prompt for the password, then [`authenticate`].
    NeedsSudo,
    /// Non-root and `sudo` is not installed — no elevation is possible.
    NoSudo,
}

/// True when the effective uid is 0. Uses `id -u` (the effective uid) — no libc dependency.
pub fn is_root() -> bool {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim() == "0")
        .unwrap_or(false)
}

/// True when a `sudo` binary is on PATH (same executable-probe as the yazi check).
fn sudo_on_path() -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|dir| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::metadata(dir.join("sudo"))
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
    })
}

/// Decide what elevation the current process needs. Cheap — a subprocess + a PATH scan.
pub fn preflight() -> Preflight {
    if is_root() {
        Preflight::Root
    } else if sudo_on_path() {
        Preflight::NeedsSudo
    } else {
        Preflight::NoSudo
    }
}

/// The result of validating a typed sudo password.
pub enum AuthOutcome {
    /// Password accepted; the timestamp is cached — carry this [`Elevation`] into the worker.
    Ok(Elevation),
    /// Wrong password — re-prompt.
    Wrong,
    /// `sudo` vanished between preflight and here.
    Missing,
    /// sudo itself errored (not an auth failure) — surface the message.
    Error(String),
}

/// Validate + cache the sudo timestamp with `sudo -S -v -p ''`, feeding the password on stdin.
pub fn authenticate(password: String) -> AuthOutcome {
    let secret = Secret::new(password);
    let mut child = match Command::new("sudo")
        .args(["-S", "-v", "-p", ""])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return AuthOutcome::Missing,
        Err(e) => return AuthOutcome::Error(format!("running sudo: {e}")),
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&secret.line());
        // dropping stdin closes it, so sudo sees EOF after the password line
    }
    match child.wait_with_output() {
        Ok(o) if o.status.success() => AuthOutcome::Ok(Elevation::Sudo(Arc::new(secret))),
        // sudo -S prints "Sorry, try again." to stderr on a bad password; any non-zero exit here
        // is treated as an auth failure (re-prompt) rather than a hard error.
        Ok(_) => AuthOutcome::Wrong,
        Err(e) => AuthOutcome::Error(format!("waiting for sudo: {e}")),
    }
}

impl Elevation {
    /// Build a Command running `argv` with root privileges. `feed_password` = true adds `sudo -S`
    /// (the caller then writes [`Self::password_line`] to the child's stdin); false adds `sudo -n`
    /// (non-interactive, relies on the cached timestamp — for the write, whose stdin is data).
    fn command(&self, argv: &[&str], feed_password: bool) -> Command {
        match self {
            Elevation::Root => {
                let mut c = Command::new(argv[0]);
                c.args(&argv[1..]);
                c
            }
            Elevation::Sudo(_) => {
                let mut c = Command::new("sudo");
                if feed_password {
                    c.args(["-S", "-p", ""]);
                } else {
                    c.arg("-n");
                }
                c.args(argv);
                c
            }
        }
    }

    /// The password+newline to write to a `-S` command's stdin, or None when root.
    fn password_line(&self) -> Option<Vec<u8>> {
        match self {
            Elevation::Root => None,
            Elevation::Sudo(s) => Some(s.line()),
        }
    }

    /// Run a privileged command to completion, capturing its output. Feeds the cached password on
    /// stdin (`-S`) so an expired timestamp can't stall it. Use for commands that do NOT read data
    /// from stdin (sgdisk, blockdev, dd reads).
    pub fn run_captured(&self, argv: &[&str]) -> Result<std::process::Output> {
        let mut child = self
            .command(argv, true)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("running {}", argv.join(" ")))?;
        if let (Some(line), Some(mut stdin)) = (self.password_line(), child.stdin.take()) {
            let _ = stdin.write_all(&line);
        }
        child
            .wait_with_output()
            .with_context(|| format!("waiting for {}", argv.join(" ")))
    }

    /// Run a privileged command whose STDIN must carry DATA (not the sudo password) —
    /// e.g. `cryptsetup open --key-file=-` reading the LUKS passphrase. Like the dd
    /// write path it uses `sudo -n`, leaning on the timestamp the surrounding `-S`
    /// commands keep fresh; when root the command runs directly. `input` is written
    /// to the child's stdin, then stdin is closed (EOF).
    pub fn run_with_input(&self, argv: &[&str], input: &[u8]) -> Result<std::process::Output> {
        let mut child = self
            .command(argv, false)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("running {}", argv.join(" ")))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(input)
                .with_context(|| format!("feeding stdin of {}", argv.join(" ")))?;
            // dropping stdin closes it — the child sees EOF after the payload
        }
        child
            .wait_with_output()
            .with_context(|| format!("waiting for {}", argv.join(" ")))
    }

    /// Exact byte size of a block device — `blockdev --getsize64`, elevated when needed.
    pub fn device_size(&self, dev: &Path) -> Result<u64> {
        let dev = dev.to_string_lossy().into_owned();
        let out = self.run_captured(&["blockdev", "--getsize64", &dev])?;
        if !out.status.success() {
            bail!(
                "blockdev --getsize64 {dev} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .with_context(|| "parsing blockdev size")
    }

    /// A seekable, read-only handle onto `dev`, elevated when needed.
    pub fn open_reader(&self, dev: &Path) -> Result<DevReader> {
        match self {
            Elevation::Root => {
                let f = open_device_read(dev)?;
                Ok(DevReader::File(f))
            }
            Elevation::Sudo(secret) => {
                let len = self.device_size(dev)?;
                Ok(DevReader::Sudo(SudoReader::new(
                    dev.to_path_buf(),
                    len,
                    secret.clone(),
                )))
            }
        }
    }

    /// A writable sink onto `dev`, elevated when needed. The write copies image bytes into it; the
    /// sudo path pipes them through `dd of=<dev> conv=fsync` (data on the child's stdin, so it uses
    /// the cached timestamp via `-n`).
    pub fn open_writer(&self, dev: &Path) -> Result<DevWriter> {
        match self {
            Elevation::Root => {
                let f = std::fs::OpenOptions::new()
                    .write(true)
                    .open(dev)
                    .with_context(|| format!("opening {} for writing", dev.display()))?;
                Ok(DevWriter::File(f))
            }
            Elevation::Sudo(_) => {
                let dev = dev.to_string_lossy().into_owned();
                let mut child = self
                    .command(
                        &[
                            "dd",
                            &format!("of={dev}"),
                            "bs=4194304",
                            "conv=fsync",
                            "status=none",
                        ],
                        false,
                    )
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::piped())
                    .spawn()
                    .with_context(|| format!("spawning sudo dd of={dev}"))?;
                let stdin = child.stdin.take().context("opening dd stdin")?;
                Ok(DevWriter::Sudo { child, stdin })
            }
        }
    }
}

/// Open a device for reading, mapping EACCES to the same actionable message the verify screen used
/// to print (so an unelevated read still explains what to do).
fn open_device_read(dev: &Path) -> Result<std::fs::File> {
    match std::fs::File::open(dev) {
        Ok(f) => Ok(f),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => bail!(
            "no permission to read {} — run nixnas as a user that can sudo, add yourself to the \
             `disk` group, or run as root.",
            dev.display()
        ),
        Err(e) => Err(e).with_context(|| format!("opening {}", dev.display())),
    }
}

/// 1 MiB block for the small-read cache (fatfs does many tiny reads over the ESP).
const BLOCK: usize = 1024 * 1024;

/// A seekable read-only device handle: a plain `File` when root, or a `sudo dd`-backed reader
/// otherwise. Implements Read + Write(fail-closed) + Seek + Debug so it plugs into the `gpt` crate
/// and the verify code exactly where a `File` did.
#[derive(Debug)]
pub enum DevReader {
    File(std::fs::File),
    Sudo(SudoReader),
}

impl DevReader {
    /// An independent handle onto the same device (mirrors `File::try_clone`, used by the verify
    /// code to hand the GPT parser and the ESP window their own cursors).
    pub fn try_clone(&self) -> std::io::Result<DevReader> {
        match self {
            DevReader::File(f) => f.try_clone().map(DevReader::File),
            DevReader::Sudo(s) => Ok(DevReader::Sudo(s.fresh_clone())),
        }
    }
}

impl Read for DevReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            DevReader::File(f) => f.read(buf),
            DevReader::Sudo(s) => s.read(buf),
        }
    }
}

impl Seek for DevReader {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        match self {
            DevReader::File(f) => f.seek(pos),
            DevReader::Sudo(s) => s.seek(pos),
        }
    }
}

impl Write for DevReader {
    // Demanded by gpt's DiskDevice bound; a read handle must never write (fail closed).
    fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "device handle is read-only",
        ))
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A `sudo dd`-backed seekable reader. Large reads fetch their exact range in one `dd`; small reads
/// are served from a 1 MiB block cache so fatfs's many tiny reads don't spawn a process each.
pub struct SudoReader {
    dev: PathBuf,
    len: u64,
    pos: u64,
    secret: SharedSecret,
    cache: Vec<u8>,
    cache_start: u64,
}

impl std::fmt::Debug for SudoReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SudoReader")
            .field("dev", &self.dev)
            .field("len", &self.len)
            .field("pos", &self.pos)
            .finish()
    }
}

impl SudoReader {
    fn new(dev: PathBuf, len: u64, secret: SharedSecret) -> Self {
        SudoReader {
            dev,
            len,
            pos: 0,
            secret,
            cache: Vec::new(),
            cache_start: 0,
        }
    }

    fn fresh_clone(&self) -> Self {
        SudoReader {
            dev: self.dev.clone(),
            len: self.len,
            pos: self.pos,
            secret: self.secret.clone(),
            cache: Vec::new(),
            cache_start: 0,
        }
    }

    /// One `sudo dd` reading exactly `len` bytes at byte offset `off` (GNU `skip_bytes,count_bytes`
    /// let us pass byte offsets with a big block size). Returns however many bytes came back.
    fn dd_range(&self, off: u64, len: usize) -> std::io::Result<Vec<u8>> {
        let dev = self.dev.to_string_lossy().into_owned();
        let argv = [
            "dd",
            &format!("if={dev}"),
            "iflag=skip_bytes,count_bytes",
            "bs=1048576",
            &format!("skip={off}"),
            &format!("count={len}"),
            "status=none",
        ];
        let mut c = Command::new("sudo");
        c.args(["-S", "-p", ""])
            .args(argv)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = c.spawn()?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(&self.secret.line());
        }
        let out = child.wait_with_output()?;
        if !out.status.success() {
            return Err(std::io::Error::other(format!(
                "sudo dd read failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(out.stdout)
    }

    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.len {
            return Ok(0);
        }
        let want = buf.len().min((self.len - self.pos) as usize);
        if want == 0 {
            return Ok(0);
        }
        if want >= BLOCK {
            // Large (e.g. the 64 MiB hash chunks): fetch the exact range directly.
            let data = self.dd_range(self.pos, want)?;
            let n = data.len().min(want);
            buf[..n].copy_from_slice(&data[..n]);
            self.pos += n as u64;
            return Ok(n);
        }
        // Small: serve from the block cache, refilling on a miss with a BLOCK-aligned fetch.
        let in_cache =
            self.pos >= self.cache_start && self.pos < self.cache_start + self.cache.len() as u64;
        if !in_cache {
            let start = self.pos - (self.pos % BLOCK as u64);
            let span = (BLOCK as u64).min(self.len - start) as usize;
            self.cache = self.dd_range(start, span)?;
            self.cache_start = start;
        }
        let offset = (self.pos - self.cache_start) as usize;
        if offset >= self.cache.len() {
            return Ok(0);
        }
        let n = (self.cache.len() - offset).min(want);
        buf[..n].copy_from_slice(&self.cache[offset..offset + n]);
        self.pos += n as u64;
        Ok(n)
    }

    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let target = match pos {
            SeekFrom::Start(o) => o as i128,
            SeekFrom::End(o) => self.len as i128 + o as i128,
            SeekFrom::Current(o) => self.pos as i128 + o as i128,
        };
        if target < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "seek before start of device",
            ));
        }
        self.pos = target as u64;
        Ok(self.pos)
    }
}

/// A writable device sink: a plain `File` when root, or a `sudo dd of=<dev>` pipe otherwise.
pub enum DevWriter {
    File(std::fs::File),
    Sudo { child: Child, stdin: ChildStdin },
}

impl Write for DevWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            DevWriter::File(f) => f.write(buf),
            DevWriter::Sudo { stdin, .. } => stdin.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            DevWriter::File(f) => f.flush(),
            DevWriter::Sudo { stdin, .. } => stdin.flush(),
        }
    }
}

impl DevWriter {
    /// Durably finish the write: fsync the File, or close dd's stdin and reap it (dd `conv=fsync`
    /// already synced the device). Consumes the writer.
    pub fn finish(self) -> Result<()> {
        match self {
            DevWriter::File(f) => f.sync_all().context("syncing the device after the write"),
            DevWriter::Sudo { mut child, stdin } => {
                drop(stdin); // EOF to dd
                let status = child.wait().context("waiting for sudo dd")?;
                if !status.success() {
                    bail!("sudo dd (device write) failed — is the sudo timestamp still valid?");
                }
                Ok(())
            }
        }
    }
}
