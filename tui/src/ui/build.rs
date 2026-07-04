//! BUILD — live step checklist beside a scrolling log pane, fed by the worker in
//! build.rs over an mpsc channel. The LUKS passphrase is collected FIRST (masked,
//! entered twice) so the operator can walk away during the long nix build; the
//! checklist still shows the passphrase step at its true position in the pipeline.

use crate::build::{BuildEvent, SizeOverride, StepState, MINIMAL_IMAGE_GIB, STEP_NAMES};
use crate::config::Config;
use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, Paragraph, Wrap};
use ratatui::Frame;
use std::path::PathBuf;
use std::sync::mpsc::Receiver;

/// Keep the log bounded; trimming in blocks avoids a per-line memmove.
const MAX_LOG_LINES: usize = 10_000;
const TRIM_CHUNK: usize = 2_000;

enum Phase {
    /// First passphrase entry; carries the mismatch complaint, if any.
    PassFirst {
        buf: String,
        error: Option<String>,
    },
    /// Second entry, compared against the first.
    PassConfirm {
        first: String,
        buf: String,
    },
    Running,
    Done {
        ok: bool,
    },
}

pub struct BuildScreen {
    phase: Phase,
    steps: [StepState; STEP_NAMES.len()],
    log: Vec<String>,
    /// Top visible log line; only honoured while not following the tail.
    scroll: usize,
    follow: bool,
    rx: Option<Receiver<BuildEvent>>,
    /// The final outcome line (image path or error), shown above the footer.
    message: Option<String>,
    /// THIS build's session-log file (set when the pipeline starts), so the
    /// panel/footer never show a stale path from an earlier action.
    session_log: Option<PathBuf>,
    /// How this build sizes the image (Pathway B: minimal-reusable when `host_attr` is set,
    /// else the fixed `.#<image_attr>` output). Handed to the worker at spawn.
    size: SizeOverride,
    /// The steps-panel title — states which build this is (minimal N GiB / fixed).
    title: String,
}

impl BuildScreen {
    /// Pathway B "Build image": a standalone build kept at the stable image path. With `host_attr`
    /// set it builds a MINIMAL reusable image (reflash to any stick, grow-to-fill expands it);
    /// otherwise the fixed-size `.#<image_attr>` output (backward compatible).
    pub fn new(cfg: &Config) -> Self {
        let (size, title) = if cfg.host_attr.is_some() {
            (
                SizeOverride::Gib(MINIMAL_IMAGE_GIB),
                format!(
                    "Build image — minimal reusable {MINIMAL_IMAGE_GIB} GiB (flash to any stick, grows to fill)"
                ),
            )
        } else {
            (
                SizeOverride::Fixed,
                format!("Build image — fixed .#{}", cfg.image_attr),
            )
        };
        BuildScreen {
            phase: Phase::PassFirst {
                buf: String::new(),
                error: None,
            },
            steps: [StepState::Pending; STEP_NAMES.len()],
            log: Vec::new(),
            scroll: 0,
            follow: true,
            rx: None,
            message: None,
            session_log: None,
            size,
            title,
        }
    }

    pub fn is_running(&self) -> bool {
        matches!(self.phase, Phase::Running)
    }

