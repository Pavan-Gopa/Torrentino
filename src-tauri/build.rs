fn main() {
    // Re-embed the frontend whenever UI assets change, so interface edits are
    // picked up by `cargo build` without needing a manual `touch`.
    println!("cargo:rerun-if-changed=../ui");
    println!("cargo:rerun-if-changed=tauri.conf.json");
    tauri_build::build()
}