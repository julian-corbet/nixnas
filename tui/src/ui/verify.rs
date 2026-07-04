//! VERIFY — live checklist beside a findings pane, fed by the worker in
//! verify.rs over an mpsc channel. One screen serves both HOME entries: `Image`
//! verifies the built `.raw` directly (same discovery as the HOME status);
//! `Install` starts on the FLASH screen's disk presentation and runs the same
//! read-only checks against the chosen device, plus the skippable
//! flash-fidelity compare. Nothing here can write — there is no arming gate.

use crate::build::StepState;
use crate::flash::{self, Disk};
use crate::sudo::{self, AuthOutcome, Elevation, Preflight};
use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::verify::{VerifyEvent, STEP_NAMES_IMAGE, STEP_NAMES_INSTALL};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Gauge, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::Arc;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum VerifyMode {
    Image,
    Install,
}

enum Phase {
    /// Install only: picking the device to check. Read-only, so unlike FLASH
    /// there is no summary/typed-confirmation gate — Enter starts the checks.
    Devices,
    /// Install only, non-root: the sudo password needed to READ the device.
    SudoPass {
        buf: String,
        error: Option<String>,
    },
    Running,
    Done {
        ok: bool,
    },
}

pub struct VerifyScreen {
    mode: VerifyMode,
    phase: Phase,
    steps: [StepState; 5],
    step_names: [&'static str; 5],
    /// Finding lines (partition rows, UKI names, digests) from the worker.
    details: Vec<String>,
    /// Top visible finding line; only honoured while not following the tail.
    scroll: usize,
    follow: bool,
    rx: Option<Receiver<VerifyEvent>>,
    /// Install only: 's' flips it and the worker waives the fidelity compare.
    skip: Arc<AtomicBool>,
    /// The built `.raw` (verify target, or fidelity reference for a device).
    image: Option<(PathBuf, u64)>,
    disks: Vec<Disk>,
    selected: usize,
    list_error: Option<String>,
    /// The device chosen to check, held across the sudo-password step (install, non-root).
    pending_dev: Option<PathBuf>,
    gauge_title: &'static str,
    progress: (u64, u64),
    /// The final verdict line (PASS summary or issue list), shown in the panel.
    message: Option<String>,
    /// THIS verification's session-log file (set when the checks start), so
    /// the panel/footer never show a stale path from an earlier action.
    /// pub(crate): the image mode spawns in the constructor, so HOME opens
    /// the log right after constructing (see ui/home.rs).
    pub(crate) session_log: Option<PathBuf>,
}

impl VerifyScreen {
    fn empty(mode: VerifyMode) -> Self {
        VerifyScreen {
            mode,
            phase: Phase::Devices,
            steps: [StepState::Pending; 5],
            step_names: match mode {
                VerifyMode::Image => STEP_NAMES_IMAGE,
                VerifyMode::Install => STEP_NAMES_INSTALL,
            },
            details: Vec::new(),
            scroll: 0,
            follow: true,
            rx: None,
            skip: Arc::new(AtomicBool::new(false)),
            image: None,
            disks: Vec::new(),
            selected: 0,
            list_error: None,
            pending_dev: None,
            gauge_title: "",
            progress: (0, 0),
            message: None,
            session_log: None,
        }
    }

    /// VERIFY IMAGE: the checks start immediately against the built `.raw` —
    /// there is nothing to pick and nothing destructive to gate.
    pub fn new_image(config_path: &std::path::Path) -> Self {
        let mut screen = Self::empty(VerifyMode::Image);
        match flash::find_image(config_path) {
            Ok(img) => {
                let size = std::fs::metadata(&img).map(|m| m.len()).unwrap_or(0);
                screen.rx = Some(crate::verify::spawn_verify_image(img.clone()));
                screen.image = Some((img, size));
                screen.phase = Phase::Running;
            }
            // No image = nothing to verify; land directly on a failure panel.
            Err(e) => {
                screen.message = Some(format!("{e:#}"));
                screen.phase = Phase::Done { ok: false };
            }
        }
        screen
    }

    /// VERIFY INSTALL: pick a device first. A missing built image is NOT fatal
    /// here — the structural checks stand alone, only fidelity gets skipped.
    pub fn new_install(config_path: &std::path::Path) -> Self {
        let mut screen = Self::empty(VerifyMode::Install);
        screen.image = flash::find_image(config_path)
            .ok()
            .and_then(|p| std::fs::metadata(&p).map(|m| (p, m.len())).ok());
        screen.refresh_disks();
        screen
    }

    pub fn is_running(&self) -> bool {
        matches!(self.phase, Phase::Running)
    }

