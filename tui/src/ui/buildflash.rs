//! BUILD & FLASH A STICK — the turnkey pathway (A). ONE guided, chained flow: pick the target
//! device FIRST → size an EXACT-FIT image to its byte count → build it → then flash that image
//! straight onto the SAME device (typed confirmation + header verify) → done.
//!
//! It reuses the proven cores unchanged: the flash device picker (flash.rs `Disk`), the build
//! pipeline (build.rs, sized via `SizeOverride::Bytes`), the flash worker (flash.rs), the masked
//! passphrase modal, the typed-name confirmation and the byte-counter gauge. Because the image is
//! built to the device's EXACT size, no grow-to-fill is needed here (that is Pathway B's job).
//!
//! Chaining note: the build and the flash each get their OWN session-log file (build-… then
//! flash-…), same as the standalone pathways — the screen just drives them back to back.

use crate::build::{
    self, check_target_bytes, device_bytes, BuildEvent, SizeOverride, StepState, STEP_NAMES,
};
use crate::config::Config;
use crate::flash::{self, Disk, FlashEvent};
use crate::sudo::{self, AuthOutcome, Elevation, Preflight};
use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;
use std::path::PathBuf;
use std::sync::mpsc::Receiver;

/// Keep the log bounded; same policy as the standalone build screen.
const MAX_LOG_LINES: usize = 10_000;
const TRIM_CHUNK: usize = 2_000;

enum Stage {
    /// `host_attr` is unset, so the image cannot be sized to the device — a terminal explanation.
    Unavailable,
    /// Choose the target stick (its exact size sets the image size AND it is the flash target).
    PickDevice,
    PassFirst {
        buf: String,
        error: Option<String>,
    },
    PassConfirm {
        first: String,
        buf: String,
    },
    Building,
    /// Build succeeded — review the flash (backup toggle, exact-fit check) before arming.
    FlashReview,
    FlashConfirm {
        typed: String,
        error: Option<String>,
    },
    /// Non-root only: the sudo password needed to WRITE the device (distinct from the LUKS
    /// passphrase collected earlier for the build).
    FlashSudo {
        buf: String,
        error: Option<String>,
    },
    Flashing,
    Done {
        ok: bool,
    },
}

pub struct BuildFlowScreen {
    disks: Vec<Disk>,
    selected: usize,
    list_error: Option<String>,
    pick_error: Option<String>,
    /// (bare device name, EXACT byte size) of the chosen target — sizes the build, is the flash
    /// target, and is the exact-fit reference for the post-build check.
    picked: Option<(String, u64)>,
    /// Back the device up before overwriting (default ON — same safety default as flash).
    backup: bool,
    stage: Stage,

    // Build side.
    steps: [StepState; STEP_NAMES.len()],
    log: Vec<String>,
    scroll: usize,
    follow: bool,
    build_rx: Option<Receiver<BuildEvent>>,
    /// The built `.raw` and its byte size, once the build finishes.
    built: Option<(PathBuf, u64)>,

    // Flash side.
    flash_rx: Option<Receiver<FlashEvent>>,
    gauge_title: &'static str,
    progress: (u64, u64),

    /// The final outcome / terminal explanation line.
    message: Option<String>,
    /// The CURRENT action's session-log file (build first, then flash), so the footer never shows
    /// a stale path across the two chained actions.
    session_log: Option<PathBuf>,
}

impl BuildFlowScreen {
    pub fn new(cfg: &Config) -> Self {
        let available = cfg.host_attr.is_some();
        let mut s = BuildFlowScreen {
            disks: Vec::new(),
            selected: 0,
            list_error: None,
            pick_error: None,
            picked: None,
            backup: true,
            stage: if available {
                Stage::PickDevice
            } else {
                Stage::Unavailable
            },
            steps: [StepState::Pending; STEP_NAMES.len()],
            log: Vec::new(),
            scroll: 0,
            follow: true,
            build_rx: None,
            built: None,
            flash_rx: None,
            gauge_title: "",
            progress: (0, 0),
            message: (!available).then(|| {
                "Build & flash needs `host_attr` set (Configure) — it sizes the image to the \
                 device by re-evaluating that host. Set it, or use the separate Build/Flash entries."
                    .to_string()
            }),
            session_log: None,
        };
        if available {
            s.refresh_disks();
        }
        s
    }

