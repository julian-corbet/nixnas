//! nixnas — a full-screen guided TUI to configure, build, and flash a nixnas USB stick.
//!
//! Deliberately narrow scope: it does NOT do updates. A running nixnas updates itself
//! the Nix way (system.autoUpgrade builds a new generation; the bootloader keeps the
//! previous ones for rollback). This tool only PROVISIONS a fresh stick: edit the TUI
//! config -> build the personalised image LOCALLY -> optionally back the current
//! stick up -> overwrite it. The MACHINE's configuration is Nix, in the operator's
//! flake — the TUI config only says where that flake is and how to build/flash it.
//!
//! This file owns the terminal lifecycle and the screen state machine; the screens
//! live in `ui/`, the mechanics (config model, build pipeline, flash) in their own
//! modules — the UI is an interaction layer over those logic cores, never the other
//! way around.

mod build;
mod config;
mod flash;
mod logging;
mod ui;
mod verify;

use anyhow::{bail, Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// Which screen the state machine is on. Each screen's mutable state lives in its
/// own struct on [`App`] so a running operation survives redraws untouched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Home,
    Configure,
    Build,
    Flash,
    /// Both HOME verify entries (image / install) — the mode lives on the state.
    Verify,
}

pub struct App {
    pub config_path: PathBuf,
    pub cfg: config::Config,
    pub screen: Screen,
    pub home: ui::home::HomeState,
    /// Present only while the CONFIGURE screen is open (fresh copy of the config).
    pub configure: Option<ui::configure::ConfigureState>,
    /// Present from entering BUILD until it is backed out of after completion.
    pub build: Option<ui::build::BuildScreen>,
    /// Present from entering FLASH until it is backed out of after completion.
    pub flash: Option<ui::flash::FlashScreen>,
    /// Present from entering VERIFY until it is backed out of after completion.
    pub verify: Option<ui::verify::VerifyScreen>,
    /// A yazi path-pick asked for by the CONFIGURE screen. Screens cannot run it
    /// themselves — suspending the terminal is the main loop's job (it owns the
    /// terminal handle), so they RECORD the request and the loop services it.
    pub yazi_pick: Option<ui::configure::YaziRequest>,
    /// Session log tee: inert until the first action opens a file (see
    /// logging.rs); the exit prompt on HOME decides clean/keep at quit time.
    pub log: logging::SessionLog,
    pub quit: bool,
}

impl App {
    fn new(config_path: PathBuf, cfg: config::Config) -> Self {
        App {
            config_path,
            cfg,
            screen: Screen::Home,
            home: ui::home::HomeState::default(),
            configure: None,
            build: None,
            flash: None,
            verify: None,
            yazi_pick: None,
            log: logging::SessionLog::new(),
            quit: false,
        }
    }

    /// True while a worker thread owns a build, flash or verify. The screens
    /// refuse Esc mid-run (backing out of a half-written stick helps nobody);
    /// Ctrl+C stays available as the emergency exit.
    pub fn op_running(&self) -> bool {
        self.build.as_ref().is_some_and(|b| b.is_running())
            || self.flash.as_ref().is_some_and(|f| f.is_running())
            || self.verify.as_ref().is_some_and(|v| v.is_running())
    }
}

fn main() -> Result<()> {
    let config_path = PathBuf::from(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "nixnas.config".to_string()),
    );
    let cfg = config::Config::load(&config_path)?;

    // Graceful "not a terminal": bail with a plain error instead of wedging a pipe
    // with raw-mode escape sequences.
    if !std::io::stdout().is_terminal() || !std::io::stdin().is_terminal() {
        bail!("nixnas is a full-screen TUI — run it in an interactive terminal");
    }

    // The panic hook must restore the terminal BEFORE the default hook prints, or
    // the message vanishes with the alternate screen and the shell stays in raw mode.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_terminal();
        default_hook(info);
    }));

    enable_raw_mode().context("enabling raw mode")?;
    crossterm::execute!(std::io::stdout(), EnterAlternateScreen)
        .context("entering the alternate screen")?;
    let mut terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))
        .context("initialising the terminal")?;

    let result = run(&mut terminal, App::new(config_path, cfg));
    restore_terminal();
    result
}

