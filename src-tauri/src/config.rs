use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// All user-tunable settings for Torrentino.
/// Serialized to/from TOML. `#[serde(default)]` makes every field optional,
/// so a partial config file is fine.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Where finished/partial data is stored.
    pub download_dir: String,
    /// Folder watched in `run` mode: drop `.torrent`/`.magnet` files here.
    pub inbox_dir: String,
    /// Subfolder (inside inbox_dir) where already-added torrent files are moved.
    pub processed_dir: String,
    /// TCP/uTP listen port range (inclusive start, exclusive end).
    pub listen_port_start: u16,
    pub listen_port_end: u16,
    /// Disable DHT (Distributed Hash Table). Keep false for best peer discovery.
    pub disable_dht: bool,
    /// Enable UPnP port forwarding on the router.
    pub enable_upnp: bool,
    /// Resume torrents without re-checking already downloaded pieces.
    pub fastresume: bool,
    /// Max download speed in bytes/sec. 0 = unlimited.
    pub max_download_bps: u32,
    /// Max upload speed in bytes/sec. 0 = unlimited.
    pub max_upload_bps: u32,
    /// Timeout for establishing a peer connection, in seconds.
    pub connect_timeout_secs: u64,
    /// How often (seconds) the inbox folder is scanned in `run` mode.
    pub inbox_poll_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            download_dir: "~/Downloads".to_string(),
            inbox_dir: "~/Downloads/torrentino-inbox".to_string(),
            processed_dir: "processed".to_string(),
            listen_port_start: 4240,
            listen_port_end: 4260,
            disable_dht: false,
            enable_upnp: true,
            fastresume: true,
            max_download_bps: 0,
            max_upload_bps: 0,
            connect_timeout_secs: 10,
            inbox_poll_secs: 2,
        }
    }
}

impl Config {
    /// Default config file location: <config_dir>/torrentino/config.toml
    pub fn default_path() -> PathBuf {
        let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        base.join("torrentino").join("config.toml")
    }

    /// Load config from `path`. If the file does not exist, returns defaults.
    pub fn load(path: &Path) -> Result<Config> {
        if !path.exists() {
            return Ok(Config::default());
        }
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("failed to read config file {}", path.display()))?;
        let cfg: Config = toml::from_str(&text)
            .with_context(|| format!("failed to parse config file {}", path.display()))?;
        Ok(cfg)
    }

    /// Expand a leading `~` to the user's home directory.
    pub fn expand(p: &str) -> PathBuf {
        if let Some(stripped) = p.strip_prefix("~/") {
            if let Some(home) = dirs::home_dir() {
                return home.join(stripped);
            }
        } else if p == "~" {
            if let Some(home) = dirs::home_dir() {
                return home;
            }
        }
        PathBuf::from(p)
    }

    pub fn download_path(&self) -> PathBuf {
        Self::expand(&self.download_dir)
    }

    /// Render an example config file (with comments).
    #[allow(dead_code)]
    pub fn example_toml() -> String {
        r#"# Torrentino configuration
# All fields are optional; missing values fall back to the defaults shown here.

# Where downloaded data is stored.
download_dir = "~/Downloads"

# Folder watched by `torrentino run`: drop .torrent / .magnet files here.
inbox_dir = "~/Downloads/torrentino-inbox"

# Subfolder of inbox_dir where already-added torrent files are moved.
processed_dir = "processed"

# Listen port range for incoming peer connections.
listen_port_start = 4240
listen_port_end = 4260

# DHT (Distributed Hash Table) greatly improves peer discovery. Keep false.
disable_dht = false

# Try to forward ports automatically via UPnP on your router.
enable_upnp = true

# Skip re-checking already downloaded pieces on resume (faster restarts).
fastresume = true

# Speed limits in bytes/second. 0 = unlimited.
# Example: 10 MiB/s download => 10485760
max_download_bps = 0
max_upload_bps = 0

# Timeout (seconds) for establishing a peer connection.
connect_timeout_secs = 10

# How often (seconds) the inbox folder is scanned in `run` mode.
inbox_poll_secs = 2
"#
        .to_string()
    }
}
