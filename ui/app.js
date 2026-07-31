// Torrentino frontend. Uses the global Tauri API (withGlobalTauri: true).
const { invoke } = window.__TAURI__.core;

// ---- formatting helpers -------------------------------------------------
function fmtBytes(n) {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return (i === 0 ? n.toString() : v.toFixed(2)) + " " + units[i];
}
function fmtSpeed(bps) {
  if (!bps || bps <= 0) return "0 B/s";
  return fmtBytes(bps) + "/s";
}
function fmtEta(secs) {
  if (secs == null) return "—";
  if (secs < 60) return secs + "s";
  const m = Math.floor(secs / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  return h + "h " + (m % 60) + "m";
}
function escapeHtml(s) {
  return (s || "").replace(/[&<>"]/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;",
  }[c]));
}

// ---- per-file selection state -------------------------------------------
// id -> { open, files, loading }; kept in JS so an open file panel survives
// the 700ms polling rebuild of the list.
const filesState = {};

function fileListHtml(id) {
  const st = filesState[id];
  if (!st || !st.open) return "";
  if (st.loading) return `<div class="files-note">Loading files…</div>`;
  if (!st.files || st.files.length === 0) return `<div class="files-note">No files</div>`;
  return (
    `<div class="file-list">` +
    st.files
      .map(
        (f) => `
    <label class="file-row">
      <input type="checkbox" data-file-id="${id}" data-idx="${f.index}" ${f.selected ? "checked" : ""} />
      <span class="file-name" title="${escapeHtml(f.name)}">${escapeHtml(f.name)}</span>
      <span class="file-size">${fmtBytes(f.size)}</span>
    </label>`
      )
      .join("") +
    `</div>`
  );
}

// ---- rendering ----------------------------------------------------------
function cardHtml(t) {
  const paused = t.state === "paused";
  const label = t.finished ? "Done" : t.state;
  const peers = `<span title="live / seen (connecting / dead)">👥 ${t.peers_live}/${t.peers_seen} (${t.peers_connecting}/${t.peers_dead})</span>`;
  const meta = t.finished
    ? `<span>${fmtBytes(t.total_bytes)}</span>${peers}`
    : `<span>${fmtBytes(t.progress_bytes)} / ${fmtBytes(t.total_bytes)}</span>
       <span>↓ ${fmtSpeed(t.download_bps)}</span>
       <span>ETA ${fmtEta(t.eta_secs)}</span>${peers}`;

  let buttons;
  if (t.finished) {
    buttons = `<button class="icon" data-act="remove" data-id="${t.id}" title="Remove">✕</button>`;
  } else if (paused) {
    buttons = `<button class="icon" data-act="resume" data-id="${t.id}" title="Resume">▶</button>
               <button class="icon" data-act="remove" data-id="${t.id}" title="Remove">✕</button>`;
  } else {
    buttons = `<button class="icon" data-act="pause" data-id="${t.id}" title="Pause">⏸</button>
               <button class="icon" data-act="remove" data-id="${t.id}" title="Remove">✕</button>`;
  }

  const err = t.error ? ": " + escapeHtml(t.error) : "";
  return `
    <div class="card">
      <div class="top">
        <span class="name">${escapeHtml(t.name)}</span>
        <span class="pct ${t.finished ? "done" : ""}">${t.percent.toFixed(0)}%</span>
      </div>
      <div class="bar"><div class="fill ${t.finished ? "done" : ""}" style="width:${t.percent.toFixed(1)}%"></div></div>
      <div class="meta">${meta}<span class="state ${t.state}">${label}${err}</span></div>
      <div class="actions">${buttons}
        <button class="files-toggle" data-act="files" data-id="${t.id}">${filesState[t.id] && filesState[t.id].open ? "▾" : "▸"} Files</button>
      </div>
      <div class="files" data-files="${t.id}">${fileListHtml(t.id)}</div>
    </div>`;
}

async function render() {
  let list;
  try {
    list = await invoke("list_torrents");
  } catch (e) {
    console.error("list_torrents failed:", e);
    return;
  }
  const el = document.getElementById("list");
  const empty = document.getElementById("empty");
  if (!list || list.length === 0) {
    el.querySelectorAll(".card").forEach((n) => n.remove());
    empty.style.display = "block";
    return;
  }
  empty.style.display = "none";
  // Rebuild the list (small N; simple and robust).
  el.querySelectorAll(".card").forEach((n) => n.remove());
  el.insertAdjacentHTML("beforeend", list.map(cardHtml).join(""));
}

async function refreshFolder() {
  try {
    const dir = await invoke("get_download_dir");
    document.getElementById("folder-label").textContent = "Saving to: " + dir;
  } catch (e) {
    console.error(e);
  }
}

// ---- actions ------------------------------------------------------------
async function addFromInput() {
  const input = document.getElementById("input");
  const value = input.value.trim();
  if (!value) return;
  try {
    await invoke("add_torrent", { input: value });
    input.value = "";
  } catch (e) {
    alert("Failed to add torrent:\n" + e);
  }
  render();
}

document.getElementById("add").addEventListener("click", addFromInput);
document.getElementById("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") addFromInput();
});

document.getElementById("add-file").addEventListener("click", async () => {
  let path;
  try {
    path = await invoke("pick_torrent_file");
  } catch (e) {
    alert("Could not open file picker:\n" + e);
    return;
  }
  if (!path) return;
  try {
    await invoke("add_torrent", { input: path });
  } catch (e) {
    alert("Failed to add torrent:\n" + e);
  }
  render();
});

document.getElementById("change-folder").addEventListener("click", async () => {
  try {
    const picked = await invoke("choose_folder");
    if (picked) refreshFolder();
  } catch (e) {
    alert("Could not open folder picker:\n" + e);
  }
});

// Event delegation for per-torrent buttons.
document.getElementById("list").addEventListener("click", async (e) => {
  const btn = e.target.closest("button[data-act]");
  if (!btn) return;
  const id = Number(btn.dataset.id);
  const act = btn.dataset.act;
  if (act === "files") {
    const st = filesState[id] || (filesState[id] = { open: false, files: null, loading: false });
    st.open = !st.open;
    if (st.open && !st.files) {
      st.loading = true;
      render();
      try {
        st.files = await invoke("list_files", { id });
      } catch (err) {
        alert("Failed to list files:\n" + err);
        st.open = false;
      }
      st.loading = false;
    }
    render();
    return;
  }
  try {
    if (act === "pause") await invoke("pause_torrent", { id });
    else if (act === "resume") await invoke("resume_torrent", { id });
    else if (act === "remove") await invoke("remove_torrent", { id, deleteFiles: false });
  } catch (err) {
    alert("Action failed:\n" + err);
  }
  render();
});

// Checkbox toggling inside an open file panel -> update the download selection.
document.getElementById("list").addEventListener("change", async (e) => {
  const cb = e.target.closest("input[data-file-id]");
  if (!cb) return;
  const id = Number(cb.dataset.fileId);
  const container = document.querySelector(`.files[data-files="${id}"]`);
  const indices = Array.from(container.querySelectorAll("input[data-file-id]:checked")).map((i) =>
    Number(i.dataset.idx)
  );
  try {
    await invoke("set_files", { id, indices });
  } catch (err) {
    alert("Failed to update file selection:\n" + err);
  }
  // Refresh from the engine so checkboxes reflect the authoritative state.
  try {
    if (filesState[id]) filesState[id].files = await invoke("list_files", { id });
  } catch (err) {
    /* ignore */
  }
  render();
});

// ---- init ---------------------------------------------------------------
refreshFolder();
render();
setInterval(render, 700);