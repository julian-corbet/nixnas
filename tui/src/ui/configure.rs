//! CONFIGURE — the nixnas.config fields as a navigable form. Path fields open a
//! filesystem browser modal; text/number fields edit inline. The machine's actual
//! configuration is Nix (in the operator's flake) — this form only edits what the
//! TUI itself consumes (see config.rs).

use crate::config::{config_dir, Config};
use crate::ui::{self, ACCENT, DIM, ERR, OK, WARN};
use crate::{App, Screen};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq)]
enum FieldKind {
    /// Browser picks a directory.
    DirPath,
    /// Browser picks a file.
    FilePath,
    Text,
    Number,
}

struct FieldMeta {
    label: &'static str,
    kind: FieldKind,
    /// May be cleared to empty ("use the default / none").
    optional: bool,
    help: &'static str,
}

const FIELDS: [FieldMeta; 4] = [
    FieldMeta {
        label: "flake_dir",
        kind: FieldKind::DirPath,
        optional: false,
        help: "Directory holding the flake that composes nixnas (the private host \
               overlay). Relative paths resolve against this config file's directory.",
    },
    FieldMeta {
        label: "sb_keys_sops",
        kind: FieldKind::FilePath,
        optional: true,
        help: "Optional sops-encrypted tar of the Secure Boot PKI directory (sbctl \
               layout: PK/KEK/db keypairs), injected at build time so the box signs \
               UKIs with a STABLE operator identity across reflashes. Empty = \
               lanzaboote autogenerates keys on first boot (identity changes on \
               every reflash).",
    },
    FieldMeta {
        label: "image_attr",
        kind: FieldKind::Text,
        optional: false,
        help: "The flake attribute that builds the STICK image script (`nix build \
               .#<attr>`). Default `imageScript`. A hot-mode setup names its RESCUE \
               image attribute here — the hot MAIN is never flashed.",
    },
    FieldMeta {
        label: "build_memory_mib",
        kind: FieldKind::Number,
        optional: true,
        help: "MiB of RAM for the disko image-builder VM. Empty = disko's default.",
    },
];

pub struct ConfigureState {
    /// Field values as edit buffers; empty string = None for optional fields.
    values: [String; 4],
    selected: usize,
    edit: Option<EditState>,
    browser: Option<Browser>,
    /// (message, is_error) — save confirmations and validation complaints.
    notice: Option<(String, bool)>,
    dirty: bool,
}

struct EditState {
    buf: String,
}

impl ConfigureState {
    pub fn from_config(cfg: &Config) -> Self {
        ConfigureState {
            values: [
                cfg.flake_dir.clone(),
                cfg.sb_keys_sops.clone().unwrap_or_default(),
                cfg.image_attr.clone(),
                cfg.build_memory_mib
                    .map(|m| m.to_string())
                    .unwrap_or_default(),
            ],
            selected: 0,
            edit: None,
            browser: None,
            notice: None,
            dirty: false,
        }
    }

    /// Validate the buffers into a Config, or say what is wrong.
    fn to_config(&self) -> Result<Config, String> {
        let mem = self.values[3].trim();
        let build_memory_mib =
            if mem.is_empty() {
                None
            } else {
                Some(mem.parse::<u32>().map_err(|_| {
                    format!("build_memory_mib: `{mem}` is not a whole number of MiB")
                })?)
            };
        let flake_dir = self.values[0].trim();
        let image_attr = self.values[2].trim();
        Ok(Config {
            // Empty inputs fall back to the documented defaults rather than
            // serialising unusable empty strings.
            flake_dir: if flake_dir.is_empty() {
                ".".to_string()
            } else {
                flake_dir.to_string()
            },
            sb_keys_sops: {
                let s = self.values[1].trim();
                if s.is_empty() {
                    None
                } else {
                    Some(s.to_string())
                }
            },
            image_attr: if image_attr.is_empty() {
                "imageScript".to_string()
            } else {
                image_attr.to_string()
            },
            build_memory_mib,
        })
    }
}

// ---------------------------------------------------------------------------
// Filesystem browser modal
// ---------------------------------------------------------------------------

