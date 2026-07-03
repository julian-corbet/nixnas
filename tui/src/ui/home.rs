//! HOME — the appliance front door: banner, live environment status, main menu.

use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
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

const MENU: [(&str, &str); 4] = [
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
    ("Quit", "leave nixnas"),
];

#[derive(Default)]
pub struct HomeState {
    pub selected: usize,
}

pub fn on_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Up | KeyCode::Char('k') => {
            app.home.selected = app.home.selected.checked_sub(1).unwrap_or(MENU.len() - 1);
        }
        KeyCode::Down | KeyCode::Char('j') => {
            app.home.selected = (app.home.selected + 1) % MENU.len();
        }
        KeyCode::Char('q') => app.quit = true,
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
            _ => app.quit = true,
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
                    format!("  {name:<12}"),
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