/// Idempotent, error-swallowing teardown — used by the normal exit path AND the
/// panic hook (where there is nothing sensible to do with a failure anyway).
fn restore_terminal() {
    let _ = disable_raw_mode();
    let _ = crossterm::execute!(
        std::io::stdout(),
        LeaveAlternateScreen,
        crossterm::cursor::Show
    );
}

fn run(terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>, mut app: App) -> Result<()> {
    while !app.quit {
        // Pull worker events first so every frame reflects the newest progress.
        // This drain is also the ONE tee point into the session log — the
        // workers stay terminal- and file-agnostic (see logging.rs).
        if let Some(b) = app.build.as_mut() {
            b.drain_events(&mut app.log);
        }
        if let Some(fl) = app.flash.as_mut() {
            fl.drain_events(&mut app.log);
        }
        if let Some(v) = app.verify.as_mut() {
            v.drain_events(&mut app.log);
        }
        terminal.draw(|f| ui::draw(f, &mut app))?;
        // The poll timeout doubles as the redraw tick while workers stream events.
        if event::poll(Duration::from_millis(100)).context("polling terminal events")? {
            if let Event::Key(key) = event::read().context("reading terminal events")? {
                // Ignore Release/Repeat (kitty-protocol terminals emit them too).
                if key.kind == KeyEventKind::Press {
                    on_key(&mut app, key);
                }
            }
        }
        // Service a recorded yazi request AFTER key handling: only here does the
        // terminal handle live, and the picker needs the real terminal.
        if let Some(req) = app.yazi_pick.take() {
            if let Some(path) = run_yazi_picker(terminal, &req.start) {
                ui::configure::apply_picked(&mut app, req.field, path);
            }
        }
    }
    Ok(())
}

/// Run yazi as the premium path picker: suspend the ratatui world (leave the
/// alternate screen, cook the terminal), hand the real terminal to
/// `yazi --chooser-file=<RAM tmpfile>`, then read the pick back, shred the
/// tmpfile and resurrect the TUI with a forced full repaint. Every failure path
/// (yazi dying, killed, cancelled inside) restores the terminal and returns
/// None — the field keeps its old value.
fn run_yazi_picker(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    start: &Path,
) -> Option<PathBuf> {
    // Unique per invocation: the pid alone would collide on the second pick.
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let chooser = build::secure_tmp().join(format!(
        "nixnas-yazi-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    // Suspend: the same idempotent teardown the exit path uses. yazi manages its
    // own raw mode / alternate screen from the sane state this leaves behind.
    restore_terminal();
    let status = std::process::Command::new("yazi")
        .arg(start)
        .arg(format!("--chooser-file={}", chooser.display()))
        .status();
    // First line of the chooser file is the pick; an empty or absent file means
    // the operator quit yazi without choosing.
    let picked = match status {
        Ok(s) if s.success() => std::fs::read_to_string(&chooser).ok().and_then(|text| {
            text.lines()
                .next()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(PathBuf::from)
        }),
        // Spawn failure (yazi vanished mid-session) or a killed/failing yazi.
        _ => None,
    };
    // The pick is not a secret, but the file sits in shared tmp — clean it up
    // with the same shred guard the build secrets use.
    drop(build::ShredOnDrop(chooser));
    // Resurrect the TUI (mirror of the startup sequence); the explicit clear
    // forces the next draw to repaint every cell yazi may have touched.
    let _ = enable_raw_mode();
    let _ = crossterm::execute!(std::io::stdout(), EnterAlternateScreen);
    let _ = terminal.clear();
    picked
}

fn on_key(app: &mut App, key: KeyEvent) {
    // Global emergency exit. Esc is refused during a running build/flash, so this
    // must always work — the process dies, children are NOT reaped (documented).
    // It also bypasses HOME's session-log exit prompt: emergency exit stays
    // instant, and any log files simply remain on disk for inspection.
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
        app.quit = true;
        return;
    }
    match app.screen {
        Screen::Home => ui::home::on_key(app, key),
        Screen::Configure => ui::configure::on_key(app, key),
        Screen::Build => ui::build::on_key(app, key),
        Screen::Flash => ui::flash::on_key(app, key),
        Screen::Verify => ui::verify::on_key(app, key),
    }
}
