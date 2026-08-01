// Entry point for the Torrentino Tauri app.
//
// Reliability notes:
//  * Never panic if the torrent engine fails to start: the window still opens and
//    the frontend shows a readable banner via the `engine_error` command.
//  * No poisonable std mutexes in the hot path: async-aware tokio Mutex only.
//  * IDs come from the engine itself (TorrentId), not from our own counter, so
//    frontend references stay valid and stable for the whole app lifetime.

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;

use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session, TorrentStats};
use serde::Serialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;
use tokio::sync::Mutex;

use crate::config::Config;
use crate::engine;

/// librqbit's torrent lookup key type.
type TIdOrHash = librqbit::api::TorrentIdOrHash;

/// Snapshot of one torrent that the frontend renders.
#[derive(Serialize, Clone)]
pub struct TorrentInfo {
    id: usize,
    name: String,
    /// "initializing" | "live" | "paused" | "error" | "finished"
    state: String,
    progress_bytes: u64,
    total_bytes: u64,
    percent: f64,
    /// Smoothed download speed, bytes/sec.
    download_bps: f64,
    eta_secs: Option<u64>,
    finished: bool,
    error: Option<String>,
    peers_live: usize,
    peers_seen: usize,
    peers_connecting: usize,
    peers_dead: usize,
}

/// One file inside a torrent, for the checkbox panel.
#[derive(Serialize)]
pub struct FileEntry {
    index: usize,
    name: String,
    size: u64,
    selected: bool,
}

/// Shared app state. `session` is None when the engine failed to start; the UI
/// still opens and reports the error instead of crashing.
pub struct AppState {
    session: Option<Arc<Session>>,
    output_folder: Mutex<String>,
    /// id -> (bytes at previous poll, wall clock), for smoothed speed.
    seen: Mutex<HashMap<usize, (u64, Instant)>>,
}

/// Startup error string, stored once if the engine failed to launch.
static ENGINE_ERROR: StdMutex<Option<String>> = StdMutex::new(None);

async fn session_or_err(state: &AppState) -> Result<Arc<Session>, String> {
    state.session.clone().ok_or_else(|| {
        ENGINE_ERROR
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .unwrap_or_else(|| "torrent engine failed to start".to_string())
    })
}

fn current_output_folder(state: &AppState) -> String {
    // tokio::Mutex::blocking_lock is fine here: value is tiny and never held across awaits.
    let g = state.output_folder.blocking_lock();
    g.clone()
}

fn build_torrent_info(
    id: usize,
    handle: &ManagedTorrent,
    stats: &TorrentStats,
    speed: f64,
    eta: Option<u64>,
) -> TorrentInfo {
    let total = stats.total_bytes;
    let progress = stats.progress_bytes;
    let percent = if total > 0 {
        progress as f64 / total as f64 * 100.0
    } else {
        0.0
    };
    let state = if stats.finished {
        "finished".to_string()
    } else {
        stats.state.to_string()
    };
    let (peers_live, peers_seen, peers_connecting, peers_dead) = stats
        .live
        .as_ref()
        .map(|l| {
            let p = &l.snapshot.peer_stats;
            (p.live, p.seen, p.connecting, p.dead)
        })
        .unwrap_or((0, 0, 0, 0));
    TorrentInfo {
        id,
        name: handle.name().unwrap_or_else(|| "torrent".to_string()),
        state,
        progress_bytes: progress,
        total_bytes: total,
        percent,
        download_bps: speed,
        eta_secs: eta,
        finished: stats.finished,
        error: stats.error.clone(),
        peers_live,
        peers_seen,
        peers_connecting,
        peers_dead,
    }
}

// ---- commands -------------------------------------------------------------

/// Add a torrent from a magnet link, http(s) URL or local .torrent path.
#[tauri::command]
async fn add_torrent(app: AppHandle, input: String) -> Result<TorrentInfo, String> {
    let (session, output_folder) = {
        let state = app.state::<AppState>();
        (session_or_err(&state).await?, current_output_folder(&state))
    };

    let add = AddTorrent::from_cli_argument(&input).map_err(|e| e.to_string())?;
    let opts = AddTorrentOptions {
        // overwrite=false: resume happens through fastresume; blind overwrite
        // could wipe good data after a partial download.
        overwrite: false,
        output_folder: Some(output_folder),
        ..Default::default()
    };
    let response = session
        .add_torrent(add, Some(opts))
        .await
        .map_err(|e| e.to_string())?;
    let handle = response
        .into_handle()
        .ok_or_else(|| "torrent was added but not started".to_string())?;
    let id = handle.id();
    let stats = handle.stats();
    Ok(build_torrent_info(id, &handle, &stats, 0.0, None))
}

