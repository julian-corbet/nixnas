//! FLASH — pick a whole disk from a live lsblk listing, review the summary, type
//! the bare device name to arm the write, then watch the byte-counter gauge and
//! the header-verification verdict. Every gate lives HERE; flash.rs only executes.

use crate::flash::{self, Disk, FlashEvent};
use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Gauge, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;
use std::path::PathBuf;
use std::sync::mpsc::Receiver;

enum Phase {
    Devices,
    Summary,
    Confirm {
        typed: String,
        error: Option<String>,
    },
    Running,
    Done {
        ok: bool,
    },
}

pub struct FlashScreen {
    /// The built `.raw` and its size; None ⇒ the screen only shows the error.
    image: Option<(PathBuf, u64)>,
    disks: Vec<Disk>,
    selected: usize,
    list_error: Option<String>,
    /// Back the current stick contents up before overwriting (default ON —
    /// same safety default as the old flow).
    backup: bool,
    phase: Phase,
    rx: Option<Receiver<FlashEvent>>,
    gauge_title: &'static str,
    progress: (u64, u64),
    message: Option<String>,
    /// THIS flash's session-log file (set when the write is armed), so the
    /// panel/footer never show a stale path from an earlier action.
    session_log: Option<PathBuf>,
}

impl FlashScreen {
    pub fn new(config_path: &std::path::Path) -> Self {
        let image = flash::find_image(config_path)
            .and_then(|p| Ok((p.clone(), std::fs::metadata(&p)?.len())));
        let (image, message, phase) = match image {
            Ok(pair) => (Some(pair), None, Phase::Devices),
            // No image = nothing to flash; land directly on a failure panel.
            Err(e) => (None, Some(format!("{e:#}")), Phase::Done { ok: false }),
        };
        let mut screen = FlashScreen {
            image,
            disks: Vec::new(),
            selected: 0,
            list_error: None,
            backup: true,
            phase,
            rx: None,
            gauge_title: "",
            progress: (0, 0),
            message,
            session_log: None,
        };
        screen.refresh_disks();
        screen
    }