    /// Start the (read-only) install verification on `dev` with the resolved elevation.
    fn arm_install(&mut self, dev: PathBuf, log: &mut crate::logging::SessionLog, elev: Elevation) {
        // Fresh skip flag per run — a skip from a previous verification must not silently waive
        // this one's fidelity compare.
        self.skip = Arc::new(AtomicBool::new(false));
        self.session_log = log.begin("verify-install");
        self.rx = Some(crate::verify::spawn_verify_install(
            dev,
            self.image.as_ref().map(|(p, _)| p.clone()),
            self.skip.clone(),
            elev,
        ));
        self.phase = Phase::Running;
    }

    fn refresh_disks(&mut self) {
        match flash::list_disks() {
            Ok(disks) => {
                self.disks = disks;
                self.list_error = None;
            }
            Err(e) => {
                self.disks.clear();
                self.list_error = Some(format!("{e:#}"));
            }
        }
        self.selected = self.selected.min(self.disks.len().saturating_sub(1));
    }

    /// Pull everything the worker produced since the last frame, teeing every
    /// event into the session log — the file gets exactly what this pane shows
    /// (progress is a gauge, not a line — it is deliberately not logged).
    pub fn drain_events(&mut self, slog: &mut crate::logging::SessionLog) {
        let Some(rx) = &self.rx else { return };
        let mut done: Option<Result<String, String>> = None;
        while let Ok(ev) = rx.try_recv() {
            match ev {
                VerifyEvent::Step(i, s) => {
                    if let Some(name) = self.step_names.get(i) {
                        slog.step(name, s);
                    }
                    if let Some(slot) = self.steps.get_mut(i) {
                        *slot = s;
                    }
                }
                VerifyEvent::Detail(line) => {
                    slog.line(&line);
                    self.details.push(line);
                }
                VerifyEvent::Phase(title) => {
                    slog.phase(title);
                    self.gauge_title = title;
                    self.progress = (0, 0);
                }
                VerifyEvent::Progress { done, total } => self.progress = (done, total),
                VerifyEvent::Done(r) => done = Some(r),
            }
        }
        if let Some(result) = done {
            self.rx = None;
            match result {
                Ok(msg) => {
                    slog.done(true, &msg);
                    self.message = Some(msg);
                    self.phase = Phase::Done { ok: true };
                }
                Err(e) => {
                    slog.done(false, &e);
                    self.message = Some(e);
                    self.phase = Phase::Done { ok: false };
                }
            }
        }
    }
}

pub fn on_key(app: &mut App, key: KeyEvent) {
    let Some(st) = app.verify.as_mut() else {
        return;
    };
    match &mut st.phase {
        Phase::Devices => match key.code {
            KeyCode::Esc => {
                app.verify = None;
                app.screen = Screen::Home;
            }
            KeyCode::Up | KeyCode::Char('k') => st.selected = st.selected.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                st.selected = (st.selected + 1).min(st.disks.len().saturating_sub(1));
            }
            KeyCode::Char('r') => st.refresh_disks(),
            KeyCode::Enter => {
                let Some(dev) = st.disks.get(st.selected).map(Disk::dev_path) else {
                    return;
                };
                // Reading the raw device needs root. Root → go; non-root → sudo modal; no sudo →
                // try a direct read anyway and let the EACCES verdict explain (the fallback panel).
                match sudo::preflight() {
                    Preflight::Root => st.arm_install(dev, &mut app.log, Elevation::Root),
                    Preflight::NeedsSudo => {
                        st.pending_dev = Some(dev);
                        st.phase = Phase::SudoPass {
                            buf: String::new(),
                            error: None,
                        };
                    }
                    Preflight::NoSudo => st.arm_install(dev, &mut app.log, Elevation::Root),
                }
            }
            _ => {}
        },
        Phase::SudoPass { buf, .. } => match key.code {
            KeyCode::Esc => st.phase = Phase::Devices,
            KeyCode::Enter => {
                let entered = std::mem::take(buf);
                let dev = st.pending_dev.clone();
                match sudo::authenticate(entered) {
                    AuthOutcome::Ok(elev) => {
                        if let Some(dev) = dev {
                            st.arm_install(dev, &mut app.log, elev);
                        }
                    }
                    AuthOutcome::Wrong => {
                        st.phase = Phase::SudoPass {
                            buf: String::new(),
                            error: Some("Wrong sudo password — try again".into()),
                        }
                    }
                    // sudo vanished — fall back to a direct read (EACCES verdict explains).
                    AuthOutcome::Missing => {
                        if let Some(dev) = dev {
                            st.arm_install(dev, &mut app.log, Elevation::Root);
                        }
                    }
                    AuthOutcome::Error(e) => {
                        st.message = Some(e);
                        st.phase = Phase::Done { ok: false };
                    }
                }
            }
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Char(c) => buf.push(c),
            _ => {}
        },
        Phase::Running => match key.code {
            // Esc is deliberately inert (same rule as build/flash: never orphan
            // a worker). 's' waives only the fidelity compare — the structural
            // checks always run to completion.
            KeyCode::Char('s') if st.mode == VerifyMode::Install => {
                st.skip.store(true, Ordering::Relaxed);
            }
            KeyCode::Up => {
                st.follow = false;
                st.scroll = st.scroll.saturating_sub(1);
            }
            KeyCode::Down => st.scroll += 1,
            KeyCode::PageUp => {
                st.follow = false;
                st.scroll = st.scroll.saturating_sub(20);
            }
            KeyCode::PageDown => st.scroll += 20,
            KeyCode::End | KeyCode::Char('f') => st.follow = true,
            _ => {}
        },
        Phase::Done { .. } => match key.code {
            KeyCode::Esc | KeyCode::Enter => {
                app.verify = None;
                app.screen = Screen::Home;
            }
            KeyCode::Up => {
                st.follow = false;
                st.scroll = st.scroll.saturating_sub(1);
            }
            KeyCode::Down => st.scroll += 1,
            KeyCode::PageUp => {
                st.follow = false;
                st.scroll = st.scroll.saturating_sub(20);
            }
            KeyCode::PageDown => st.scroll += 20,
            KeyCode::End | KeyCode::Char('f') => st.follow = true,
            _ => {}
        },
    }
}

