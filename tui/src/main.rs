//! nixnas — a small, guided TUI to configure, build, and flash a nixnas USB stick.
//!
//! Deliberately narrow scope: it does NOT do updates. A running nixnas updates itself
//! the Nix way (writes its inactive A/B slot). This tool only PROVISIONS a fresh
//! stick: edit config -> build the personalised image LOCALLY -> optionally back the
//! current stick up -> overwrite it.

mod build;
mod config;
mod flash;

use anyhow::Result;
use config::Config;
use dialoguer::{theme::ColorfulTheme, Confirm, Input, Select};
use std::path::{Path, PathBuf};

fn main() -> Result<()> {
    let config_path = PathBuf::from(
        std::env::args().nth(1).unwrap_or_else(|| "nixnas.config".to_string()),
    );
    let mut cfg = Config::load(&config_path)?;
    let theme = ColorfulTheme::default();

    loop {
        let choice = Select::with_theme(&theme)
            .with_prompt("nixnas")
            .items(&["Edit config", "Build image (local)", "Flash to USB stick", "Quit"])
            .default(0)
            .interact()?;

        match choice {
            0 => edit_config(&theme, &mut cfg, &config_path)?,
            1 => {
                let img = build::build_image(&config_path)?;
                println!("Built image: {}", img.display());
            }
            2 => flash::flash(&theme, &config_path)?,
            _ => break,
        }
    }
    Ok(())
}

/// v0 config editor: the top-level fields inline. The schema-aware ratatui form
/// (covering every `nixnas.config` field) is the next iteration.
fn edit_config(theme: &ColorfulTheme, cfg: &mut Config, path: &Path) -> Result<()> {
    cfg.host_name = Input::with_theme(theme)
        .with_prompt("Hostname")
        .with_initial_text(cfg.host_name.clone())
        .interact_text()?;
    cfg.hot.name = Input::with_theme(theme)
        .with_prompt("HOT pool name (SSD)")
        .with_initial_text(cfg.hot.name.clone())
        .interact_text()?;
    cfg.cold.name = Input::with_theme(theme)
        .with_prompt("COLD pool name (HDD)")
        .with_initial_text(cfg.cold.name.clone())
        .interact_text()?;
    cfg.secure_boot = Confirm::with_theme(theme)
        .with_prompt("Secure Boot (own keys)?")
        .default(cfg.secure_boot)
        .interact()?;
    cfg.tpm2 = Confirm::with_theme(theme)
        .with_prompt("Bind LUKS to TPM2 + PIN?")
        .default(cfg.tpm2)
        .interact()?;
    cfg.save(path)?;
    println!("Saved {}", path.display());
    Ok(())
}