    pub fn is_running(&self) -> bool {
        matches!(self.phase, Phase::Running)
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

    /// Pull everything the worker produced since the last frame, teeing the
    /// phases and the verdict into the session log (progress is a gauge, not
    /// a line — it is deliberately not logged).
    pub fn drain_events(&mut self, slog: &mut crate::logging::SessionLog) {
        let Some(rx) = &self.rx else { return };
        let mut done: Option<Result<String, String>> = None;
        while let Ok(ev) = rx.try_recv() {
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

    fn selected_disk(&self) -> Option<&Disk> {
        self.disks.get(self.selected)
    }

    /// The one hard block: an image that cannot physically fit is never armed.
    fn image_fits(&self) -> bool {
        match (&self.image, self.selected_disk().and_then(|d| d.size)) {
            (Some((_, img)), Some(dev)) => *img <= dev,
            _ => true, // unknown device size — the typed confirmation still gates
        }
    }

    /// True when the image is SMALLER than the device: grow-to-fill applies (extend the last
    /// partition now, grow the f2fs on first boot). False (or unknown size) ⇒ no grow — an
    /// exact-fit image already reaches the device end.
    fn grows_to_fill(&self) -> bool {
        matches!(
            (&self.image, self.selected_disk().and_then(|d| d.size)),
            (Some((_, img)), Some(dev)) if *img < dev
        )
    }
}

pub fn on_key(app: &mut App, key: KeyEvent) {
    let config_path = app.config_path.clone();
    let Some(st) = app.flash.as_mut() else { return };
    match &mut st.phase {
        Phase::Devices => match key.code {
            KeyCode::Esc => {
                app.flash = None;
                app.screen = Screen::Home;
            }
            KeyCode::Up | KeyCode::Char('k') => st.selected = st.selected.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                st.selected = (st.selected + 1).min(st.disks.len().saturating_sub(1));
            }
            KeyCode::Char('r') => st.refresh_disks(),
            KeyCode::Enter if st.selected_disk().is_some() => st.phase = Phase::Summary,
            _ => {}
        },
        Phase::Summary => match key.code {
            KeyCode::Esc => st.phase = Phase::Devices,
            KeyCode::Char('b') => st.backup = !st.backup,
            // The one hard block: an image that cannot physically fit is never armed.
            KeyCode::Enter if st.image_fits() => {
                st.phase = Phase::Confirm {
                    typed: String::new(),
                    error: None,
                };
            }
            _ => {}
        },
        Phase::Confirm { typed, .. } => match key.code {
            KeyCode::Esc => st.phase = Phase::Summary,
            KeyCode::Backspace => {
                typed.pop();
            }
            KeyCode::Char(c) => typed.push(c),
            KeyCode::Enter => {
                let typed = std::mem::take(typed);
                // Copy the disk facts out so the immutable borrow of `st` is dead
                // before we mutate `st.phase`/`st.rx` below.
                let Some((name, dev, size)) = st
                    .selected_disk()
                    .map(|d| (d.name.clone(), d.dev_path(), d.size))
                else {
                    return;
                };
                // The point of no return: the BARE device name, typed exactly.
                if typed.trim() == name {
                    let (image, _) = st.image.clone().expect("confirmed without an image");
                    let backup_to = st.backup.then(|| flash::backup_path(&config_path));
                    let grow = st.grows_to_fill();
                    // The action is real from here: open its session-log file.
                    st.session_log = app.log.begin("flash");
                    st.rx = Some(flash::spawn_flash(image, dev, size, backup_to, grow));
                    st.phase = Phase::Running;
                } else {
                    st.phase = Phase::Confirm {
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
        // Esc is deliberately inert mid-write: there is no safe way to back out
        // of a half-overwritten stick from a keypress.
        Phase::Running => {}
        Phase::Done { .. } => match key.code {
            KeyCode::Esc | KeyCode::Enter => {
                app.flash = None;
                app.screen = Screen::Home;
            }
            _ => {}
        },
    }
}

pub fn draw(f: &mut Frame, app: &mut App) {
    let config_path = app.config_path.clone();
    let Some(st) = app.flash.as_mut() else { return };
    let [main_area, footer_area] =
        Layout::vertical([Constraint::Min(8), Constraint::Length(1)]).areas(f.area());

    match &st.phase {
        Phase::Devices => {
            draw_devices(f, st, main_area);
            ui::footer(
                f,
                footer_area,
                &[
                    ("↑↓", "select"),
                    ("Enter", "choose target"),
                    ("r", "refresh"),
                    ("Esc", "back"),
                ],
            );
        }
        Phase::Summary | Phase::Confirm { .. } => {
            draw_summary(f, st, &config_path, main_area);
            if matches!(st.phase, Phase::Summary) {
                ui::footer(
                    f,
                    footer_area,
                    &[
                        ("b", "toggle backup"),
                        ("Enter", "continue"),
                        ("Esc", "back"),
                    ],
                );
            } else {
                ui::footer(f, footer_area, &[("Enter", "confirm"), ("Esc", "back")]);
            }
            if let Phase::Confirm { typed, error } = &st.phase {
                draw_confirm_modal(f, st.selected_disk(), typed, error.as_deref());
            }
        }
        Phase::Running => {
            draw_progress(f, st, main_area);
            let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
            let mut hints = vec![("", "writing — do not remove the stick")];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        Phase::Done { ok } => {
            draw_done(f, st, *ok, main_area);
            let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
            let mut hints = vec![("Esc/Enter", "back to menu")];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
    }
}

/// Crate-visible: the VERIFY INSTALL screen reuses this exact disk presentation.
pub(crate) fn disk_lines(d: &Disk, _selected: bool) -> Vec<Line<'static>> {
    let size = d.size.map(flash::human_size).unwrap_or_else(|| "?".into());
    let tran = d.tran.clone().unwrap_or_default();
    let badge = if d.looks_like_usb_stick() {
        Span::styled(
            " ● USB/removable ",
            Style::default().fg(Color::Black).bg(OK),
        )
    } else {
        Span::styled(
            " ⚠ INTERNAL DISK ",
            Style::default().fg(Color::Black).bg(ERR),
        )
    };
    let mut lines = vec![Line::from(vec![
        Span::styled(
            format!(" /dev/{:<8}", d.name),
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("{size:>10}  "), Style::default().fg(ACCENT)),
        Span::styled(format!("{tran:<6}"), Style::default().fg(DIM)),
        badge,
        Span::styled(
            format!("  {}", d.model.clone().unwrap_or_default()),
            Style::default().fg(DIM),
        ),
    ])];
    // Partitions are CONTEXT (what the operator is about to destroy), not targets.
    for p in &d.parts {
        let psize = p.size.map(flash::human_size).unwrap_or_else(|| "?".into());
        let label = p
            .label
            .clone()
            .map(|l| format!("  [{l}]"))
            .unwrap_or_default();
        lines.push(Line::from(Span::styled(
            format!("   ├─{:<10}{psize:>10}{label}", p.name),
            Style::default().fg(DIM),
        )));
    }
    lines
}

fn draw_devices(f: &mut Frame, st: &mut FlashScreen, area: ratatui::layout::Rect) {
    draw_disk_list(
        f,
        area,
        &st.disks,
        st.selected,
        st.list_error.as_deref(),
        "Flash stick — pick the TARGET disk (it will be OVERWRITTEN)",
    );
}

/// Crate-visible: the "Build & flash a stick" pathway reuses this exact disk picker to choose
/// the target device it will SIZE the image to (and later flash to).
pub(crate) fn draw_disk_list(
    f: &mut Frame,
    area: ratatui::layout::Rect,
    disks: &[Disk],
    selected: usize,
    list_error: Option<&str>,
    title: &str,
) {
    let items: Vec<ListItem> = disks
        .iter()
        .enumerate()
        .map(|(i, d)| ListItem::new(disk_lines(d, i == selected)))
        .collect();
    if items.is_empty() {
        let msg = list_error
            .map(str::to_string)
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
    state.select(Some(selected));
    f.render_stateful_widget(
        List::new(items)
            .block(ui::panel(title))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED)),
        area,
        &mut state,
    );
}

fn draw_summary(
    f: &mut Frame,
    st: &FlashScreen,
    config_path: &std::path::Path,
    area: ratatui::layout::Rect,
) {
    let Some(disk) = st.selected_disk() else {
        return;
    };
    let Some((image, image_size)) = &st.image else {
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
                format!("  ({})", flash::human_size(*image_size)),
                Style::default().fg(ACCENT),
            ),
        ]),
        Line::from(vec![
            label("Device"),
            Span::styled(
                format!(
                    "/dev/{}  {}",
                    disk.name,
                    disk.model.clone().unwrap_or_default()
                ),
                Style::default().fg(Color::White),
            ),
            Span::styled(
                format!(
                    "  ({})",
                    disk.size
                        .map(flash::human_size)
                        .unwrap_or_else(|| "size unknown".into())
                ),
                Style::default().fg(ACCENT),
            ),
        ]),
        Line::default(),
    ];
    if !st.image_fits() {
        lines.push(Line::from(Span::styled(
            "  ✗ The image is LARGER than the device — it cannot be flashed here.",
            Style::default().fg(ERR).add_modifier(Modifier::BOLD),
        )));
    } else if !disk.looks_like_usb_stick() {
        lines.push(Line::from(Span::styled(
            "  ⚠ This is NOT a removable/USB disk. Continue only if you are certain.",
            Style::default().fg(ERR).add_modifier(Modifier::BOLD),
        )));
    }
    if st.grows_to_fill() {
        lines.push(Line::from(Span::styled(
            "  ⤢ Image smaller than the device — grow to fill (partition now, filesystem on first boot).",
            Style::default().fg(OK),
        )));
    }
    lines.push(Line::from(vec![
        Span::styled(
            if st.backup { "  [x] " } else { "  [ ] " },
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "Back the current contents of /dev/{} up to {} first",
                disk.name,
                flash::backup_path(config_path).display()
            ),
            Style::default().fg(Color::White),
        ),
    ]));
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        format!("  Every byte on /dev/{} will be destroyed.", disk.name),
        Style::default().fg(WARN),
    )));
    f.render_widget(
        Paragraph::new(lines)
            .block(ui::panel("Flash stick — summary"))
            .wrap(Wrap { trim: false }),
        area,
    );
}