pub fn draw(f: &mut Frame, app: &mut App) {
    let Some(st) = app.verify.as_mut() else {
        return;
    };
    let [main_area, aux_area, footer_area] = Layout::vertical([
        Constraint::Min(8),
        Constraint::Length(5),
        Constraint::Length(1),
    ])
    .areas(f.area());

    match &st.phase {
        Phase::Devices | Phase::SudoPass { .. } => {
            draw_devices(f, st, main_area);
            draw_reference(f, st, aux_area);
            ui::footer(
                f,
                footer_area,
                &[
                    ("↑↓", "select"),
                    ("Enter", "check (read-only)"),
                    ("r", "refresh"),
                    ("Esc", "back"),
                ],
            );
            if let Phase::SudoPass { buf, error } = &st.phase {
                crate::ui::build::draw_pass_modal(
                    f,
                    "Administrator (sudo) password — needed to read the device",
                    buf,
                    error.as_deref(),
                    false,
                );
            }
        }
        Phase::Running => {
            let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
            draw_checks(f, st, main_area);
            draw_gauge(f, st, aux_area);
            let mut hints = vec![("↑↓/PgUp/PgDn", "scroll"), ("End", "follow")];
            if st.mode == VerifyMode::Install {
                hints.push(("s", "skip fidelity compare"));
            }
            hints.push(("", "verify running — Esc disabled"));
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        Phase::Done { ok } => {
            // Copy the flag out so the borrow of `st.phase` is dead before the
            // mutable borrow draw_checks needs (it clamps the findings scroll).
            let ok = *ok;
            let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
            draw_checks(f, st, main_area);
            draw_verdict(f, st, ok, aux_area);
            let mut hints = vec![("↑↓/PgUp/PgDn", "scroll"), ("Esc/Enter", "back to menu")];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
    }
}

fn draw_devices(f: &mut Frame, st: &mut VerifyScreen, area: Rect) {
    let items: Vec<ListItem> = st
        .disks
        .iter()
        .enumerate()
        .map(|(i, d)| ListItem::new(ui::flash::disk_lines(d, i == st.selected)))
        .collect();
    let title = "Verify install — pick the disk to CHECK (read-only, nothing is written)";
    if items.is_empty() {
        let msg = st
            .list_error
            .clone()
            .unwrap_or_else(|| "No whole disks found — plug the stick in and press r".into());
        f.render_widget(
            Paragraph::new(msg)
                .style(Style::default().fg(WARN))
                .block(ui::panel(title)),
            area,
        );
        return;
    }
    let mut state = ListState::default();
    state.select(Some(st.selected));
    f.render_stateful_widget(
        List::new(items)
            .block(ui::panel(title))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED)),
        area,
        &mut state,
    );
}

