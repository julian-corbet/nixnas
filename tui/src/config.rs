//! The `nixnas.config` model — the TUI edits these values; the Nix image build
//! reads the SAME TOML via `builtins.fromTOML`. Keep field names in sync with
//! `modules/options.nix` (the typed contract).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Pool {
    /// ZFS pool name to IMPORT (operator-created; nixnas never creates/formats it).
    pub name: String,
    /// LUKS member devices (by-id) to unlock before importing.
    #[serde(default)]
    pub luks_devices: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub host_name: String,
    pub hot: Pool,
    pub cold: Pool,
    /// label -> /dev/disk/by-id path for whole-disk-LUKS SMR archive disks.
    #[serde(default)]
    pub smr_disks: BTreeMap<String, String>,
    #[serde(default = "yes")]
    pub secure_boot: bool,
    #[serde(default = "yes")]
    pub tpm2: bool,
}

fn yes() -> bool {
    true
}

impl Default for Config {
    fn default() -> Self {
        Config {
            host_name: "nas".to_string(),
            hot: Pool { name: "hot".to_string(), luks_devices: vec![] },
            cold: Pool { name: "cold".to_string(), luks_devices: vec![] },
            smr_disks: BTreeMap::new(),
            secure_boot: true,
            tpm2: true,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        if !path.exists() {
            return Ok(Config::default());
        }
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading {}", path.display()))?;
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let text = toml::to_string_pretty(self).context("serialising config")?;
        std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))
    }
}