/// Crate-visible: the "Build & flash a stick" pathway reuses this typed-name confirmation modal.
pub(crate) fn draw_confirm_modal(
    f: &mut Frame,
    disk: Option<&Disk>,
    typed: &str,
    error: Option<&str>,
) {
    let Some(disk) = disk else { return };
    let area = ui::centered_rect(f.area(), 62, 8);
    let inner = ui::modal(f, area, "Point of no return");
    let [text_area, input_area, error_area] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);
    f.render_widget(
        Paragraph::new(vec![
            Line::from(vec![
                Span::styled(
                    "This will COMPLETELY OVERWRITE ",
                    Style::default().fg(Color::White),
                ),
                Span::styled(
                    format!("/dev/{}", disk.name),
                    Style::default().fg(ERR).add_modifier(Modifier::BOLD),
                ),
                Span::styled(".", Style::default().fg(Color::White)),
            ]),
            Line::from(Span::styled(
                format!("Type the bare device name ({}) to confirm:", disk.name),
                Style::default().fg(DIM),
            )),
        ])
        .wrap(Wrap { trim: true }),
        text_area,
    );
    f.render_widget(Paragraph::new(ui::input_line(typed, false)), input_area);
    if let Some(e) = error {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(e, Style::default().fg(WARN)))),
            error_area,
        );
    }
}

fn draw_progress(f: &mut Frame, st: &FlashScreen, area: ratatui::layout::Rect) {
    draw_progress_body(
        f,
        area,
        "Flash stick — writing",
        st.gauge_title,
        st.progress,
    );
}

/// Crate-visible: a titled panel with a phase line + byte-counter gauge. Reused by the
/// "Build & flash a stick" pathway for its flash phase.
pub(crate) fn draw_progress_body(
    f: &mut Frame,
    area: ratatui::layout::Rect,
    panel_title: &str,
    phase: &str,
    progress: (u64, u64),
) {
    let block = ui::panel(panel_title);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let [_, title_area, gauge_area, _] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(3),
        Constraint::Min(0),
    ])
    .areas(inner);
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!("  {phase}"),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ))),
        title_area,
    );
    let (done, total) = progress;
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

fn draw_done(f: &mut Frame, st: &FlashScreen, ok: bool, area: ratatui::layout::Rect) {
    let (title, color, headline) = if ok {
        (
            "Flash stick — verified",
            OK,
            "✓ Write complete — device header verified against the image.",
        )
    } else {
        ("Flash stick — failed", ERR, "✗ Not flashed.")
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
    if let Some(p) = &st.session_log {
        lines.push(Line::default());
        lines.push(Line::from(Span::styled(
            format!("  log: {}", p.display()),
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
