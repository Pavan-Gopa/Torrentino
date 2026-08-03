#!/usr/bin/env bash
#
# QA WP-08 - drag-and-drop filtering and Finder URL/document associations.
#
# Xcode generates the app plist in this project. The project file therefore
# must carry the association keys when no source Info.plist exists.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

LIST="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
APP="${NATIVE_DIR}/TorrentinoApp/App/TorrentinoApp.swift"
PBXPROJ="${NATIVE_DIR}/Torrentino.xcodeproj/project.pbxproj"

[[ -f "${LIST}" ]] || qa_die "TorrentListView.swift is missing"
[[ -f "${APP}" ]] || qa_die "TorrentinoApp.swift is missing"
[[ -f "${PBXPROJ}" ]] || qa_die "project.pbxproj is missing"

INFO_FILES=()
for candidate in \
	"${NATIVE_DIR}/TorrentinoApp/Info.plist" \
	"${NATIVE_DIR}/Info.plist" \
	"${NATIVE_DIR}/Config/Info.plist"; do
	if [[ -f "${candidate}" ]]; then
		INFO_FILES+=("${candidate}")
	fi
done

if [[ ${#INFO_FILES[@]} -gt 0 ]]; then
	info_text="$(cat "${INFO_FILES[@]}")"
	for key in CFBundleDocumentTypes CFBundleURLTypes; do
		case "${info_text}" in
			*"${key}"*) qa_ok "${key} declared in source Info.plist" ;;
			*) qa_die "${key} missing from source Info.plist" ;;
		esac
	done
	case "${info_text}" in
		*"com.bittorrent.torrent"*"torrent"*) qa_ok "torrent UTI and extension are associated" ;;
		*) qa_die "torrent UTI/extension association is incomplete" ;;
	esac
	case "${info_text}" in
		*"CFBundleURLSchemes"*"magnet"*) qa_ok "magnet URL scheme is associated" ;;
		*) qa_die "magnet URL scheme association is incomplete" ;
	esac
else
	grep -Eq 'CFBundleDocumentTypes|INFOPLIST_KEY_CFBundleDocumentTypes' "${PBXPROJ}" \
		|| qa_die "CFBundleDocumentTypes missing from generated app Info.plist configuration"
	grep -Eq 'CFBundleURLTypes|INFOPLIST_KEY_CFBundleURLTypes' "${PBXPROJ}" \
		|| qa_die "CFBundleURLTypes missing from generated app Info.plist configuration"
	qa_ok "generated Info.plist association keys declared"
fi

require_text() {
	local file="$1"
	local needle="$2"
	local description="$3"
	grep -Fq "$needle" "$file" || qa_die "$description: missing '$needle'"
	qa_ok "$description"
}

require_text "${LIST}" '.onDrop(of: [.fileURL, .plainText]' "drop accepts file URLs and text"
require_text "${LIST}" 'url.pathExtension.lowercased() == "torrent" else { return }' "drop rejects non-torrent files"
require_text "${LIST}" 'text.hasPrefix("magnet:") else { return }' "drop rejects non-magnet text"
require_text "${APP}" '.onOpenURL { url in' "open URL handler"
require_text "${APP}" 'url.scheme == "magnet"' "magnet URL association handler"
require_text "${APP}" 'url.pathExtension.lowercased() == "torrent"' "torrent URL association handler"

qa_pass