    /// Pull everything the worker produced since the last frame, teeing every
    /// event into the session log — the file gets exactly what this pane shows.
    pub fn drain_events(&mut self, slog: &mut crate::logging::SessionLog) {
        let Some(rx) = &self.rx else { return };
        let mut done: Option<Result<PathBuf, String>> = None;
        while let Ok(ev) = rx.try_recv() {
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
            self.rx = None;
            match result {
                Ok(img) => {
                    let msg = format!("Built image: {}", img.display());
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
    let Some(st) = app.build.as_mut() else { return };
    match &mut st.phase {
        Phase::PassFirst { buf, .. } => match key.code {
            KeyCode::Esc => {
                app.build = None;
                app.screen = Screen::Home;
            }
            KeyCode::Enter => {
                // Take the buffer FIRST so the borrow of `st.phase` through `buf`
                // is dead before we replace the phase.
                let taken = std::mem::take(buf);
                st.phase = if taken.is_empty() {
                    Phase::PassFirst {
                        buf: String::new(),
                        error: Some("Passphrase must not be empty".into()),
                    }
                } else {
                    Phase::PassConfirm {
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
        Phase::PassConfirm { first, buf } => match key.code {
            KeyCode::Esc => {
                app.build = None;
                app.screen = Screen::Home;
            }
            KeyCode::Enter => {
                let first = std::mem::take(first);
                let second = std::mem::take(buf);
                if first == second {
                    // Passphrase accepted — hand it to the worker and start the
                    // pipeline. The worker owns the RAM-file + shred lifecycle.
                    // The action is real from here: open its session-log file
                    // (the passphrase itself never enters the event stream,
                    // so it can never reach the file — see logging.rs).
                    st.session_log = app.log.begin("build");
                    st.phase = Phase::Running;
                    st.rx = Some(crate::build::spawn_build(
                        app.config_path.clone(),
                        app.cfg.clone(),
                        first,
                        st.size,
                    ));
                } else {
                    st.phase = Phase::PassFirst {
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
        Phase::Running => match key.code {
            // Esc is deliberately inert: backing out would orphan the pipeline.
            // Log scrolling is the only interaction while the build runs.
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
                app.build = None;
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
    let Some(st) = app.build.as_mut() else { return };
    let log_path = st.session_log.as_ref().map(|p| p.display().to_string());
    // Two message rows: the outcome line plus the session-log path under it.
    let [main_area, message_area, footer_area] = Layout::vertical([
        Constraint::Min(8),
        Constraint::Length(2),
        Constraint::Length(1),
    ])
    .areas(f.area());
    draw_build_body(
        f,
        main_area,
        &st.title,
        &st.steps,
        &st.log,
        &mut st.scroll,
        st.follow,
    );

    if let Some(msg) = &st.message {
        let ok = matches!(st.phase, Phase::Done { ok: true });
        let mut lines = vec![Line::from(Span::styled(
            format!(" {msg}"),
            Style::default()
                .fg(if ok { OK } else { ERR })
                .add_modifier(Modifier::BOLD),
        ))];
        if let Some(p) = &log_path {
            lines.push(Line::from(Span::styled(
                format!(" log: {p}"),
                Style::default().fg(DIM),
            )));
        }
        f.render_widget(
            Paragraph::new(lines).wrap(Wrap { trim: true }),
            message_area,
        );
    }

    match st.phase {
        Phase::Running => {
            let mut hints = vec![
                ("↑↓/PgUp/PgDn", "scroll log"),
                ("End", "follow"),
                ("", "build running — Esc disabled"),
            ];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        Phase::Done { .. } => {
            let mut hints = vec![
                ("↑↓/PgUp/PgDn", "scroll log"),
                ("Esc/Enter", "back to menu"),
            ];
            if let Some(p) = &log_path {
                hints.push(("log", p.as_str()));
            }
            ui::footer(f, footer_area, &hints);
        }
        _ => ui::footer(
            f,
            footer_area,
            &[("Enter", "confirm"), ("Esc", "cancel build")],
        ),
    }

    // Passphrase modal floats over the (still pending) checklist.
    match &st.phase {
        Phase::PassFirst { buf, error } => {
            draw_pass_modal(f, "LUKS store passphrase", buf, error.as_deref(), false);
        }
        Phase::PassConfirm { buf, .. } => {
            draw_pass_modal(f, "Confirm passphrase", buf, None, true);
        }
        _ => {}
    }
}

/// Crate-visible: the two-pane build body (step checklist beside a scrolling log window).
/// Reused by the "Build & Flash" pathway during its build phase. Clamps `scroll` to the
/// tail when `follow` is on.
pub(crate) fn draw_build_body(
    f: &mut Frame,
    area: ratatui::layout::Rect,
    steps_title: &str,
    steps: &[StepState],
    log: &[String],
    scroll: &mut usize,
    follow: bool,
) {
    let [steps_area, log_area] =
        Layout::horizontal([Constraint::Length(44), Constraint::Min(20)]).areas(area);

    // Step checklist.
    let items: Vec<ListItem> = STEP_NAMES
        .iter()
        .zip(steps.iter())
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
    f.render_widget(List::new(items).block(ui::panel(steps_title)), steps_area);

    // Log pane: render only the visible window (the log can be 10k lines).
    let log_block = ui::panel(if follow { "Log (following)" } else { "Log" });
    let visible_height = log_block.inner(log_area).height as usize;
    let max_scroll = log.len().saturating_sub(visible_height);
    if follow {
        *scroll = max_scroll;
    } else {
        *scroll = (*scroll).min(max_scroll);
    }
    let window: Vec<Line> = log
        .iter()
        .skip(*scroll)
        .take(visible_height)
        .map(|l| Line::from(l.as_str()))
        .collect();
    f.render_widget(Paragraph::new(window).block(log_block), log_area);
}

pub(crate) fn draw_pass_modal(
    f: &mut Frame,
    title: &str,
    buf: &str,
    error: Option<&str>,
    confirming: bool,
) {
    let area = ui::centered_rect(f.area(), 62, 7);
    let inner = ui::modal(f, area, title);
    let [text_area, input_area, error_area] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);
    let prompt = if confirming {
        "Type the passphrase again to confirm."
    } else {
        "Unlocks the encrypted store at boot. Held in a RAM-backed 0600 file \
         during the build, zeroed afterwards."
    };
    f.render_widget(
        Paragraph::new(prompt)
            .style(Style::default().fg(DIM))
            .wrap(Wrap { trim: true }),
        text_area,
    );
    f.render_widget(
        Paragraph::new(ui::input_line(buf, true)).style(Style::default().fg(Color::White)),
        input_area,
    );
    if let Some(e) = error {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(e, Style::default().fg(WARN)))),
            error_area,
        );
    }
}
