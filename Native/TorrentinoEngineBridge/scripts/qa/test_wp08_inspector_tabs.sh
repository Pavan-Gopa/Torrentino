#!/usr/bin/env bash
#
# QA WP-08 - Inspector tabs, selection synchronization, and Cmd+I.
#
# The Inspector is a UI-only surface, so this check validates the source
# contract and the command path that opens it. It deliberately does not
# accept comments as evidence of a tab or a selection binding.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

INSPECTOR="${NATIVE_DIR}/TorrentinoApp/Features/InspectorView.swift"
LIST="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
MODEL="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListViewModel.swift"
APP="${NATIVE_DIR}/TorrentinoApp/App/TorrentinoApp.swift"

require_file() {
	[[ -f "$1" ]] || qa_die "$2: missing file $1"
	qa_ok "$2"
}

require_text() {
	local file="$1"
	local needle="$2"
	local description="$3"
	grep -Fq "$needle" "$file" || qa_die "$description: missing '$needle'"
	qa_ok "$description"
}

require_file "${INSPECTOR}" "InspectorView source"
require_file "${LIST}" "TorrentListView source"
require_file "${MODEL}" "TorrentListViewModel source"
require_file "${APP}" "TorrentinoApp source"

for tab in general activity files settings; do
	require_text "${INSPECTOR}" "case ${tab}" "Inspector ${tab} enum case"
	require_text "${INSPECTOR}" ".tag(InspectorTab.${tab})" "Inspector ${tab} tab tag"
done

require_text "${INSPECTOR}" 'TabView(selection: $selectedTab)' "Inspector selected-tab binding"
require_text "${LIST}" 'InspectorView(torrent: viewModel.selectedTorrent, viewModel: viewModel)' "Inspector receives selected torrent"
require_text "${MODEL}" 'var selectedTorrent: TorrentSnapshot?' "selected torrent projection"
require_text "${MODEL}" 'guard let selectedRecordID = selection.first else { return nil }' "selection drives inspector identity"
require_text "${APP}" '.keyboardShortcut("i", modifiers: .command)' "Cmd+I Inspector shortcut"

qa_pass