/// The fidelity reference under the device list: which image (if any) the
/// device's bytes will be compared against.
fn draw_reference(f: &mut Frame, st: &VerifyScreen, area: Rect) {
    let lines = match &st.image {
        Some((img, size)) => vec![Line::from(vec![
            Span::styled("  Built image  ", Style::default().fg(DIM)),
            Span::styled(img.display().to_string(), Style::default().fg(Color::White)),
            Span::styled(
                format!("  ({})", flash::human_size(*size)),
                Style::default().fg(ACCENT),
            ),
        ])],
        None => vec![Line::from(Span::styled(
            "  none built yet — the flash-fidelity compare will be skipped",
            Style::default().fg(WARN),
        ))],
    };
    f.render_widget(
        Paragraph::new(lines).block(ui::panel("Fidelity reference")),
        area,
    );
}

fn draw_checks(f: &mut Frame, st: &mut VerifyScreen, area: Rect) {
    let [steps_area, detail_area] =
        Layout::horizontal([Constraint::Length(44), Constraint::Min(20)]).areas(area);

    // Step checklist (same vocabulary as the BUILD screen).
    let items: Vec<ListItem> = st
        .step_names
        .iter()
        .zip(st.steps.iter())
        .map(|(name, state)| {
            let (mark, style) = match state {
                StepState::Pending => ("  ○ ", Style::default().fg(DIM)),
                StepState::Running => (
                    "  ▶ ",
                    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
                ),
                StepState::Ok => ("  ✓ ", Style::default().fg(OK)),
                StepState::Skipped => ("  ‒ ", Style::default().fg(DIM)),
                StepState::Fail => (
                    "  ✗ ",
                    Style::default().fg(ERR).add_modifier(Modifier::BOLD),
                ),
            };
            ListItem::new(Line::from(vec![
                Span::styled(mark, style),
                Span::styled(*name, style),
            ]))
        })
        .collect();
    let title = match st.mode {
        VerifyMode::Image => "Verify image",
        VerifyMode::Install => "Verify install",
    };
    f.render_widget(List::new(items).block(ui::panel(title)), steps_area);

    // Findings pane: render only the visible window (same scheme as the BUILD
    // log, though findings stay small — partitions, UKIs, digests).
    let detail_block = ui::panel(if st.follow {
        "Findings (following)"
    } else {
        "Findings"
    });
    let visible_height = detail_block.inner(detail_area).height as usize;
    let max_scroll = st.details.len().saturating_sub(visible_height);
    if st.follow {
        st.scroll = max_scroll;
    } else {
        st.scroll = st.scroll.min(max_scroll);
    }
    let window: Vec<Line> = st
        .details
        .iter()
        .skip(st.scroll)
        .take(visible_height)
        .map(|l| Line::from(l.as_str()))
        .collect();
    f.render_widget(Paragraph::new(window).block(detail_block), detail_area);
}

fn draw_gauge(f: &mut Frame, st: &VerifyScreen, area: Rect) {
    // No hashing pass announced yet (the structural checks are I/O-light and
    // carry no gauge) — leave the row empty rather than showing a dead gauge.
    if st.gauge_title.is_empty() {
        return;
    }
    let [title_area, gauge_area] =
        Layout::vertical([Constraint::Length(1), Constraint::Length(3)]).areas(area);
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!("  {}", st.gauge_title),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ))),
        title_area,
    );
    let (done, total) = st.progress;
    let ratio = if total > 0 {
        (done as f64 / total as f64).min(1.0)
    } else {
        0.0
    };
    let label = if total > 0 {
        format!("{} / {}", flash::human_size(done), flash::human_size(total))
    } else {
        flash::human_size(done)
    };
    f.render_widget(
        Gauge::default()
            .gauge_style(Style::default().fg(ACCENT).bg(Color::Black))
            .ratio(ratio)
            .label(label),
        gauge_area,
    );
}

/// The final PASS/ISSUES panel. Hard failures (unreadable target, missing
/// permissions on a device) land here too, with their instructions intact.
fn draw_verdict(f: &mut Frame, st: &VerifyScreen, ok: bool, area: Rect) {
    let (color, headline) = if ok {
        (OK, "✓ PASS")
    } else {
        (ERR, "✗ ISSUES")
    };
    let mut lines = vec![Line::from(Span::styled(
        format!("  {headline}"),
        Style::default().fg(color).add_modifier(Modifier::BOLD),
    ))];
    if let Some(msg) = &st.message {
        lines.push(Line::from(Span::styled(
            format!("  {msg}"),
            Style::default().fg(Color::White),
        )));
    }
    if let Some(p) = &st.session_log {
        lines.push(Line::from(Span::styled(
            format!("  log: {}", p.display()),
            Style::default().fg(DIM),
        )));
    }
    f.render_widget(
        Paragraph::new(lines)
            .block(ui::panel("Verdict"))
            .wrap(Wrap { trim: false }),
        area,
    );
}