    /// A worker owns the build or the flash — Esc is refused (same rule as the other screens).
    pub fn is_running(&self) -> bool {
        matches!(self.stage, Stage::Building | Stage::Flashing)
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

    fn selected_disk(&self) -> Option<&Disk> {
        self.disks.get(self.selected)
    }

    /// Pull worker events since the last frame, teeing into the session log. Build and flash never
    /// run at once, so only one receiver is live.
    pub fn drain_events(&mut self, slog: &mut crate::logging::SessionLog) {
        // Build phase.
        if self.build_rx.is_some() {
            let mut done: Option<Result<PathBuf, String>> = None;
            while let Ok(ev) = self.build_rx.as_ref().unwrap().try_recv() {
                match ev {
                    BuildEvent::Step(i, s) => {
                        if let Some(name) = STEP_NAMES.get(i) {
                            slog.step(name, s);
                        }
                        if let Some(slot) = self.steps.get_mut(i) {
                            *slot = s;
                        }
                    }
                    BuildEvent::Log(line) => {
                        slog.line(&line);
                        self.log.push(line);
                    }
                    BuildEvent::Done(r) => done = Some(r),
                }
            }
            if self.log.len() > MAX_LOG_LINES {
                let cut = self.log.len() - (MAX_LOG_LINES - TRIM_CHUNK);
                self.log.drain(..cut);
                self.scroll = self.scroll.saturating_sub(cut);
            }
            if let Some(result) = done {
                self.build_rx = None;
                match result {
                    Ok(img) => {
                        let size = std::fs::metadata(&img).map(|m| m.len()).unwrap_or(0);
                        let msg = format!(
                            "Built image: {} ({})",
                            img.display(),
                            flash::human_size(size)
                        );
                        slog.done(true, &msg);
                        self.built = Some((img, size));
                        // Hand off to the flash review on the SAME device.
                        self.stage = Stage::FlashReview;
                    }
                    Err(e) => {
                        slog.done(false, &e);
                        self.message = Some(e);
                        self.stage = Stage::Done { ok: false };
                    }
                }
            }
        }
        // Flash phase.
        if self.flash_rx.is_some() {
            let mut done: Option<Result<String, String>> = None;
            while let Ok(ev) = self.flash_rx.as_ref().unwrap().try_recv() {
                match ev {
                    FlashEvent::Phase(title) => {
                        slog.phase(title);
                        self.gauge_title = title;
                        self.progress = (0, 0);
                    }
                    FlashEvent::Progress { done, total } => self.progress = (done, total),
                    FlashEvent::Done(r) => done = Some(r),
                }
            }
            if let Some(result) = done {
                self.flash_rx = None;
                match result {
                    Ok(msg) => {
                        slog.done(true, &msg);
                        self.message = Some(msg);
                        self.stage = Stage::Done { ok: true };
                    }
                    Err(e) => {
                        slog.done(false, &e);
                        self.message = Some(e);
                        self.stage = Stage::Done { ok: false };
                    }
                }
            }
        }
    }

    /// Compare the built image's byte size against the target device's exact size. None until the
    /// build has finished. Ok(()) ⇒ exact fit or a harmless smaller tail; Err ⇒ image too big.
    fn exact_fit_note(&self) -> Option<Result<String, String>> {
        let ((_, img), (name, dev)) = (self.built.as_ref()?, self.picked.as_ref()?);
        Some(if img == dev {
            Ok(format!(
                "✓ image is the EXACT size of /dev/{name} ({img} bytes)"
            ))
        } else if img < dev {
            Ok(format!(
                "image is {} smaller than /dev/{name} — a small tail stays unused",
                flash::human_size(dev - img)
            ))
        } else {
            Err(format!(
                "✗ image ({}) is LARGER than /dev/{name} ({}) — cannot flash",
                flash::human_size(*img),
                flash::human_size(*dev)
            ))
        })
    }

    fn image_fits(&self) -> bool {
        !matches!(self.exact_fit_note(), Some(Err(_)))
    }

    /// Start the flash worker on the picked device with the resolved elevation. The typed-name
    /// gate has already passed. Exact-fit image ⇒ no grow-to-fill (that is Pathway B's job).
    fn arm_flash(
        &mut self,
        config_path: &std::path::Path,
        log: &mut crate::logging::SessionLog,
        elev: Elevation,
    ) {
        let Some((name, bytes)) = self.picked.clone() else {
            return;
        };
        let Some((image, _)) = self.built.clone() else {
            return;
        };
        let dev = PathBuf::from(format!("/dev/{name}"));
        let backup_to = self.backup.then(|| flash::backup_path(config_path));
        self.session_log = log.begin("flash");
        self.progress = (0, 0);
        self.stage = Stage::Flashing;
        self.flash_rx = Some(flash::spawn_flash(
            image,
            dev,
            Some(bytes),
            backup_to,
            false,
            elev,
        ));
    }
}

pub fn on_key(app: &mut App, key: KeyEvent) {
    let config_path = app.config_path.clone();
    let Some(st) = app.buildflash.as_mut() else {
        return;
    };
    match &mut st.stage {
        Stage::Unavailable => {
            if matches!(key.code, KeyCode::Esc | KeyCode::Enter) {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
        }
        Stage::PickDevice => match key.code {
            KeyCode::Esc => {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
            KeyCode::Up | KeyCode::Char('k') => st.selected = st.selected.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                st.selected = (st.selected + 1).min(st.disks.len().saturating_sub(1));
            }
            KeyCode::Char('r') => st.refresh_disks(),
            KeyCode::Enter => {
                let Some(name) = st.selected_disk().map(|d| d.name.clone()) else {
                    return;
                };
                // The authoritative EXACT byte size (blockdev --getsize64), not the whole-GiB view.
                match device_bytes(&name) {
                    None => {
                        st.pick_error =
                            Some("device size unknown — cannot size the image to it".into())
                    }
                    Some(bytes) => match check_target_bytes(bytes) {
                        Ok(()) => {
                            st.picked = Some((name, bytes));
                            st.pick_error = None;
                            st.stage = Stage::PassFirst {
                                buf: String::new(),
                                error: None,
                            };
                        }
                        Err(e) => st.pick_error = Some(e),
                    },
                }
            }
            _ => {}
        },
        Stage::PassFirst { buf, .. } => match key.code {
            KeyCode::Esc => {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
            KeyCode::Enter => {
                let taken = std::mem::take(buf);
                st.stage = if taken.is_empty() {
                    Stage::PassFirst {
                        buf: String::new(),
                        error: Some("Passphrase must not be empty".into()),
                    }
                } else {
                    Stage::PassConfirm {
                        first: taken,
                        buf: String::new(),
                    }
                };
            }
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Char(c) => buf.push(c),
            _ => {}
        },
        Stage::PassConfirm { first, buf } => match key.code {
            KeyCode::Esc => {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
            KeyCode::Enter => {
                let first = std::mem::take(first);
                let second = std::mem::take(buf);
                if first == second {
                    let bytes = st.picked.as_ref().map(|(_, b)| *b).unwrap_or(0);
                    st.session_log = app.log.begin("build");
                    st.steps = [StepState::Pending; STEP_NAMES.len()];
                    st.log.clear();
                    st.stage = Stage::Building;
                    st.build_rx = Some(build::spawn_build(
                        config_path,
                        app.cfg.clone(),
                        first,
                        SizeOverride::Bytes(bytes),
                    ));
                } else {
                    st.stage = Stage::PassFirst {
                        buf: String::new(),
                        error: Some("Passphrases do not match — try again".into()),
                    };
                }
            }
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Char(c) => buf.push(c),
            _ => {}
        },
        // Esc is inert mid-build; only log scrolling.
        Stage::Building => match key.code {
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
        Stage::FlashReview => match key.code {
            // Backing out here keeps the built image (flashable later via the Flash entry).
            KeyCode::Esc => {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
            KeyCode::Char('b') => st.backup = !st.backup,
            KeyCode::Enter if st.image_fits() => {
                st.stage = Stage::FlashConfirm {
                    typed: String::new(),
                    error: None,
                };
            }
            _ => {}
        },
        Stage::FlashConfirm { typed, .. } => match key.code {
            KeyCode::Esc => st.stage = Stage::FlashReview,
            KeyCode::Backspace => {
                typed.pop();
            }
            KeyCode::Char(c) => typed.push(c),
            KeyCode::Enter => {
                let typed = std::mem::take(typed);
                let Some((name, _bytes)) = st.picked.clone() else {
                    return;
                };
                if typed.trim() == name {
                    // Writing the device needs root — elevate from inside the tool.
                    match sudo::preflight() {
                        Preflight::Root => {
                            st.arm_flash(&config_path, &mut app.log, Elevation::Root)
                        }
                        Preflight::NeedsSudo => {
                            st.stage = Stage::FlashSudo {
                                buf: String::new(),
                                error: None,
                            }
                        }
                        Preflight::NoSudo => {
                            st.message = Some(
                                "sudo is not installed — run nixnas as root to flash the device."
                                    .into(),
                            );
                            st.stage = Stage::Done { ok: false };
                        }
                    }
                } else {
                    st.stage = Stage::FlashConfirm {
                        typed: String::new(),
                        error: Some(format!(
                            "`{}` does not match `{name}` — nothing written",
                            typed.trim()
                        )),
                    };
                }
            }
            _ => {}
        },
        Stage::FlashSudo { buf, .. } => match key.code {
            KeyCode::Esc => st.stage = Stage::FlashReview,
            KeyCode::Enter => {
                let entered = std::mem::take(buf);
                match sudo::authenticate(entered) {
                    AuthOutcome::Ok(elev) => st.arm_flash(&config_path, &mut app.log, elev),
                    AuthOutcome::Wrong => {
                        st.stage = Stage::FlashSudo {
                            buf: String::new(),
                            error: Some("Wrong sudo password — try again".into()),
                        }
                    }
                    AuthOutcome::Missing => {
                        st.message = Some("sudo is not installed — run nixnas as root.".into());
                        st.stage = Stage::Done { ok: false };
                    }
                    AuthOutcome::Error(e) => {
                        st.message = Some(e);
                        st.stage = Stage::Done { ok: false };
                    }
                }
            }
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Char(c) => buf.push(c),
            _ => {}
        },
        // Esc is inert mid-write.
        Stage::Flashing => {}
        Stage::Done { .. } => {
            if matches!(key.code, KeyCode::Esc | KeyCode::Enter) {
                app.buildflash = None;
                app.screen = Screen::Home;
            }
        }
    }
}

pub fn draw(f: &mut Frame, app: &mut App) {
    let Some(st) = app.buildflash.as_mut() else {
        return;
    };
    let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
    let [main_area, message_area, footer_area] = Layout::vertical([
        Constraint::Min(8),
        Constraint::Length(2),
        Constraint::Length(1),
    ])
    .areas(f.area());

    // The device-name subtitle threaded through the build/flash titles.
    let dev_name = st
        .picked
        .as_ref()
        .map(|(n, _)| n.clone())
        .unwrap_or_default();

    match &st.stage {
        Stage::Unavailable => {
            f.render_widget(
                Paragraph::new(st.message.clone().unwrap_or_default())
                    .style(Style::default().fg(WARN))
                    .wrap(Wrap { trim: true })
                    .block(ui::panel("Build & Flash — unavailable")),
                main_area,
            );
            ui::footer(f, footer_area, &[("Esc/Enter", "back to menu")]);
        }
        Stage::PickDevice => {
            crate::ui::flash::draw_disk_list(
                f,
                main_area,
                &st.disks,
                st.selected,
                st.list_error.as_deref(),
                "Build & flash — pick the TARGET stick (its exact size sets the image; nothing written yet)",
            );
            if let Some(err) = &st.pick_error {
                f.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        format!(" {err}"),
                        Style::default().fg(WARN),
                    ))),
                    message_area,
                );
            }
            ui::footer(
                f,
                footer_area,
                &[
                    ("↑↓", "select"),
                    ("Enter", "size + build for this stick"),
                    ("r", "refresh"),
                    ("Esc", "back"),
                ],
            );
        }
        Stage::PassFirst { buf, error } => {
            // Own the modal inputs so the mutable body draw below is free of the pattern borrow.
            let (buf, error) = (buf.clone(), error.clone());
            draw_pending_body(f, main_area, &dev_name, st);
            ui::footer(f, footer_area, &[("Enter", "confirm"), ("Esc", "cancel")]);
            crate::ui::build::draw_pass_modal(
                f,
                "LUKS store passphrase",
                &buf,
                error.as_deref(),
                false,
            );
        }
        Stage::PassConfirm { buf, .. } => {
            let buf = buf.clone();
            draw_pending_body(f, main_area, &dev_name, st);
            ui::footer(f, footer_area, &[("Enter", "confirm"), ("Esc", "cancel")]);
            crate::ui::build::draw_pass_modal(f, "Confirm passphrase", &buf, None, true);
        }
        Stage::Building => {
            let title = format!("Build & flash — building exact-fit image for /dev/{dev_name}");
            crate::ui::build::draw_build_body(
                f,
                main_area,
                &title,
                &st.steps,
                &st.log,
                &mut st.scroll,
                st.follow,
            );
            let mut hints = vec![
                ("↑↓/PgUp/PgDn", "scroll log"),
                ("End", "follow"),
                ("", "building — Esc disabled"),
            ];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        Stage::FlashReview | Stage::FlashConfirm { .. } | Stage::FlashSudo { .. } => {
            draw_flash_review(f, main_area, st);
            if matches!(st.stage, Stage::FlashReview) {
                ui::footer(
                    f,
                    footer_area,
                    &[
                        ("b", "toggle backup"),
                        ("Enter", "flash to this stick"),
                        ("Esc", "back to menu (keep image)"),
                    ],
                );
            } else {
                ui::footer(f, footer_area, &[("Enter", "confirm"), ("Esc", "back")]);
            }
            match &st.stage {
                Stage::FlashConfirm { typed, error } => {
                    crate::ui::flash::draw_confirm_modal(
                        f,
                        st.selected_disk(),
                        typed,
                        error.as_deref(),
                    );
                }
                Stage::FlashSudo { buf, error } => {
                    crate::ui::build::draw_pass_modal(
                        f,
                        "Administrator (sudo) password — needed to write the device",
                        buf,
                        error.as_deref(),
                        false,
                    );
                }
                _ => {}
            }
        }
        Stage::Flashing => {
            crate::ui::flash::draw_progress_body(
                f,
                main_area,
                "Build & flash — writing",
                st.gauge_title,
                st.progress,
            );
            let mut hints = vec![("", "writing — do not remove the stick")];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        Stage::Done { ok } => {
            draw_done(f, main_area, *ok, st, log_path.as_deref());
            ui::footer(f, footer_area, &[("Esc/Enter", "back to menu")]);
        }
    }

    // message_area is used only by the PickDevice pick-error above; other stages carry their
    // outcome inside their own panels. Nothing else to render here.
    let _ = message_area;
}

/// The build body while the passphrase is still being entered: all steps pending, empty log.
fn draw_pending_body(f: &mut Frame, area: Rect, dev_name: &str, st: &mut BuildFlowScreen) {
    let title = if dev_name.is_empty() {
        "Build & Flash".to_string()
    } else {
        format!("Build & flash — exact-fit image for /dev/{dev_name}")
    };
    crate::ui::build::draw_build_body(
        f,
        area,
        &title,
        &st.steps,
        &st.log,
        &mut st.scroll,
        st.follow,
    );
}

fn draw_flash_review(f: &mut Frame, area: Rect, st: &BuildFlowScreen) {
    let Some((image, image_size)) = &st.built else {
        return;
    };
    let Some((name, dev_bytes)) = &st.picked else {
        return;
    };
    let label = |s: &str| Span::styled(format!("  {s:<14}"), Style::default().fg(DIM));
    let mut lines = vec![
        Line::from(vec![
            label("Image"),
            Span::styled(
                image.display().to_string(),
                Style::default().fg(Color::White),
            ),
            Span::styled(
                format!("  ({}, {image_size} bytes)", flash::human_size(*image_size)),
                Style::default().fg(ACCENT),
            ),
        ]),
        Line::from(vec![
            label("Device"),
            Span::styled(format!("/dev/{name}"), Style::default().fg(Color::White)),
            Span::styled(
                format!("  ({}, {dev_bytes} bytes)", flash::human_size(*dev_bytes)),
                Style::default().fg(ACCENT),
            ),
        ]),
        Line::default(),
    ];
    // The exact-fit verdict (assertion made visible).
    match st.exact_fit_note() {
        Some(Ok(note)) => lines.push(Line::from(Span::styled(
            format!("  {note}"),
            Style::default().fg(OK),
        ))),
        Some(Err(note)) => lines.push(Line::from(Span::styled(
            format!("  {note}"),
            Style::default().fg(ERR).add_modifier(Modifier::BOLD),
        ))),
        None => {}
    }
    lines.push(Line::from(vec![
        Span::styled(
            if st.backup { "  [x] " } else { "  [ ] " },
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("Back the current contents of /dev/{name} up first"),
            Style::default().fg(Color::White),
        ),
    ]));
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        format!("  Every byte on /dev/{name} will be destroyed.",),
        Style::default().fg(WARN),
    )));
    f.render_widget(
        Paragraph::new(lines)
            .block(ui::panel("Build & flash — ready to flash"))
            .wrap(Wrap { trim: false }),
        area,
    );
}

fn draw_done(f: &mut Frame, area: Rect, ok: bool, st: &BuildFlowScreen, log_path: Option<&str>) {
    let (title, color, headline) = if ok {
        (
            "Build & flash — done",
            OK,
            "✓ Built and flashed — device header verified against the exact-fit image.",
        )
    } else {
        ("Build & flash — failed", ERR, "✗ Not completed.")
    };
    let mut lines = vec![
        Line::default(),
        Line::from(Span::styled(
            format!("  {headline}"),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        )),
    ];
    if let Some(msg) = &st.message {
        lines.push(Line::default());
        lines.push(Line::from(Span::styled(
            format!("  {msg}"),
            Style::default().fg(Color::White),
        )));
    }
    if let Some(p) = log_path {
        lines.push(Line::default());
        lines.push(Line::from(Span::styled(
            format!("  log: {p}"),
            Style::default().fg(DIM),
        )));
    }
    f.render_widget(
        Paragraph::new(lines)
            .block(ui::panel(title))
            .wrap(Wrap { trim: false }),
        area,
    );
}
