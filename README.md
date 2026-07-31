# Torrentino

A small, fast and minimalist **BitTorrent client for macOS**, written in Rust and
powered by [`librqbit`](https://github.com/ikatson/rqbit), with a native
[Tauri](https://tauri.app) GUI.

Built to be a lightweight, stable alternative to heavy qBittorrent-style clients.
Compiles to a **native Apple Silicon (arm64)** binary and takes advantage of the
hardware that actually matters for torrenting:

- **Native arm64 code** — no emulation on M-series Macs.
- **Hardware-accelerated SHA-1** — piece hashing uses the CPU's SHA extensions.
- **Many parallel connections** — DHT + PEX + uTP for maximum peer discovery.
- **Tuned disk I/O** and an optimized release build (fat LTO).

> Note: Metal / the Neural Engine are *not* used — torrenting is bound by network,
> disk and SHA-1 hashing, not GPU/ML. The optimizations above are what give real speed.

## Features

- **Minimal native GUI** (Tauri webview, no Electron) with a dark, clean interface.
- Add a torrent from a `magnet:` link, an `http(s)` URL, or a local `.torrent` file
  (via a native file picker).
- **Native "choose folder" dialog** to pick where downloads are saved.
- **Live torrent list**: name, status, animated progress bar, percentage,
  downloaded/total size, **download speed** and **ETA**.
- Per-torrent controls: **▶ Resume**, **⏸ Pause**, **✕ Remove**.
- Automatic **resume** of partially-downloaded files (`overwrite = true`).
- TOML configuration for ports, speed limits, timeouts, DHT/UPnP and more.

## Prerequisites

- Rust toolchain (`rustup`).
- Xcode command-line tools: `xcode-select --install`.
- Node.js + npm (only needed for `tauri dev` / building the `.app` bundle).

## Run & build

Quick run (compiles and launches the app):

```sh
cd src-tauri
cargo run
```

Develop with hot reload (uses the Tauri CLI):

```sh
npm install
npm run dev          # == tauri dev
```

Produce a release `.app` and `.dmg` bundle:

```sh
npm install
npm run build        # == tauri build
# output: src-tauri/target/release/bundle/macos/Torrentino.app
#         src-tauri/target/release/bundle/dmg/Torrentino_0.1.0_aarch64.dmg
```

A standalone optimized binary is also produced at
`src-tauri/target/release/torrentino`.

## Configuration

Default location: `~/Library/Application Support/torrentino/config.toml` (macOS).
If absent, sensible defaults are used. The GUI reads `download_dir` as the initial
save location (changeable in-app) and the engine settings below.

| Key                    | Default         | Description                        |
|------------------------|-----------------|------------------------------------|
| `download_dir`         | `~/Downloads`   | Where downloaded files go          |
| `listen_port_start`    | `4240`          | First port to listen on            |
| `listen_port_end`      | `4260`          | Last port to listen on             |
| `disable_dht`          | `false`         | Disable DHT peer discovery         |
| `enable_upnp`          | `true`          | Enable UPnP port forwarding        |
| `fastresume`           | `true`          | Skip re-checking known-good pieces |
| `max_download_bps`     | `0` (unlimited) | Download speed limit (bytes/sec)   |
| `max_upload_bps`       | `0` (unlimited) | Upload speed limit (bytes/sec)     |
| `connect_timeout_secs` | `10`            | Peer connection timeout            |

## Project layout

```
ui/                   Frontend (plain HTML/CSS/JS, no build step)
  index.html          Layout: add bar, folder picker, torrent list
  styles.css          Minimal dark theme
  app.js              Calls Tauri commands, renders list, polls stats
src-tauri/
  tauri.conf.json     Window/bundle config (withGlobalTauri)
  capabilities/       IPC permissions (core + dialog)
  icons/              App icons (generated via `tauri icon`)
  src/
    main.rs           Entry point + logging
    gui.rs            Tauri commands + app state (session, torrent registry)
    engine.rs         librqbit session/options helpers
    config.rs         TOML config model, defaults, path expansion
```

### Tauri commands (Rust → frontend)

`add_torrent`, `list_torrents`, `pause_torrent`, `resume_torrent`,
`remove_torrent`, `choose_folder`, `get_download_dir`, `pick_torrent_file`.
