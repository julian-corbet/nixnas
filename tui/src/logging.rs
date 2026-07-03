//! Persistent session logging — a plain-text tee of what the action screens
//! already show.
//!
//! One [`SessionLog`] lives on the [`crate::App`] for the whole run. It stays
//! completely inert while the operator merely browses; the FIRST loggable
//! action (build / flash / verify) lazily creates
//! `$XDG_STATE_HOME/nixnas/logs/<action>-<YYYYMMDD-HHMMSS>.log` (falling back
//! to `~/.local/state`, directory 0700) and every action run gets its own file.
//!
//! Each file receives EXACTLY what the UI already displays — the log/findings
//! pane lines, the step transitions, the flash phases and the final Done
//! verdict — teed at the single point where main.rs drains the worker events;
//! the workers themselves stay terminal- and file-agnostic. SECRETS: the LUKS
//! passphrase and the sops plaintext never enter the event streams (build.rs
//! writes them to RAM-backed files / captures them without ever logging), so
//! by construction they can never reach a log file. Keep it that way: only
//! ever tee what the panes already show.
//!
//! On quit the HOME screen asks what to do with the files written THIS run:
//! clean (the default — tidy by default) or keep (for inspecting a failed
//! run). Keeping prunes the directory to the newest [`RETAIN`] files.
//!
//! Everything here is best-effort: a log that cannot be created or written is
//! silently dropped — logging must never break the TUI or an action.

use crate::build::StepState;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// How many log files survive a [K]eep — the newest N, older pruned silently.
pub const RETAIN: usize = 20;

pub struct SessionLog {
    /// Resolved logs directory; None ⇒ no usable state home, logging disabled.
    dir: Option<PathBuf>,
    /// Every file written THIS session — the exit prompt's scope. Clean removes
    /// exactly these; files kept by earlier runs are only touched by retention.
    files: Vec<PathBuf>,
    /// Open buffered writer for the currently running action, if any.
    writer: Option<BufWriter<File>>,
    /// Lines written since the last flush — [`Self::flush`] is a no-op without.
    dirty: bool,
}

impl SessionLog {
    /// Cheap: resolves the directory PATH only. No filesystem I/O happens
    /// until [`Self::begin`] — mere browsing never creates anything.
    pub fn new() -> Self {
        SessionLog {
            dir: logs_dir(),
            files: Vec::new(),
            writer: None,
            dirty: false,
        }
    }

    /// Open the log file for a starting action ("build", "flash",
    /// "verify-image", "verify-install"). Returns the created path so the
    /// screen can display it. Any failure disables logging for this run of
    /// the action — never the action itself.
    pub fn begin(&mut self, action: &str) -> Option<PathBuf> {
        // A lost Done (worker died without its terminal event) must not leak
        // an open writer into the next action's lines.
        self.finish();
        let dir = self.dir.clone()?;
        // 0700: the logs hold no secrets (see the module docs), but build logs
        // still describe this machine — keep them operator-only like ~/.ssh.
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .ok()?;
        let stamp = timestamp();
        // Same action twice within one second (a fast failure, retried) —
        // disambiguate with a bounded suffix instead of clobbering.
        for n in 0..100 {
            let name = if n == 0 {
                format!("{action}-{stamp}.log")
            } else {
                format!("{action}-{stamp}.{n}.log")
            };
            let path = dir.join(name);
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)
            {
                Ok(f) => {
                    self.writer = Some(BufWriter::new(f));
                    self.files.push(path.clone());
                    self.write_line(&format!("[start] {action} — {stamp}"));
                    return Some(path);
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => return None,
            }
        }
        None
    }

    /// One pane line, verbatim (BUILD log lines, VERIFY finding lines).
    pub fn line(&mut self, s: &str) {
        self.write_line(s);
    }

    /// A step-checklist transition, e.g. `[step] disko builder VM: Running`.
    pub fn step(&mut self, name: &str, state: StepState) {
        let state = match state {
            StepState::Pending => "Pending",
            StepState::Running => "Running",
            StepState::Ok => "Ok",
            StepState::Skipped => "Skipped",
            StepState::Fail => "Fail",
        };
        self.write_line(&format!("[step] {name}: {state}"));
    }

