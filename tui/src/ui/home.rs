//! HOME — the appliance front door: banner, live environment status, main menu.
//! It also owns the quit path, and with it the session-log exit prompt: clean
//! by default, keep only on request (for inspecting a failed run).

use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;
use std::path::Path;

// Block-letter banner ("ANSI shadow" style) — the one splash of personality.
const BANNER: [&str; 6] = [
    "███╗   ██╗██╗██╗  ██╗███╗   ██╗ █████╗ ███████╗",
    "████╗  ██║██║╚██╗██╔╝████╗  ██║██╔══██╗██╔════╝",
    "██╔██╗ ██║██║ ╚███╔╝ ██╔██╗ ██║███████║███████╗",
    "██║╚██╗██║██║ ██╔██╗ ██║╚██╗██║██╔══██║╚════██║",
    "██║ ╚████║██║██╔╝ ██╗██║ ╚████║██║  ██║███████║",
    "╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝",
];

const MENU: [(&str, &str); 6] = [
    (
        "Configure",
        "edit nixnas.config (flake location, Secure Boot PKI, build knobs)",
    ),
    (
        "Build image",
        "build the personalised .raw locally via Nix + disko",
    ),
    (
        "Flash stick",
        "write the built image to a USB stick (typed confirmation)",
    ),
    (
        "Verify image",
        "read-only checks of the built .raw (GPT, boot chain, LUKS2, digest)",
    ),
    (
        "Verify install",
        "the same read-only checks against a flashed device",
    ),
    ("Quit", "leave nixnas"),
];

#[derive(Default)]
pub struct HomeState {
    pub selected: usize,
    /// The quit-time "clean or keep the session logs" modal is open.
    pub exit_prompt: bool,
}

/// Quit — or, when this run wrote session logs, ask what to do with them
/// first. Ctrl+C (handled in main.rs) bypasses the prompt by design.
fn request_quit(app: &mut App) {
    if app.log.has_files() {
        app.home.exit_prompt = true;
    } else {
        app.quit = true;
    }
}

pub fn on_key(app: &mut App, key: KeyEvent) {
    // The exit modal owns the keyboard while open. CLEAN is the default —
    // Enter, C and even Esc all take it; K is the deliberate choice for a run
    // worth inspecting. (Ctrl+C never reaches here — main.rs exits instantly,
    // leaving the files on disk.)
    if app.home.exit_prompt {
        match key.code {
            KeyCode::Enter | KeyCode::Esc | KeyCode::Char('c') | KeyCode::Char('C') => {
                app.log.clean();
                app.quit = true;
            }
            KeyCode::Char('k') | KeyCode::Char('K') => {
                app.log.keep_and_prune();
                app.quit = true;
            }
            _ => {}
        }
        return;
    }
    match key.code {
        KeyCode::Up | KeyCode::Char('k') => {
            app.home.selected = app.home.selected.checked_sub(1).unwrap_or(MENU.len() - 1);
        }
        KeyCode::Down | KeyCode::Char('j') => {
            app.home.selected = (app.home.selected + 1) % MENU.len();
        }
        KeyCode::Char('q') => request_quit(app),
        KeyCode::Enter => match app.home.selected {
            0 => {
                app.configure = Some(ui::configure::ConfigureState::from_config(&app.cfg));
                app.screen = Screen::Configure;
            }
            1 => {
                // Re-entering while a build runs must show THAT build, not start
                // a second one; a finished screen is replaced by a fresh prompt.
                if app.build.as_ref().is_none_or(|b| !b.is_running()) {
                    app.build = Some(ui::build::BuildScreen::new());
                }
                app.screen = Screen::Build;
            }
            2 => {
                if app.flash.as_ref().is_none_or(|f| !f.is_running()) {
                    app.flash = Some(ui::flash::FlashScreen::new(&app.config_path));
                }
                app.screen = Screen::Flash;
            }
            // Both verify entries share one screen slot: a RUNNING verification
            // is shown as-is whichever entry was chosen (never orphan a worker);
            // a finished one is replaced by the freshly requested mode.
            3 => {
                if app.verify.as_ref().is_none_or(|v| !v.is_running()) {
                    let mut screen = ui::verify::VerifyScreen::new_image(&app.config_path);
                    // The image verify spawns its worker in the constructor —
                    // open the session log only when it actually started (a
                    // missing image is still browsing, not an action).
                    if screen.is_running() {
                        screen.session_log = app.log.begin("verify-image");
                    }
                    app.verify = Some(screen);
                }
                app.screen = Screen::Verify;
            }
            4 => {
                if app.verify.as_ref().is_none_or(|v| !v.is_running()) {
                    app.verify = Some(ui::verify::VerifyScreen::new_install(&app.config_path));
                }
                app.screen = Screen::Verify;
            }
            _ => request_quit(app),
        },
        _ => {}
    }
}