struct Browser {
    /// Which form field receives the picked path.
    field: usize,
    pick_dir: bool,
    cwd: PathBuf,
    /// (name, is_dir), dirs first, alpha within — before filtering.
    entries: Vec<(String, bool)>,
    selected: usize,
    show_hidden: bool,
    filter: String,
}

impl Browser {
    fn new(field: usize, pick_dir: bool, start: PathBuf) -> Self {
        let mut b = Browser {
            field,
            pick_dir,
            cwd: start,
            entries: Vec::new(),
            selected: 0,
            show_hidden: false,
            filter: String::new(),
        };
        b.reread();
        b
    }

    fn reread(&mut self) {
        self.entries.clear();
        if let Ok(rd) = std::fs::read_dir(&self.cwd) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if !self.show_hidden && name.starts_with('.') {
                    continue;
                }
                // Follow symlinks for the dir/file distinction (path().is_dir does).
                self.entries.push((name, e.path().is_dir()));
            }
        }
        self.entries.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then(a.0.to_lowercase().cmp(&b.0.to_lowercase()))
        });
        self.selected = 0;
    }

    /// Indices into `entries` that survive the type-to-filter.
    fn visible(&self) -> Vec<usize> {
        let needle = self.filter.to_lowercase();
        self.entries
            .iter()
            .enumerate()
            .filter(|(_, (name, _))| needle.is_empty() || name.to_lowercase().contains(&needle))
            .map(|(i, _)| i)
            .collect()
    }

    /// Rows as listed: in dir-pick mode a synthetic "use this directory" row sits
    /// on top — Enter on a real directory always DESCENDS, so selecting the cwd
    /// itself needs its own row rather than an extra keybinding.
    fn row_count(&self) -> usize {
        self.visible().len() + usize::from(self.pick_dir)
    }

    fn descend(&mut self, name: &str) {
        self.cwd = self.cwd.join(name);
        self.filter.clear();
        self.reread();
    }

    fn ascend(&mut self) {
        if let Some(parent) = self.cwd.parent() {
            self.cwd = parent.to_path_buf();
            self.filter.clear();
            self.reread();
        }
    }
}

