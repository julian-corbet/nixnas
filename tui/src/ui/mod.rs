//! Shared drawing vocabulary for the nixnas screens: theme, panel blocks, footer
//! keybind bar, centered modals. Every screen draws inside the same dark,
//! cyan-accented frame so the tool reads as ONE appliance, not four dialogs.

pub mod build;
pub mod configure;
pub mod flash;
pub mod home;

use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use ratatui::Frame;

// The palette: dark terminal background, cyan/blue accents. Deliberately no
// warm/cream tones anywhere.
pub const ACCENT: Color = Color::Cyan;
pub const OK: Color = Color::Green;
pub const WARN: Color = Color::Yellow;
pub const ERR: Color = Color::Red;
pub const DIM: Color = Color::DarkGray;

pub fn draw(f: &mut Frame, app: &mut crate::App) {
    match app.screen {
        crate::Screen::Home => home::draw(f, app),
        crate::Screen::Configure => configure::draw(f, app),
        crate::Screen::Build => build::draw(f, app),
        crate::Screen::Flash => flash::draw(f, app),
    }
}

/// Bordered panel with its title in the accent colour.
pub fn panel(title: &str) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(DIM))
        .title(Span::styled(
            format!(" {title} "),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ))
}

/// One-line key legend. Every screen states its complete key vocabulary here —
/// nothing is only discoverable by accident.
pub fn footer(f: &mut Frame, area: Rect, hints: &[(&str, &str)]) {
    let mut spans = vec![Span::raw(" ")];
    for (key, desc) in hints {
        spans.push(Span::styled(
            format!(" {key} "),
            Style::default().fg(Color::Black).bg(ACCENT),
        ));
        spans.push(Span::styled(format!(" {desc}  "), Style::default().fg(DIM)));
    }
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Fixed-size rect centered in `area`, clamped to fit small terminals.
pub fn centered_rect(area: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(area.width);
    let h = height.min(area.height);
    Rect {
        x: area.x + (area.width - w) / 2,
        y: area.y + (area.height - h) / 2,
        width: w,
        height: h,
    }
}

/// Clear the backdrop under a modal and draw its frame; returns the inner area.
/// Modals get an ACCENT border so they visibly float above the dim-bordered panels.
pub fn modal(f: &mut Frame, area: Rect, title: &str) -> Rect {
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ACCENT))
        .title(Span::styled(
            format!(" {title} "),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    f.render_widget(block, area);
    inner
}

/// An input line with a block cursor at the end; `mask` hides the typed content
/// (passphrases). The cursor is drawn, not the terminal's — the app never leaves
/// the alternate-screen/raw-mode world.
pub fn input_line(content: &str, mask: bool) -> Line<'static> {
    let shown = if mask {
        "\u{2022}".repeat(content.chars().count())
    } else {
        content.to_string()
    };
    Line::from(vec![
        Span::styled(shown, Style::default().fg(Color::White)),
        Span::styled("\u{2588}", Style::default().fg(ACCENT)),
    ])
}
