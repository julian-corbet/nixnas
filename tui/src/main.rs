//! nixnas — a small, guided TUI to configure, build, and flash a nixnas USB stick.
//!
//! Deliberately narrow scope: it does NOT do updates. A running nixnas updates itself
//! the Nix way (system.autoUpgrade builds a new generation; the bootloader keeps the
//! previous ones for rollback). This tool only PROVISIONS a fresh stick: edit the TUI
//! config -> build the personalised image LOCALLY -> optionally back the current
//! stick up -> overwrite it. The MACHINE's configuration is Nix, in the operator's
//! flake — the TUI config only says where that flake is and how to build/flash it.

mod build;
mod config;
mod flash;

use anyhow::Result;
use config::Config;
use dialoguer::{theme::ColorfulTheme, Input, Select};
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
                let img = build::build_image(&config_path, &cfg)?;
                println!("Built image: {}", img.display());
            }
            2 => flash::flash(&theme, &config_path)?,
            _ => break,
        }
    }
    Ok(())
}

/// Edit the TUI's own settings (see config.rs — the machine config is Nix, not here).
fn edit_config(theme: &ColorfulTheme, cfg: &mut Config, path: &Path) -> Result<()> {
    cfg.flake_dir = Input::with_theme(theme)
        .with_prompt("Flake directory (the host overlay that composes nixnas)")
        .with_initial_text(cfg.flake_dir.clone())
        .interact_text()?;
    let sops: String = Input::with_theme(theme)
        .with_prompt("Secure Boot PKI sops file (tar; empty = autogenerate keys on first boot)")
        .with_initial_text(cfg.sb_keys_sops.clone().unwrap_or_default())
        .allow_empty(true)
        .interact_text()?;
    cfg.sb_keys_sops = if sops.trim().is_empty() { None } else { Some(sops.trim().to_string()) };
    cfg.save(path)?;
    println!("Saved {}", path.display());
    Ok(())
}