/// Where the browser opens: the field's current value if it points somewhere real
/// (a file's parent for file fields), else the config's directory.
fn browser_start(value: &str, config_path: &Path) -> PathBuf {
    let base = config_dir(config_path);
    let candidate = {
        let p = Path::new(value.trim());
        if value.trim().is_empty() {
            base.clone()
        } else if p.is_absolute() {
            p.to_path_buf()
        } else {
            base.join(p)
        }
    };
    let dir = if candidate.is_dir() {
        candidate
    } else if candidate.is_file() {
        candidate.parent().map(Path::to_path_buf).unwrap_or(base)
    } else {
        base
    };
    // Canonical so the picked value is an unambiguous absolute path.
    std::fs::canonicalize(&dir).unwrap_or(dir)
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

pub fn on_key(app: &mut App, key: KeyEvent) {
    let config_path = app.config_path.clone();
    let Some(st) = app.configure.as_mut() else {
        return;
    };

    // Modal precedence: browser, then inline edit, then the form itself.
    if st.browser.is_some() {
        browser_key(st, key);
        return;
    }
    if let Some(edit) = st.edit.as_mut() {
        match key.code {
            KeyCode::Esc => st.edit = None,
            KeyCode::Enter => {
                st.values[st.selected] = edit.buf.trim().to_string();
                st.dirty = true;
                st.edit = None;
            }
            KeyCode::Backspace => {
                edit.buf.pop();
            }
            KeyCode::Char(c) => edit.buf.push(c),
            _ => {}
        }
        return;
    }

    match key.code {
        KeyCode::Esc => {
            // Discarding is explicit in the footer; no nag modal.
            app.configure = None;
            app.screen = Screen::Home;
        }
        KeyCode::Up | KeyCode::Char('k') => {
            st.selected = st.selected.checked_sub(1).unwrap_or(FIELDS.len() - 1);
        }
        KeyCode::Down | KeyCode::Char('j') => st.selected = (st.selected + 1) % FIELDS.len(),
        KeyCode::Enter => match FIELDS[st.selected].kind {
            FieldKind::DirPath | FieldKind::FilePath => {
                st.browser = Some(Browser::new(
                    st.selected,
                    FIELDS[st.selected].kind == FieldKind::DirPath,
                    browser_start(&st.values[st.selected], &config_path),
                ));
            }
            FieldKind::Text | FieldKind::Number => {
                st.edit = Some(EditState {
                    buf: st.values[st.selected].clone(),
                });
            }
        },
        // Path fields are browser-first, but typing a path by hand must stay possible.
        KeyCode::Char('e') => {
            st.edit = Some(EditState {
                buf: st.values[st.selected].clone(),
            })
        }
        KeyCode::Char('d') | KeyCode::Delete => {
            if FIELDS[st.selected].optional {
                st.values[st.selected].clear();
                st.dirty = true;
            }
        }
        KeyCode::Char('s') => match st.to_config() {
            Ok(cfg) => match cfg.save(&config_path) {
                Ok(()) => {
                    st.notice = Some((format!("Saved {}", config_path.display()), false));
                    st.dirty = false;
                    app.cfg = cfg;
                }
                Err(e) => st.notice = Some((format!("{e:#}"), true)),
            },
            Err(msg) => st.notice = Some((msg, true)),
        },
        _ => {}
    }
}

fn browser_key(st: &mut ConfigureState, key: KeyEvent) {
    let Some(b) = st.browser.as_mut() else { return };
    match key.code {
        KeyCode::Esc => st.browser = None,
        KeyCode::Up => b.selected = b.selected.saturating_sub(1),
        KeyCode::Down => {
            b.selected = (b.selected + 1).min(b.row_count().saturating_sub(1));
        }
        KeyCode::Backspace => {
            // Backspace erases the filter first; only an empty filter goes up a
            // directory — matching what the fingers expect while type-filtering.
            if b.filter.pop().is_none() {
                b.ascend();
            } else {
                b.selected = 0;
            }
        }
        KeyCode::Enter => {
            let visible = b.visible();
            let mut picked: Option<PathBuf> = None;
            if b.pick_dir && b.selected == 0 {
                picked = Some(b.cwd.clone());
            } else {
                let idx = b.selected - usize::from(b.pick_dir);
                if let Some(&entry) = visible.get(idx) {
                    let (name, is_dir) = b.entries[entry].clone();
                    if is_dir {
                        b.descend(&name);
                    } else if !b.pick_dir {
                        picked = Some(b.cwd.join(name));
                    }
                }
            }
            if let Some(path) = picked {
                let field = b.field;
                st.values[field] = path.display().to_string();
                st.dirty = true;
                st.browser = None;
            }
        }
        // '.' is the hidden-files toggle by contract, so it is NOT typeable into
        // the filter — hidden entries are found by toggling, not by typing dots.
        KeyCode::Char('.') => {
            b.show_hidden = !b.show_hidden;
            b.reread();
        }
        KeyCode::Char(c) if !c.is_control() => {
            b.filter.push(c);
            b.selected = if b.pick_dir { 1 } else { 0 };
        }
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

pub fn draw(f: &mut Frame, app: &mut App) {
    let Some(st) = app.configure.as_mut() else {
        return;
    };
    let [form_area, help_area, notice_area, footer_area] = Layout::vertical([
        Constraint::Length(FIELDS.len() as u16 + 2),
        Constraint::Min(4),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(f.area());

    // The form: one row per field, the edited field shows its live buffer.
    let items: Vec<ListItem> = FIELDS
        .iter()
        .enumerate()
        .map(|(i, meta)| {
            let editing = st.edit.is_some() && i == st.selected;
            let mut spans = vec![Span::styled(
                format!("  {:<18}", meta.label),
                Style::default().fg(ACCENT),
            )];
            if editing {
                spans.extend(ui::input_line(&st.edit.as_ref().unwrap().buf, false).spans);
            } else if st.values[i].is_empty() {
                let placeholder = match meta.kind {
                    FieldKind::FilePath => "(none — autogenerate on first boot)",
                    FieldKind::Number => "(default)",
                    _ => "(empty)",
                };
                spans.push(Span::styled(placeholder, Style::default().fg(DIM)));
            } else {
                spans.push(Span::styled(
                    st.values[i].clone(),
                    Style::default().fg(Color::White),
                ));
            }
            ListItem::new(Line::from(spans))
        })
        .collect();
    let mut state = ListState::default();
    state.select(Some(st.selected));
    let title = if st.dirty {
        "Configure — unsaved changes"
    } else {
        "Configure"
    };
    f.render_stateful_widget(
        List::new(items)
            .block(ui::panel(title))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED)),
        form_area,
        &mut state,
    );

    // Context-sensitive help for the selected field.
    f.render_widget(
        Paragraph::new(FIELDS[st.selected].help)
            .style(Style::default().fg(DIM))
            .wrap(Wrap { trim: true })
            .block(ui::panel("About this field")),
        help_area,
    );

    if let Some((msg, is_err)) = &st.notice {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(" {msg}"),
                Style::default().fg(if *is_err { ERR } else { OK }),
            ))),
            notice_area,
        );
    }

    if st.edit.is_some() {
        ui::footer(
            f,
            footer_area,
            &[("Enter", "apply"), ("Esc", "cancel edit")],
        );
    } else {
        ui::footer(
            f,
            footer_area,
            &[
                ("↑↓", "field"),
                ("Enter", "browse/edit"),
                ("e", "edit as text"),
                ("d", "clear"),
                ("s", "save"),
                ("Esc", "back (discard)"),
            ],
        );
    }

    // The browser floats above everything.
    if st.browser.is_some() {
        draw_browser(f, st);
    }
}

