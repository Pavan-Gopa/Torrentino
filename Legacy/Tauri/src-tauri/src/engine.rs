use crate::config::Config;
use anyhow::{Context, Result};
use librqbit::limits::LimitsConfig;
use librqbit::{PeerConnectionOptions, Session, SessionOptions};
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Duration;

/// Translate our TOML config into librqbit's SessionOptions.
pub fn build_session_options(cfg: &Config) -> SessionOptions {
    let mut opts = SessionOptions::default();
    opts.disable_dht = cfg.disable_dht;
    opts.enable_upnp_port_forwarding = cfg.enable_upnp;
    opts.fastresume = cfg.fastresume;
    opts.listen_port_range = Some(cfg.listen_port_start..cfg.listen_port_end);

    let mut peer_opts = PeerConnectionOptions::default();
    peer_opts.connect_timeout = Some(Duration::from_secs(cfg.connect_timeout_secs));
    opts.peer_opts = Some(peer_opts);

    // NonZeroU32::new returns None for 0 => "unlimited".
    opts.ratelimits = LimitsConfig {
        download_bps: NonZeroU32::new(cfg.max_download_bps),
        upload_bps: NonZeroU32::new(cfg.max_upload_bps),
    };

    opts
}

/// Create a torrent session that downloads into cfg.download_path().
pub async fn create_session(cfg: &Config) -> Result<Arc<Session>> {
    let download_dir = cfg.download_path();
    std::fs::create_dir_all(&download_dir)
        .with_context(|| format!("failed to create download dir {}", download_dir.display()))?;

    let opts = build_session_options(cfg);
    let session = Session::new_with_opts(download_dir.clone(), opts)
        .await
        .with_context(|| format!("failed to start torrent session in {}", download_dir.display()))?;
    Ok(session)
}