    /// A flash/hashing phase beginning (the gauge titles).
    pub fn phase(&mut self, title: &str) {
        self.write_line(&format!("[phase] {title}"));
    }

    /// The terminal event: the same message the done-panel shows. Flushes and
    /// closes the file — the log is complete the moment the UI says Done.
    pub fn done(&mut self, ok: bool, msg: &str) {
        self.write_line(&format!("[done] {}: {msg}", if ok { "OK" } else { "FAIL" }));
        self.finish();
    }

    /// True once any action wrote a log this session (the exit-prompt gate).
    pub fn has_files(&self) -> bool {
        !self.files.is_empty()
    }

    pub fn count(&self) -> usize {
        self.files.len()
    }

    pub fn dir(&self) -> Option<&Path> {
        self.dir.as_deref()
    }

    /// Exit choice CLEAN (the default): delete every file THIS session wrote.
    /// Files kept from earlier sessions are deliberately untouched.
    pub fn clean(&mut self) {
        self.finish();
        for f in self.files.drain(..) {
            let _ = std::fs::remove_file(f);
        }
    }

    /// Exit choice KEEP: retain this session's files, then prune the whole
    /// directory to the newest [`RETAIN`] logs (by mtime — the filename stamps
    /// only sort within one action prefix). The silent removals still leave a
    /// trace: the count is appended to this session's newest file.
    pub fn keep_and_prune(&mut self) {
        self.finish();
        let Some(dir) = &self.dir else { return };
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        let mut logs: Vec<(std::time::SystemTime, PathBuf)> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "log"))
            .filter_map(|p| Some((std::fs::metadata(&p).ok()?.modified().ok()?, p)))
            .collect();
        if logs.len() <= RETAIN {
            return;
        }
        logs.sort_by_key(|(mtime, _)| *mtime); // oldest first
        let cut = logs.len() - RETAIN;
        let pruned = logs[..cut]
            .iter()
            .filter(|(_, p)| std::fs::remove_file(p).is_ok())
            .count();
        if pruned > 0 {
            if let Some(last) = self.files.last() {
                if let Ok(mut f) = OpenOptions::new().append(true).open(last) {
                    let _ = writeln!(
                        f,
                        "[retention] pruned {pruned} older log file(s) — newest {RETAIN} kept"
                    );
                }
            }
        }
    }

    fn write_line(&mut self, s: &str) {
        if let Some(w) = &mut self.writer {
            if writeln!(w, "{s}").is_err() {
                // Disk gone mid-run: stop logging, never break the TUI.
                self.writer = None;
            } else {
                self.dirty = true;
            }
        }
    }

    /// Push buffered lines to disk. Called once per event-drain cycle (see
    /// main.rs), so the file the footer advertises can be `tail -f`ed LIVE
    /// during a long build — and a Ctrl+C autopsy sees the latest lines
    /// instead of a file minutes behind the pane.
    pub fn flush(&mut self) {
        if self.dirty {
            if let Some(w) = &mut self.writer {
                let _ = w.flush();
            }
            self.dirty = false;
        }
    }

    /// Flush and close the current file, if one is open. Idempotent.
    fn finish(&mut self) {
        if let Some(mut w) = self.writer.take() {
            let _ = w.flush();
        }
    }
}

impl Default for SessionLog {
    fn default() -> Self {
        Self::new()
    }
}

/// `$XDG_STATE_HOME/nixnas/logs`, defaulting to `~/.local/state/nixnas/logs`.
/// The XDG spec says a relative XDG_STATE_HOME must be ignored.
fn logs_dir() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(state.join("nixnas").join("logs"))
}

/// `YYYYMMDD-HHMMSS` in UTC, computed by hand (civil-from-days, Howard
/// Hinnant's algorithm) — one filename stamp does not warrant a chrono dep.
fn timestamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (h, m, s) = (secs / 3600 % 24, secs / 60 % 60, secs % 60);
    let z = secs.div_euclid(86_400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(month <= 2);
    format!("{y:04}{month:02}{d:02}-{h:02}{m:02}{s:02}")
}
