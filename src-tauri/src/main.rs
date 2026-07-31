// Hide the console window on Windows release builds (no-op elsewhere).
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

mod config;
mod engine;
mod gui;

use tracing_subscriber::EnvFilter;

fn main() {
    // Logging is off by default. Set RUST_LOG (e.g. RUST_LOG=info) to enable.
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("off"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();

    gui::run();
}