pub fn draw(f: &mut Frame, app: &mut App) {
    let [banner_area, status_area, menu_area, footer_area] = Layout::vertical([
        Constraint::Length(BANNER.len() as u16 + 1),
        Constraint::Length(8),
        Constraint::Min(MENU.len() as u16 + 2),
        Constraint::Length(1),
    ])
    .areas(f.area());

    // Banner + tagline.
    let mut lines: Vec<Line> = BANNER
        .iter()
        .map(|l| Line::from(Span::styled(*l, Style::default().fg(ACCENT))).centered())
        .collect();
    lines.push(
        Line::from(Span::styled(
            "NixOS storage appliance — provision a stick",
            Style::default().fg(DIM),
        ))
        .centered(),
    );
    f.render_widget(Paragraph::new(lines), banner_area);

    // Status panel: everything the three actions depend on, verified live.
    f.render_widget(
        Paragraph::new(status_lines(app)).block(ui::panel("Status")),
        status_area,
    );

    // Main menu.
    let items: Vec<ListItem> = MENU
        .iter()
        .map(|(name, desc)| {
            ListItem::new(Line::from(vec![
                Span::styled(
                    format!("  {name:<16}"),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(*desc, Style::default().fg(DIM)),
            ]))
        })
        .collect();
    let mut state = ListState::default();
    state.select(Some(app.home.selected));
    f.render_stateful_widget(
        List::new(items)
            .block(ui::panel("Menu"))
            .highlight_style(Style::default().fg(Color::Black).bg(ACCENT))
            .highlight_symbol("▸"),
        menu_area,
        &mut state,
    );

    ui::footer(
        f,
        footer_area,
        &[("↑↓", "select"), ("Enter", "open"), ("q", "quit")],
    );

    // Quit-time modal: what happens to THIS run's session logs.
    if app.home.exit_prompt {
        draw_exit_modal(f, app);
    }
}

/// Centered exit prompt over the HOME screen. Clean is the DEFAULT (the tool
/// is tidy by default); Keep exists for inspecting a failed run and prunes
/// the directory to the newest files (see logging.rs).
fn draw_exit_modal(f: &mut Frame, app: &App) {
    let n = app.log.count();
    let area = ui::centered_rect(f.area(), 66, 7);
    let inner = ui::modal(f, area, &format!("Session logs ({n})"));
    let dir = app
        .log
        .dir()
        .map(|d| d.display().to_string())
        .unwrap_or_default();
    let lines = vec![
        Line::from(vec![
            Span::styled(
                format!("This run wrote {n} log file(s) under "),
                Style::default().fg(Color::White),
            ),
            Span::styled(dir, Style::default().fg(DIM)),
        ]),
        Line::default(),
        Line::from(vec![
            Span::styled(
                " C/Enter/Esc ",
                Style::default().fg(Color::Black).bg(ACCENT),
            ),
            Span::styled(" clean (default)   ", Style::default().fg(Color::White)),
            Span::styled(" K ", Style::default().fg(Color::Black).bg(ACCENT)),
            Span::styled(
                format!(" keep (dir pruned to newest {})", crate::logging::RETAIN),
                Style::default().fg(Color::White),
            ),
        ]),
    ];
    f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), inner);
}

/// One line per fact; ✓/✗ verified against the filesystem on every frame (cheap
/// stat calls — an installer, not a benchmark).
fn status_lines(app: &App) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let value = |s: String| Span::styled(s, Style::default().fg(Color::White));
    let label = |s: &str| Span::styled(format!("  {s:<18}"), Style::default().fg(DIM));
    let check = |ok: bool, ok_txt: &str, bad_txt: &str| {
        if ok {
            Span::styled(format!("  ✓ {ok_txt}"), Style::default().fg(OK))
        } else {
            Span::styled(format!("  ✗ {bad_txt}"), Style::default().fg(WARN))
        }
    };

    let cfg_exists = app.config_path.exists();
    lines.push(Line::from(vec![
        label("Config file"),
        value(app.config_path.display().to_string()),
        check(cfg_exists, "found", "not created yet (defaults in effect)"),
    ]));

    let flake = app.cfg.resolved_flake_dir(&app.config_path);
    lines.push(Line::from(vec![
        label("Flake dir"),
        value(flake.display().to_string()),
        check(
            flake.join("flake.nix").is_file(),
            "flake.nix",
            "no flake.nix",
        ),
    ]));

    lines.push(Line::from(vec![
        label("Image attr"),
        value(format!(".#{}", app.cfg.image_attr)),
    ]));

    match &app.cfg.sb_keys_sops {
        Some(p) => {
            let resolved = if Path::new(p).is_absolute() {
                Path::new(p).to_path_buf()
            } else {
                crate::config::config_dir(&app.config_path).join(p)
            };
            lines.push(Line::from(vec![
                label("SB PKI (sops)"),
                value(p.clone()),
                check(resolved.is_file(), "present", "FILE MISSING"),
            ]));
        }
        None => lines.push(Line::from(vec![
            label("SB PKI (sops)"),
            Span::styled(
                "none — keys autogenerate on first boot",
                Style::default().fg(DIM),
            ),
        ])),
    }

    match crate::flash::find_image(&app.config_path) {
        Ok(img) => {
            let size = std::fs::metadata(&img).map(|m| m.len()).unwrap_or(0);
            lines.push(Line::from(vec![
                label("Built image"),
                value(format!(
                    "{} ({})",
                    img.display(),
                    crate::flash::human_size(size)
                )),
            ]));
        }
        Err(_) => lines.push(Line::from(vec![
            label("Built image"),
            Span::styled("none yet — run Build image", Style::default().fg(DIM)),
        ])),
    }

    let kvm = Path::new("/dev/kvm").exists();
    lines.push(Line::from(vec![
        label("/dev/kvm"),
        if kvm {
            Span::styled(
                "✓ present (disko builder VM will be fast)",
                Style::default().fg(OK),
            )
        } else {
            Span::styled(
                "✗ missing — the builder VM cannot run",
                Style::default().fg(ERR),
            )
        },
    ]));

    lines
}