fn draw_browser(f: &mut Frame, st: &mut ConfigureState) {
    let Some(b) = st.browser.as_mut() else { return };
    let area = f.area();
    let modal_area = ui::centered_rect(
        area,
        (area.width * 4 / 5).max(40),
        (area.height * 4 / 5).max(12),
    );
    let title = if b.pick_dir {
        "Pick a directory"
    } else {
        "Pick a file"
    };
    let inner = ui::modal(f, modal_area, title);
    let [path_area, list_area, hint_area]: [Rect; 3] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .areas(inner);

    // Current location + live filter.
    let mut path_spans = vec![
        Span::styled(" ", Style::default()),
        Span::styled(b.cwd.display().to_string(), Style::default().fg(ACCENT)),
    ];
    if !b.filter.is_empty() {
        path_spans.push(Span::styled(
            format!("   filter: {}", b.filter),
            Style::default().fg(WARN),
        ));
    }
    f.render_widget(Paragraph::new(Line::from(path_spans)), path_area);

    let visible = b.visible();
    b.selected = b.selected.min(b.row_count().saturating_sub(1));
    let mut items: Vec<ListItem> = Vec::with_capacity(visible.len() + 1);
    if b.pick_dir {
        items.push(ListItem::new(Line::from(Span::styled(
            "▸ [ use this directory ]",
            Style::default().fg(OK).add_modifier(Modifier::BOLD),
        ))));
    }
    for &i in &visible {
        let (name, is_dir) = &b.entries[i];
        items.push(ListItem::new(Line::from(if *is_dir {
            Span::styled(format!("{name}/"), Style::default().fg(ACCENT))
        } else if b.pick_dir {
            // Files are inert context when picking a directory.
            Span::styled(name.clone(), Style::default().fg(DIM))
        } else {
            Span::styled(name.clone(), Style::default().fg(Color::White))
        })))
    }
    if items.is_empty() {
        items.push(ListItem::new(Line::from(Span::styled(
            "(empty)",
            Style::default().fg(DIM),
        ))));
    }
    let mut state = ListState::default();
    state.select(Some(b.selected));
    f.render_stateful_widget(
        List::new(items).highlight_style(Style::default().add_modifier(Modifier::REVERSED)),
        list_area,
        &mut state,
    );

    ui::footer(
        f,
        hint_area,
        &[
            ("↑↓", "move"),
            (
                "Enter",
                if b.pick_dir {
                    "descend/select"
                } else {
                    "descend/pick"
                },
            ),
            ("⌫", "filter/up"),
            (".", "hidden"),
            ("type", "filter"),
            ("Esc", "close"),
        ],
    );
}