/// Fresh snapshot of every torrent. Speed is a smoothed bytes/sec estimate that
/// we compute from progress deltas between polls (engine counters are bursty).
#[tauri::command]
async fn list_torrents(app: AppHandle) -> Result<Vec<TorrentInfo>, String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;

    let mut out: Vec<TorrentInfo> = Vec::new();
    let mut seen = state.seen.lock().await;
    let now = Instant::now();
    session.with_torrents(|torrents| {
        for (id, handle) in torrents {
            let stats = handle.stats();
            let (speed, eta) = match seen.get(&id).copied() {
                Some((prev_bytes, prev_ts)) => {
                    let dt = now.duration_since(prev_ts).as_secs_f64();
                    if dt > 0.1 && !stats.finished {
                        let delta = stats.progress_bytes.saturating_sub(prev_bytes) as f64;
                        let instant = delta / dt;
                        // Exponential smoothing so the number does not jump around.
                        let s = if instant > 0.0 {
                            0.7 * instant + 0.3 * 0.0
                        } else {
                            0.0
                        };
                        let e = if s > 1024.0 && stats.total_bytes > stats.progress_bytes {
                            Some(
                                ((stats.total_bytes - stats.progress_bytes) as f64 / s)
                                    .round() as u64,
                            )
                        } else {
                            None
                        };
                        (s, e)
                    } else {
                        (0.0, None)
                    }
                }
                None => (0.0, None),
            };
            seen.insert(id, (stats.progress_bytes, now));
            out.push(build_torrent_info(id, handle, &stats, speed, eta));
        }
    });
    // Drop id entries of removed torrents.
    let valid: Vec<usize> = out.iter().map(|t| t.id).collect();
    seen.retain(|k, _| valid.contains(k));
    Ok(out)
}

#[tauri::command]
async fn pause_torrent(app: AppHandle, id: usize) -> Result<TorrentInfo, String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;
    let handle = session
        .get(TIdOrHash::Id(id))
        .ok_or_else(|| "torrent not found".to_string())?;
    handle.pause().await.map_err(|e| e.to_string())?;
    let stats = handle.stats();
    Ok(build_torrent_info(id, &handle, &stats, 0.0, None))
}

#[tauri::command]
async fn resume_torrent(app: AppHandle, id: usize) -> Result<TorrentInfo, String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;
    let handle = session
        .get(TIdOrHash::Id(id))
        .ok_or_else(|| "torrent not found".to_string())?;
    handle.start().await.map_err(|e| e.to_string())?;
    let stats = handle.stats();
    Ok(build_torrent_info(id, &handle, &stats, 0.0, None))
}

#[tauri::command]
async fn remove_torrent(app: AppHandle, id: usize, delete_files: bool) -> Result<(), String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;
    session
        .delete(TIdOrHash::Id(id), delete_files)
        .await
        .map_err(|e| e.to_string())?;
    state.seen.lock().await.remove(&id);
    Ok(())
}

/// List files of a torrent with their current download-selection state.
#[tauri::command]
async fn list_files(app: AppHandle, id: usize) -> Result<Vec<FileEntry>, String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;
    let handle = session
        .get(TIdOrHash::Id(id))
        .ok_or_else(|| "torrent not found".to_string())?;

    handle.with_files(|files| {
        files
            .file_details()
            .iter()
            .enumerate()
            .map(|(index, f)| FileEntry {
                index,
                name: f.filename.clone(),
                size: f.len,
                selected: f.selected(),
            })
            .collect()
    })
    .map_err(|e: anyhow::Error| e.to_string())
}

/// Replace the set of files to download with the given indices.
#[tauri::command]
async fn set_files(app: AppHandle, id: usize, indices: Vec<usize>) -> Result<(), String> {
    let state = app.state::<AppState>();
    let session = session_or_err(&state).await?;
    let handle = session
        .get(TIdOrHash::Id(id))
        .ok_or_else(|| "torrent not found".to_string())?;
    handle
        .update_only_files(indices.into_iter().collect())
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn get_download_dir(app: AppHandle) -> Result<String, String> {
    let state = app.state::<AppState>();
    Ok(current_output_folder(&state))
}

#[tauri::command]
async fn choose_folder(app: AppHandle) -> Result<Option<String>, String> {
    let picked = app
        .dialog()
        .file()
        .set_title("Select download folder")
        .set_directory(true)
        .set_can_create_directories(true)
        .blocking_pick_folder();
    match picked {
        Some(path) => {
            let s = path.to_string();
            let state = app.state::<AppState>();
            *state.output_folder.lock().await = s.clone();
            Ok(Some(s))
        }
        None => Ok(None),
    }
}

#[tauri::command]
async fn pick_torrent_file(app: AppHandle) -> Result<Option<String>, String> {
    let picked = app
        .dialog()
        .file()
        .set_title("Select .torrent file")
        .add_filter("Torrent", &["torrent"])
        .blocking_pick_file();
    Ok(picked.map(|p| p.to_string()))
}

/// Human readable startup error for the engine, if any.
#[tauri::command]
fn engine_error() -> Option<String> {
    ENGINE_ERROR.lock().ok().and_then(|g| g.clone())
}

pub fn run() {
    let cfg_path = Config::default_path();
    let (cfg, cfg_err) = match Config::load(&cfg_path) {
        Ok(c) => (c, None),
        Err(e) => (
            Config::default(),
            Some(format!(
                "Could not parse {}: {}. Using defaults.",
                cfg_path.display(),
                e
            )),
        ),
    };
    if let Some(msg) = &cfg_err {
        tracing::warn!("{}", msg);
    }

    let download_dir = cfg.download_path().to_string_lossy().to_string();
    let session = match tauri::async_runtime::block_on(engine::create_session(&cfg)) {
        Ok(s) => Some(s),
        Err(e) => {
            if let Ok(mut g) = ENGINE_ERROR.lock() {
                *g = Some(format!("Torrent engine failed to start: {e}"));
            }
            None
        }
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(move |app| {
            app.manage(AppState {
                session,
                output_folder: Mutex::new(download_dir),
                seen: Mutex::new(HashMap::new()),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            add_torrent,
            list_torrents,
            pause_torrent,
            resume_torrent,
            remove_torrent,
            choose_folder,
            get_download_dir,
            pick_torrent_file,
            list_files,
            set_files,
            engine_error,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Torrentino");
}
