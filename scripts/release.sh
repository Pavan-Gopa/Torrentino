#!/usr/bin/env bash
# Torrentino WP15/WP16 Developer ID Release Pipeline
# Fail-closed script for preflight, archive, export, verification, notarization, DMG packaging, and evidence collection.
# Compatible with macOS /bin/bash 3.2+

set -euo pipefail

# Configuration Defaults
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TEAM_ID="${TEAM_ID:-438UQRF7JV}"
DEVELOPER_ID_CERT="${DEVELOPER_ID_CERT:-Developer ID Application: Stichting Kadamba Foundation (438UQRF7JV)}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-Native/Config/ExportOptions-DeveloperID.plist}"

RELEASE_DIR="${RELEASE_DIR:-artifacts/release/${VERSION}-${BUILD_NUMBER}}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${RELEASE_DIR}/Torrentino.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-${RELEASE_DIR}/exported}"
APP_PATH="${APP_PATH:-${EXPORT_DIR}/Torrentino.app}"
ZIP_PATH="${ZIP_PATH:-${RELEASE_DIR}/Torrentino-${VERSION}-${BUILD_NUMBER}.zip}"
DMG_PATH="${DMG_PATH:-${RELEASE_DIR}/Torrentino-${VERSION}-${BUILD_NUMBER}-macOS-arm64.dmg}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${RELEASE_DIR}/evidence}"
NOTARIZATION_DIR="${NOTARIZATION_DIR:-${RELEASE_DIR}/notarization}"

log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

fail() {
    log_error "$*"
    exit 1
}

# Read plist key using PlistBuddy fallback
read_plist_key() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || defaults read "$plist" "$key" 2>/dev/null
}

# Process each Mach-O file dynamically without using Bash 4 mapfile/readarray
process_app_machos() {
    local target_dir="$1"
    local callback="$2"

    while IFS= read -r file; do
        if [[ -f "$file" ]] && file -b "$file" | grep -q "Mach-O"; then
            "$callback" "$file" "$target_dir"
        fi
    done < <(find "$target_dir" -type f)
}

# Version comparison for nested minOS (must be <= 13.0, rejecting 13.1+)
compare_minos_max13() {
    local ver="$1"
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    minor="${minor:-0}"

    if (( major > 13 )) || { (( major == 13 )) && (( minor > 0 )); }; then
        return 1
    fi
    return 0
}

# Normalize dwarfdump output to relative path + UUID + arch (one line per UUID for multi-arch binaries)
get_normalized_uuid() {
    local macho="$1"
    local rel_path="$2"
    dwarfdump -u "$macho" 2>&1 | awk -v r="$rel_path" '{ if ($1 == "UUID:") print r ": " $2 " " $3 }'
}

# Subcommand: Preflight
cmd_preflight() {
    log_info "Running clean product-scope preflight checks..."

    # Check required tools
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild tool missing"
    command -v swift >/dev/null 2>&1 || fail "swift tool missing"
    command -v codesign >/dev/null 2>&1 || fail "codesign tool missing"
    command -v hdiutil >/dev/null 2>&1 || fail "hdiutil tool missing"
    command -v otool >/dev/null 2>&1 || fail "otool tool missing"
    command -v lipo >/dev/null 2>&1 || fail "lipo tool missing"
    command -v ditto >/dev/null 2>&1 || fail "ditto tool missing"
    command -v security >/dev/null 2>&1 || fail "security tool missing"
    command -v git >/dev/null 2>&1 || fail "git tool missing"
    command -v jq >/dev/null 2>&1 || fail "jq tool missing"
    command -v stat >/dev/null 2>&1 || fail "stat tool missing"
    command -v file >/dev/null 2>&1 || fail "file tool missing"
    command -v dwarfdump >/dev/null 2>&1 || fail "dwarfdump tool missing"
    command -v cmp >/dev/null 2>&1 || fail "cmp tool missing"

    # Reject dirty product/release-scope files (excluding artifacts output)
    log_info "Checking product/release scope git status..."
    local dirty_files
    dirty_files=$(git status --porcelain Native/ scripts/ Native/Config/)
    if [[ -n "$dirty_files" ]]; then
        log_error "Product/release-scope contains uncommitted modifications:"
        echo "$dirty_files" >&2
        fail "Preflight rejected: dirty product/release-scope files"
    fi

    # Verify exact Developer ID identity in keychain
    log_info "Verifying Developer ID signing identity in Keychain..."
    if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID_CERT"; then
        fail "Preflight rejected: Valid Developer ID identity '$DEVELOPER_ID_CERT' not found in keychain"
    fi

    # Capture source commit
    local source_commit
    source_commit=$(git rev-parse HEAD)
    log_info "Captured source commit: $source_commit"

    # Verify project files exist
    [[ -f "Native/Torrentino.xcodeproj/project.pbxproj" ]] || fail "Native/Torrentino.xcodeproj/project.pbxproj missing"
    [[ -f "Native/TorrentinoApp/Info.plist" ]] || fail "Native/TorrentinoApp/Info.plist missing"
    [[ -f "$EXPORT_OPTIONS_PLIST" ]] || fail "Export options plist missing: $EXPORT_OPTIONS_PLIST"

    # Verify third-party libtorrent static library prefix
    local lt_lib="Native/ThirdParty/.build/prefix/libtorrent-2.1.1-release/lib/libtorrent-rasterbar.a"
    if [[ ! -f "$lt_lib" ]]; then
        fail "libtorrent static library missing: $lt_lib. Run libtorrent build script first."
    fi

    # Verify version configuration in project files using $VERSION and $BUILD_NUMBER
    grep -q "MARKETING_VERSION = ${VERSION};" Native/Torrentino.xcodeproj/project.pbxproj || fail "project.pbxproj MARKETING_VERSION is not ${VERSION}"
    grep -q "CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};" Native/Torrentino.xcodeproj/project.pbxproj || fail "project.pbxproj CURRENT_PROJECT_VERSION is not ${BUILD_NUMBER}"
    grep -q "\$(MARKETING_VERSION)" Native/TorrentinoApp/Info.plist || fail "Info.plist does not consume MARKETING_VERSION"
    grep -q "\$(CURRENT_PROJECT_VERSION)" Native/TorrentinoApp/Info.plist || fail "Info.plist does not consume CURRENT_PROJECT_VERSION"

    log_info "Preflight checks passed successfully."
}

# Save deterministic pre-staple baseline evidence
save_pre_staple_evidence() {
    local target_app="$1"
    log_info "Recording deterministic pre-staple executable SHA-256 hashes and UUIDs..."
    mkdir -p "$RELEASE_DIR"

    local pre_hash_tmp="${RELEASE_DIR}/pre_staple_hashes.tmp"
    local pre_uuid_tmp="${RELEASE_DIR}/pre_staple_uuids.tmp"
    rm -f "$pre_hash_tmp" "$pre_uuid_tmp"

    _record_macho_baseline() {
        local macho="$1"
        local app_dir="$2"
        local rel_path="${macho#$app_dir/}"
        local hash
        hash=$(shasum -a 256 "$macho" | awk '{print $1}')
        echo "$hash  $rel_path" >> "$pre_hash_tmp"

        local norm_uuid
        norm_uuid=$(get_normalized_uuid "$macho" "$rel_path")
        echo "$norm_uuid" >> "$pre_uuid_tmp"
    }

    process_app_machos "$target_app" _record_macho_baseline

    sort -k2 "$pre_hash_tmp" > "${RELEASE_DIR}/pre_staple_hashes.txt"
    sort -k1 "$pre_uuid_tmp" > "${RELEASE_DIR}/pre_staple_uuids.txt"
    rm -f "$pre_hash_tmp" "$pre_uuid_tmp"

    log_info "Saved deterministic pre-staple baseline evidence."
}

# Subcommand: Archive & Export
cmd_archive_export() {
    log_info "Archiving and exporting Developer ID Release candidate..."

    mkdir -p "$RELEASE_DIR"

    log_info "Building archive at $ARCHIVE_PATH..."
    xcodebuild -project Native/Torrentino.xcodeproj \
        -scheme Torrentino \
        -destination 'generic/platform=macOS' \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -disableAutomaticPackageResolution \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_CERT" \
        CODE_SIGN_STYLE=Manual \
        archive

    log_info "Exporting archive to $EXPORT_DIR..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

    [[ -d "$APP_PATH" ]] || fail "Export failed: $APP_PATH missing"
    log_info "Archive and export completed: $APP_PATH"

    git rev-parse HEAD > "${RELEASE_DIR}/source_commit.txt"
    save_pre_staple_evidence "$APP_PATH"
}

# Helper: verify a single Mach-O binary inside app bundle
_verify_single_macho() {
    local macho="$1"
    local target_app="$2"
    local rel_path="${macho#$target_app/}"

    log_info "Verifying Mach-O binary: $rel_path"

    # Code signature check
    codesign --verify --verbose=4 --strict "$macho" || fail "codesign verify failed for $rel_path"

    local cs_details
    cs_details=$(codesign -dvvv "$macho" 2>&1)

    if echo "$cs_details" | grep -q "Signature=adhoc"; then
        fail "Signature for $rel_path is ad-hoc, expected Developer ID"
    fi

    if ! echo "$cs_details" | grep -q "TeamIdentifier=$TEAM_ID"; then
        fail "TeamIdentifier for $rel_path does not match expected $TEAM_ID"
    fi

    # Executables must have Hardened Runtime enabled
    if file -b "$macho" | grep -q "executable"; then
        if ! echo "$cs_details" | grep -qE "flags=.*runtime|0x10000\(runtime\)"; then
            fail "Hardened Runtime flag missing from executable $rel_path"
        fi
    fi

    # Entitlements check
    local entitlements
    entitlements=$(codesign -d --entitlements :- "$macho" 2>&1 || true)
    if echo "$entitlements" | grep -q "<key>get-task-allow</key>"; then
        if echo "$entitlements" | grep -A1 "<key>get-task-allow</key>" | grep -q "<true/>"; then
            fail "Binary $rel_path contains forbidden get-task-allow entitlement"
        fi
    fi
    if echo "$entitlements" | grep -q "com.apple.security.app-sandbox"; then
        fail "Binary $rel_path contains forbidden App Sandbox entitlement"
    fi

    # Architecture & minOS rules:
    local lipo_archs
    lipo_archs=$(lipo -archs "$macho" 2>&1 | xargs)

    local otool_load
    otool_load=$(otool -l "$macho" 2>&1)

    local minos_val=""
    if echo "$otool_load" | grep -A4 "LC_BUILD_VERSION" | grep -q "minos"; then
        minos_val=$(echo "$otool_load" | grep -A4 "LC_BUILD_VERSION" | grep "minos" | awk '{print $2}')
    elif echo "$otool_load" | grep -A4 "LC_VERSION_MIN_MACOSX" | grep -q "version"; then
        minos_val=$(echo "$otool_load" | grep -A4 "LC_VERSION_MIN_MACOSX" | grep "version" | awk '{print $2}')
    fi

    [[ -n "$minos_val" ]] || fail "Binary $rel_path minOS version could not be parsed"

    if [[ "$rel_path" == "Contents/MacOS/Torrentino" || "$rel_path" == "Contents/Library/LaunchAgents/TorrentinoEngineAgent" ]]; then
        # Primary executables MUST be exact arm64 and minOS exactly 13.0
        if [[ "$lipo_archs" != "arm64" ]]; then
            fail "Primary binary $rel_path lipo -archs ('$lipo_archs') is not exactly 'arm64'"
        fi
        if [[ "$minos_val" != "13.0" ]]; then
            fail "Primary binary $rel_path minOS ('$minos_val') is not exactly '13.0'"
        fi
    else
        # Nested third-party/framework binaries (e.g. Sparkle): arm64 MUST be present, minOS <= 13.0
        if ! echo "$lipo_archs" | grep -q "arm64"; then
            fail "Nested binary $rel_path does not contain arm64 architecture ('$lipo_archs')"
        fi
        if ! compare_minos_max13 "$minos_val"; then
            fail "Nested binary $rel_path minOS ('$minos_val') exceeds 13.0"
        fi
    fi

    # Rpath and Dependency check for local absolute coupling
    local rpath_lines dep_lines
    rpath_lines=$(echo "$otool_load" | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}' || true)
    dep_lines=$(otool -L "$macho" 2>&1 | tail -n +2 | awk '{print $1}' || true)

    for line in $rpath_lines $dep_lines; do
        if echo "$line" | grep -qE "^/opt/homebrew|^/usr/local|^/Users|^/Applications/Xcode"; then
            fail "Binary $rel_path contains forbidden local absolute dependency/rpath: $line"
        fi
    done
}

# Helper count for Mach-O discovery validation
_count_macho() {
    local macho="$1"
    MACHO_COUNT=$((MACHO_COUNT + 1))
}

# Subcommand: Verify App
cmd_verify_app() {
    local target_app="${1:-$APP_PATH}"
    log_info "Verifying app bundle at $target_app..."

    [[ -d "$target_app" ]] || fail "App bundle missing at $target_app"

    # 1. Main executable presence check
    local main_exec="$target_app/Contents/MacOS/Torrentino"
    [[ -f "$main_exec" ]] || fail "Main app executable missing: $main_exec"
    file -b "$main_exec" | grep -q "Mach-O" || fail "Main executable is not Mach-O: $main_exec"

    # 2. Info.plist expectations against $VERSION and $BUILD_NUMBER
    local info_plist="$target_app/Contents/Info.plist"
    [[ -f "$info_plist" ]] || fail "App Info.plist missing: $info_plist"

    local short_ver bundle_ver bundle_id min_os
    short_ver=$(read_plist_key "$info_plist" CFBundleShortVersionString)
    bundle_ver=$(read_plist_key "$info_plist" CFBundleVersion)
    bundle_id=$(read_plist_key "$info_plist" CFBundleIdentifier)
    min_os=$(read_plist_key "$info_plist" LSMinimumSystemVersion)

    [[ "$short_ver" == "$VERSION" ]] || fail "App Info.plist CFBundleShortVersionString ('$short_ver') != $VERSION"
    [[ "$bundle_ver" == "$BUILD_NUMBER" ]] || fail "App Info.plist CFBundleVersion ('$bundle_ver') != $BUILD_NUMBER"
    [[ "$bundle_id" == "com.torrentino.app" ]] || fail "App Info.plist CFBundleIdentifier ('$bundle_id') != com.torrentino.app"
    [[ "$min_os" == "13.0" ]] || fail "App Info.plist LSMinimumSystemVersion ('$min_os') != 13.0"

    # 3. LaunchAgent layout, executable, and plist expectations
    local agent_dir="$target_app/Contents/Library/LaunchAgents"
    [[ -d "$agent_dir" ]] || fail "Embedded LaunchAgents directory missing: $agent_dir"

    local agent_exec="$agent_dir/TorrentinoEngineAgent"
    [[ -f "$agent_exec" ]] || fail "LaunchAgent executable missing: $agent_exec"
    file -b "$agent_exec" | grep -q "Mach-O" || fail "LaunchAgent executable is not Mach-O: $agent_exec"

    local agent_plist="$agent_dir/com.torrentino.app.engine-agent.plist"
    [[ -f "$agent_plist" ]] || fail "LaunchAgent plist missing: $agent_plist"

    local agent_label agent_prog mach_service
    agent_label=$(read_plist_key "$agent_plist" Label)
    [[ "$agent_label" == "com.torrentino.app.engine-agent" ]] || fail "LaunchAgent plist Label ('$agent_label') != com.torrentino.app.engine-agent"

    agent_prog=$(read_plist_key "$agent_plist" BundleProgram)
    [[ "$agent_prog" == "Contents/Library/LaunchAgents/TorrentinoEngineAgent" ]] || fail "LaunchAgent plist BundleProgram ('$agent_prog') != Contents/Library/LaunchAgents/TorrentinoEngineAgent"

    mach_service=$(/usr/libexec/PlistBuddy -c "Print :MachServices:com.torrentino.app.engine-agent.mach" "$agent_plist" 2>/dev/null || true)
    [[ "$mach_service" == "true" ]] || fail "LaunchAgent plist MachServices com.torrentino.app.engine-agent.mach is not true"

    # 4. Count Mach-O binaries (must include at least main + agent)
    MACHO_COUNT=0
    process_app_machos "$target_app" _count_macho
    (( MACHO_COUNT >= 2 )) || fail "Mach-O binary count ($MACHO_COUNT) is less than expected minimum of 2"
    log_info "Discovered $MACHO_COUNT Mach-O binary/binaries in $target_app."

    # 5. Process every Mach-O binary recursively
    process_app_machos "$target_app" _verify_single_macho

    # Deep code signature check on whole bundle
    codesign --verify --verbose=4 --deep --strict "$target_app" || fail "Deep codesign verification failed on bundle"

    log_info "App bundle verification passed successfully."
}

# Subcommand: Create Notarization ZIP
cmd_create_notarization_zip() {
    local target_app="${1:-$APP_PATH}"
    local output_zip="${2:-$ZIP_PATH}"

    log_info "Creating notarization ZIP from $target_app -> $output_zip..."
    [[ -d "$target_app" ]] || fail "App bundle missing: $target_app"

    mkdir -p "$(dirname "$output_zip")"
    ditto -c -k --keepParent "$target_app" "$output_zip" || fail "Failed to create ZIP with ditto"

    [[ -f "$output_zip" ]] || fail "Notarization ZIP missing: $output_zip"
    log_info "Notarization ZIP created successfully: $output_zip"
}

# Subcommand: Notarize App
cmd_notarize_app() {
    local zip_file="${1:-$ZIP_PATH}"
    local profile="${NOTARY_PROFILE:-}"

    if [[ -z "$profile" ]]; then
        fail "NOTARY_PROFILE environment variable is required for app notarization"
    fi

    mkdir -p "$NOTARIZATION_DIR"
    local submit_json="$NOTARIZATION_DIR/submit-app.json"
    local submission_id=""

    if [[ -f "$submit_json" ]]; then
        submission_id=$(jq -er '.id' "$submit_json" 2>/dev/null || true)
    fi

    local status=""
    if [[ -n "$submission_id" && "$submission_id" != "null" ]]; then
        log_info "Found recorded submission ID $submission_id; querying current status via notarytool wait..."
        local wait_json="$NOTARIZATION_DIR/wait-app-${submission_id}.json"
        xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout 60m --output-format json > "$wait_json"
        status=$(jq -er '.status' "$wait_json")
    else
        log_info "Submitting $zip_file for notarization using profile '$profile'..."
        xcrun notarytool submit "$zip_file" --keychain-profile "$profile" --wait --timeout 60m --output-format json > "$submit_json"
        submission_id=$(jq -er '.id' "$submit_json")
        status=$(jq -er '.status' "$submit_json")
    fi

    [[ -n "$submission_id" && "$submission_id" != "null" ]] || fail "Failed to obtain submission ID from notarization output"

    log_info "Fetching notarization log for submission ID $submission_id..."
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$NOTARIZATION_DIR/log-app-${submission_id}.json"

    if [[ "$status" != "Accepted" ]]; then
        fail "App notarization rejected with status: '$status'. See log at $NOTARIZATION_DIR/log-app-${submission_id}.json"
    fi

    log_info "App notarization succeeded (Status: Accepted, ID: $submission_id)."
}

# Verify hash & UUID bijection against pre-staple baseline using cmp/diff
verify_hashes_against_pre_staple() {
    local target_app="$1"
    log_info "Verifying executable SHA-256 hashes & UUIDs against pre-staple baseline for $target_app..."

    local pre_hash_file="${RELEASE_DIR}/pre_staple_hashes.txt"
    local pre_uuid_file="${RELEASE_DIR}/pre_staple_uuids.txt"
    [[ -f "$pre_hash_file" ]] || fail "Pre-staple hash baseline missing: $pre_hash_file"
    [[ -f "$pre_uuid_file" ]] || fail "Pre-staple UUID baseline missing: $pre_uuid_file"

    local curr_hash_tmp="${RELEASE_DIR}/current_hashes.tmp"
    local curr_uuid_tmp="${RELEASE_DIR}/current_uuids.tmp"
    rm -f "$curr_hash_tmp" "$curr_uuid_tmp"

    _record_current() {
        local macho="$1"
        local app_dir="$2"
        local rel_path="${macho#$app_dir/}"
        local hash
        hash=$(shasum -a 256 "$macho" | awk '{print $1}')
        echo "$hash  $rel_path" >> "$curr_hash_tmp"

        local norm_uuid
        norm_uuid=$(get_normalized_uuid "$macho" "$rel_path")
        echo "$norm_uuid" >> "$curr_uuid_tmp"
    }

    process_app_machos "$target_app" _record_current

    local curr_hash_file="${RELEASE_DIR}/current_hashes.txt"
    local curr_uuid_file="${RELEASE_DIR}/current_uuids.txt"
    sort -k2 "$curr_hash_tmp" > "$curr_hash_file"
    sort -k1 "$curr_uuid_tmp" > "$curr_uuid_file"
    rm -f "$curr_hash_tmp" "$curr_uuid_tmp"

    # Compare exact sorted hash and UUID baseline using cmp/diff
    if ! cmp -s "$pre_hash_file" "$curr_hash_file"; then
        log_error "Mach-O SHA-256 hash mismatch between baseline and current state:"
        diff -u "$pre_hash_file" "$curr_hash_file" >&2
        fail "Executable hash bijection failed"
    fi

    if ! cmp -s "$pre_uuid_file" "$curr_uuid_file"; then
        log_error "Mach-O UUID mismatch between baseline and current state:"
        diff -u "$pre_uuid_file" "$curr_uuid_file" >&2
        fail "Executable UUID bijection failed"
    fi

    rm -f "$curr_hash_file" "$curr_uuid_file"
    log_info "Pre-staple hash & UUID bijection verified successfully."
}

# Subcommand: Staple App
cmd_staple_app() {
    local target_app="${1:-$APP_PATH}"
    log_info "Stapling notarization ticket to $target_app..."

    [[ -d "$target_app" ]] || fail "App bundle missing: $target_app"
    xcrun stapler staple "$target_app" || fail "Stapling app failed"
    xcrun stapler validate "$target_app" || fail "Staple validation failed"

    log_info "App stapled and validated successfully."

    # Prove pre-staple executable content hashes immediately after stapling
    verify_hashes_against_pre_staple "$target_app"
}

# Subcommand: Package DMG
cmd_package_dmg() {
    local target_app="${1:-$APP_PATH}"
    local output_dmg="${2:-$DMG_PATH}"

    log_info "Packaging DMG from $target_app -> $output_dmg..."
    [[ -d "$target_app" ]] || fail "App bundle missing: $target_app"

    # Require app to be already stapled
    if ! xcrun stapler validate "$target_app" >/dev/null 2>&1; then
        fail "Cannot package DMG: App bundle $target_app is not stapled or staple validation failed"
    fi

    mkdir -p "$(dirname "$output_dmg")"
    rm -f "$output_dmg"

    # Staging directory for DMG using ditto (Torrentino.app + /Applications symlink)
    local staging_dir
    staging_dir=$(mktemp -d /tmp/torrentino-dmg-stage.XXXXXX)
    trap 'rm -rf "$staging_dir"' EXIT

    log_info "Staging stapled app bundle using ditto..."
    ditto "$target_app" "$staging_dir/Torrentino.app"
    ln -s /Applications "$staging_dir/Applications"

    log_info "Creating DMG image..."
    hdiutil create -volname "Torrentino" \
        -srcfolder "$staging_dir" \
        -ov -format UDZO \
        "$output_dmg" || fail "hdiutil create failed"

    rm -rf "$staging_dir"
    trap - EXIT

    [[ -f "$output_dmg" ]] || fail "DMG creation failed: $output_dmg missing"
    log_info "DMG packaged successfully: $output_dmg"
}

# Subcommand: Sign DMG
cmd_sign_dmg() {
    local target_dmg="${1:-$DMG_PATH}"
    log_info "Signing DMG: $target_dmg..."

    [[ -f "$target_dmg" ]] || fail "DMG missing: $target_dmg"
    codesign --force --sign "$DEVELOPER_ID_CERT" --timestamp "$target_dmg" || fail "Signing DMG failed"

    log_info "DMG signed successfully."
}

# Subcommand: Notarize DMG
cmd_notarize_dmg() {
    local target_dmg="${1:-$DMG_PATH}"
    local profile="${NOTARY_PROFILE:-}"

    if [[ -z "$profile" ]]; then
        fail "NOTARY_PROFILE environment variable is required for DMG notarization"
    fi

    mkdir -p "$NOTARIZATION_DIR"
    local submit_json="$NOTARIZATION_DIR/submit-dmg.json"
    local submission_id=""

    if [[ -f "$submit_json" ]]; then
        submission_id=$(jq -er '.id' "$submit_json" 2>/dev/null || true)
    fi

    local status=""
    if [[ -n "$submission_id" && "$submission_id" != "null" ]]; then
        log_info "Found recorded DMG submission ID $submission_id; querying current status via notarytool wait..."
        local wait_json="$NOTARIZATION_DIR/wait-dmg-${submission_id}.json"
        xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout 60m --output-format json > "$wait_json"
        status=$(jq -er '.status' "$wait_json")
    else
        log_info "Submitting $target_dmg for notarization using profile '$profile'..."
        xcrun notarytool submit "$target_dmg" --keychain-profile "$profile" --wait --timeout 60m --output-format json > "$submit_json"
        submission_id=$(jq -er '.id' "$submit_json")
        status=$(jq -er '.status' "$submit_json")
    fi

    [[ -n "$submission_id" && "$submission_id" != "null" ]] || fail "Failed to obtain submission ID for DMG notarization"

    log_info "Fetching DMG notarization log for submission ID $submission_id..."
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$NOTARIZATION_DIR/log-dmg-${submission_id}.json"

    if [[ "$status" != "Accepted" ]]; then
        fail "DMG notarization rejected with status: '$status'. See log at $NOTARIZATION_DIR/log-dmg-${submission_id}.json"
    fi

    log_info "DMG notarization succeeded (Status: Accepted, ID: $submission_id)."
}

# Subcommand: Staple DMG
cmd_staple_dmg() {
    local target_dmg="${1:-$DMG_PATH}"
    log_info "Stapling notarization ticket to DMG: $target_dmg..."

    [[ -f "$target_dmg" ]] || fail "DMG missing: $target_dmg"
    xcrun stapler staple "$target_dmg" || fail "Stapling DMG failed"
    xcrun stapler validate "$target_dmg" || fail "Staple validation on DMG failed"

    local sha_file="${target_dmg}.sha256"
    if [[ -f "$sha_file" ]]; then
        fail "DMG checksum file $sha_file already exists; checksum is write-once. Clean build directory to recreate."
    fi

    # Write ${DMG_PATH}.sha256 EXACTLY ONCE immediately after final stapler staple/validate
    log_info "Writing final DMG SHA-256 checksum file..."
    local dmg_dir dmg_base
    dmg_dir=$(dirname "$target_dmg")
    dmg_base=$(basename "$target_dmg")

    ( cd "$dmg_dir" && shasum -a 256 "$dmg_base" > "${dmg_base}.sha256" )
    ( cd "$dmg_dir" && shasum -c "${dmg_base}.sha256" ) || fail "Final DMG checksum verification failed"

    log_info "DMG stapled, validated, and checksum written successfully."
}

# Subcommand: Verify DMG
cmd_verify_dmg() {
    local target_dmg="${1:-$DMG_PATH}"
    log_info "Verifying signed/stapled DMG and mounted app: $target_dmg..."

    [[ -f "$target_dmg" ]] || fail "DMG missing: $target_dmg"

    # Require existing ${DMG_PATH}.sha256 file and run shasum -c (never rewrite)
    local sha_file="${target_dmg}.sha256"
    [[ -f "$sha_file" ]] || fail "DMG checksum file missing: $sha_file. Must be generated in staple-dmg."

    local dmg_dir dmg_base
    dmg_dir=$(dirname "$target_dmg")
    dmg_base=$(basename "$target_dmg")

    log_info "Verifying existing DMG SHA-256 checksum file ${dmg_base}.sha256..."
    ( cd "$dmg_dir" && shasum -c "${dmg_base}.sha256" ) || fail "DMG checksum verification failed against ${dmg_base}.sha256"

    # 1. hdiutil verify check
    log_info "Running hdiutil verify on DMG..."
    hdiutil verify "$target_dmg" || fail "hdiutil verify failed for $target_dmg"

    # 2. Gatekeeper status check
    log_info "Verifying Gatekeeper status..."
    local spctl_status
    spctl_status=$(spctl --status 2>&1 || true)
    if ! echo "$spctl_status" | grep -q "assessments enabled"; then
        fail "spctl assessments are disabled: $spctl_status"
    fi

    # 3. Verify DMG code signature & Team with verbose=4
    log_info "Verifying DMG code signature..."
    codesign --verify --verbose=4 --strict "$target_dmg" || fail "DMG codesign verification failed"

    local dmg_cs_details
    dmg_cs_details=$(codesign -dvvv "$target_dmg" 2>&1)
    if ! echo "$dmg_cs_details" | grep -q "TeamIdentifier=$TEAM_ID"; then
        fail "DMG signature TeamIdentifier does not match expected $TEAM_ID"
    fi
    if ! echo "$dmg_cs_details" | grep -q "Authority=$DEVELOPER_ID_CERT"; then
        fail "DMG signing authority does not match expected $DEVELOPER_ID_CERT"
    fi

    # 4. Verify DMG staple
    log_info "Verifying DMG staple..."
    xcrun stapler validate "$target_dmg" || fail "DMG staple validation failed"

    # 5. DMG spctl assessment (with verbose=4 & reject override=)
    log_info "Running spctl assessment on DMG..."
    local dmg_spctl
    dmg_spctl=$(spctl --assess --type open --context context:primary-signature --verbose=4 "$target_dmg" 2>&1 || true)

    if echo "$dmg_spctl" | grep -q "override="; then
        fail "Gatekeeper assessment contains forbidden override: $dmg_spctl"
    fi
    if ! echo "$dmg_spctl" | grep -q "accepted"; then
        fail "Gatekeeper assessment rejected DMG: $dmg_spctl"
    fi
    if ! echo "$dmg_spctl" | grep -q "source=Notarized Developer ID"; then
        fail "Gatekeeper assessment source is not Notarized Developer ID: $dmg_spctl"
    fi

    # 6. Robust mount and mounted app verification
    local mount_dir
    mount_dir=$(mktemp -d /tmp/torrentino-dmg-mount.XXXXXX)

    detach_mount() {
        if [[ -n "${mount_dir:-}" && -d "$mount_dir" ]]; then
            hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
            rm -rf "$mount_dir"
        fi
    }
    trap detach_mount EXIT

    log_info "Attaching DMG to temporary mount point: $mount_dir..."
    hdiutil attach -readonly -nobrowse "$target_dmg" -mountpoint "$mount_dir" || fail "Failed to mount DMG"

    local mounted_app="$mount_dir/Torrentino.app"
    [[ -d "$mounted_app" ]] || fail "Mounted DMG does not contain Torrentino.app"

    # Gatekeeper assessment on mounted app (with verbose=4)
    log_info "Assessing mounted app with Gatekeeper (spctl)..."
    local app_spctl
    app_spctl=$(spctl --assess --type execute --verbose=4 "$mounted_app" 2>&1 || true)
    if echo "$app_spctl" | grep -q "override="; then
        fail "Mounted app Gatekeeper assessment contains forbidden override: $app_spctl"
    fi
    if ! echo "$app_spctl" | grep -q "accepted"; then
        fail "Gatekeeper assessment rejected mounted app: $app_spctl"
    fi
    if ! echo "$app_spctl" | grep -q "source=Notarized Developer ID"; then
        fail "Gatekeeper assessment source is not Notarized Developer ID: $app_spctl"
    fi

    # Recursive Mach-O checks on mounted app
    cmd_verify_app "$mounted_app"

    # Verify executable SHA-256 hash & UUID bijection equality against pre-staple baseline
    verify_hashes_against_pre_staple "$mounted_app"

    detach_mount
    trap - EXIT

    log_info "DMG verification passed successfully."
}

# Helper: record evidence for a single Mach-O binary
_collect_macho_evidence() {
    local macho="$1"
    local target_app="$2"
    local rel="${macho#$target_app/}"

    local sig_file="$EVIDENCE_DIR/signatures.txt"
    local ent_file="$EVIDENCE_DIR/entitlements.txt"
    local arch_file="$EVIDENCE_DIR/architectures.txt"
    local minos_file="$EVIDENCE_DIR/minos.txt"
    local rpath_file="$EVIDENCE_DIR/rpaths.txt"
    local dep_file="$EVIDENCE_DIR/dependencies.txt"
    local uuid_file="$EVIDENCE_DIR/uuids.txt"

    echo "=== $rel ===" >> "$sig_file"
    codesign -dvvv "$macho" 2>&1 >> "$sig_file"

    echo "=== $rel ===" >> "$ent_file"
    local ent_out
    ent_out=$(codesign -d --entitlements :- "$macho" 2>&1 || true)
    if echo "$ent_out" | grep -qE "<plist|<dict|<key"; then
        echo "$ent_out" >> "$ent_file"
    else
        echo "(none)" >> "$ent_file"
    fi

    echo "$rel: $(lipo -archs "$macho")" >> "$arch_file"

    local otool_out
    otool_out=$(otool -l "$macho")

    echo "=== $rel ===" >> "$minos_file"
    local minos_info
    minos_info=$(echo "$otool_out" | grep -A4 -E "LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX" || true)
    [[ -n "$minos_info" ]] || fail "Failed to extract minOS evidence for $rel"
    echo "$minos_info" >> "$minos_file"

    echo "=== $rel ===" >> "$rpath_file"
    local rpath_info
    rpath_info=$(echo "$otool_out" | grep -A2 "LC_RPATH" || true)
    if [[ -n "$rpath_info" ]]; then
        echo "$rpath_info" >> "$rpath_file"
    else
        echo "(none)" >> "$rpath_file"
    fi

    echo "=== $rel ===" >> "$dep_file"
    otool -L "$macho" >> "$dep_file"

    echo "=== $rel ===" >> "$uuid_file"
    get_normalized_uuid "$macho" "$rel" >> "$uuid_file"
}

_collect_macho_sha() {
    local macho="$1"
    local sha_file="$EVIDENCE_DIR/sha256sums.txt"
    shasum -a 256 "$macho" >> "$sha_file"
}

# Subcommand: Collect Evidence
cmd_collect_evidence() {
    log_info "Collecting release build evidence under $EVIDENCE_DIR..."
    mkdir -p "$EVIDENCE_DIR"

    local sha_file="$EVIDENCE_DIR/sha256sums.txt"
    local uuid_file="$EVIDENCE_DIR/uuids.txt"
    local build_settings_file="$EVIDENCE_DIR/build-settings.txt"
    local xcode_ver_file="$EVIDENCE_DIR/xcode-version.txt"
    local sig_file="$EVIDENCE_DIR/signatures.txt"
    local ent_file="$EVIDENCE_DIR/entitlements.txt"
    local arch_file="$EVIDENCE_DIR/architectures.txt"
    local minos_file="$EVIDENCE_DIR/minos.txt"
    local rpath_file="$EVIDENCE_DIR/rpaths.txt"
    local dep_file="$EVIDENCE_DIR/dependencies.txt"
    local commit_file="$EVIDENCE_DIR/source-commit.txt"
    local dsym_file="$EVIDENCE_DIR/dsyms.txt"
    local manifest_file="$EVIDENCE_DIR/manifest-evidence.json"

    # Source commit from candidate chain of custody
    local candidate_commit_file="${RELEASE_DIR}/source_commit.txt"
    [[ -f "$candidate_commit_file" ]] || fail "Candidate source commit file missing: $candidate_commit_file. Run archive-export first."
    cp "$candidate_commit_file" "$commit_file"

    # Build settings & Xcode version
    xcodebuild -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'generic/platform=macOS' -showBuildSettings > "$build_settings_file"
    xcodebuild -version > "$xcode_ver_file"

    # dSYMs listing
    if [[ -d "$ARCHIVE_PATH/dSYMs" ]]; then
        find "$ARCHIVE_PATH/dSYMs" -type f > "$dsym_file"
    else
        echo "No dSYMs found in archive" > "$dsym_file"
    fi

    # Mach-O specific evidence
    rm -f "$sig_file" "$ent_file" "$arch_file" "$minos_file" "$rpath_file" "$dep_file" "$uuid_file"

    if [[ -d "$APP_PATH" ]]; then
        process_app_machos "$APP_PATH" _collect_macho_evidence
    fi

    # Final SHA256 file
    rm -f "$sha_file"
    if [[ -d "$APP_PATH" ]]; then
        process_app_machos "$APP_PATH" _collect_macho_sha
    fi
    if [[ -f "$ZIP_PATH" ]]; then
        shasum -a 256 "$ZIP_PATH" >> "$sha_file"
    fi
    if [[ -f "$DMG_PATH" ]]; then
        shasum -a 256 "$DMG_PATH" >> "$sha_file"
    fi
    if [[ -f "${DMG_PATH}.sha256" ]]; then
        shasum -a 256 "${DMG_PATH}.sha256" >> "$sha_file"
    fi

    # Manifest evidence JSON
    cat <<EOF > "$manifest_file"
{
  "product": "Torrentino",
  "version": "$VERSION",
  "build_number": "$BUILD_NUMBER",
  "team_id": "$TEAM_ID",
  "developer_id_cert": "$DEVELOPER_ID_CERT",
  "source_commit": "$(cat "$commit_file")",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "archive_path": "$ARCHIVE_PATH",
  "app_path": "$APP_PATH",
  "zip_path": "$ZIP_PATH",
  "dmg_path": "$DMG_PATH"
}
EOF

    log_info "Evidence collection completed at $EVIDENCE_DIR"
}

# Validate Sparkle toolchain pin and repository locks
validate_sparkle_pin() {
    log_info "Validating Sparkle toolchain pin and repository locks..."

    local appcast_bin="${SPARKLE_GENERATE_APPCAST:-}"
    local keys_bin="${SPARKLE_GENERATE_KEYS:-}"

    if [[ -z "$appcast_bin" || -z "$keys_bin" ]]; then
        fail "Environment variables SPARKLE_GENERATE_APPCAST and SPARKLE_GENERATE_KEYS are required and must be explicit absolute executable paths."
    fi

    [[ "$appcast_bin" == /* ]] || fail "SPARKLE_GENERATE_APPCAST must be an absolute path: $appcast_bin"
    [[ "$keys_bin" == /* ]] || fail "SPARKLE_GENERATE_KEYS must be an absolute path: $keys_bin"

    [[ -x "$appcast_bin" ]] || fail "SPARKLE_GENERATE_APPCAST executable not found: $appcast_bin"
    [[ -x "$keys_bin" ]] || fail "SPARKLE_GENERATE_KEYS executable not found: $keys_bin"

    local appcast_dir keys_dir
    appcast_dir=$(dirname "$appcast_bin")
    keys_dir=$(dirname "$keys_bin")

    if [[ "$appcast_dir" != "$keys_dir" ]]; then
        fail "SPARKLE_GENERATE_APPCAST and SPARKLE_GENERATE_KEYS must share the same bin directory ($appcast_dir vs $keys_dir)"
    fi

    local changelog="$appcast_dir/../CHANGELOG"
    [[ -f "$changelog" ]] || fail "Sparkle CHANGELOG missing at $changelog"
    if ! head -n 10 "$changelog" | grep -q "^# 2\.9\.6"; then
        fail "Sparkle CHANGELOG at $changelog first heading is not '# 2.9.6'"
    fi

    local resolved="Native/Torrentino.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    [[ -f "$resolved" ]] || fail "Package.resolved missing at $resolved"
    if ! grep -q "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a" "$resolved"; then
        fail "Package.resolved revision does not match expected Sparkle 2.9.6 commit ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
    fi

    local lock="Native/ThirdParty/versions.lock"
    [[ -f "$lock" ]] || fail "versions.lock missing at $lock"
    if ! grep -q 'SPARKLE_VERSION="2.9.6"' "$lock" || ! grep -q 'SPARKLE_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"' "$lock"; then
        fail "versions.lock does not match expected Sparkle 2.9.6 version/SHA256"
    fi

    log_info "Sparkle toolchain pin and repository locks validated successfully."
}

# Subcommand: Prepare Appcast
cmd_prepare_appcast() {
    local target_dmg="${1:-$DMG_PATH}"
    log_info "Preparing Sparkle appcast for $target_dmg..."

    [[ -f "$target_dmg" ]] || fail "DMG file missing: $target_dmg. Run release build & packaging first."

    # Require existing ${DMG_PATH}.sha256 file
    local sha_file="${target_dmg}.sha256"
    [[ -f "$sha_file" ]] || fail "DMG checksum file missing: $sha_file. Must be generated in staple-dmg."

    # Appcast pre-checks: hdiutil verify, codesign, stapler validate, and verify_dmg
    log_info "Running DMG pre-checks before appcast generation..."
    hdiutil verify "$target_dmg" || fail "DMG hdiutil verify failed"
    codesign --verify --verbose=4 --strict "$target_dmg" || fail "DMG codesign verify failed"
    xcrun stapler validate "$target_dmg" || fail "DMG stapler validate failed"
    cmd_verify_dmg "$target_dmg"

    # Validate Sparkle toolchain pin and locks
    validate_sparkle_pin

    # Verify public key binding against Info.plist SUPublicEDKey before generating appcast
    local plist_pubkey
    plist_pubkey=$(read_plist_key "Native/TorrentinoApp/Info.plist" SUPublicEDKey)
    [[ -n "$plist_pubkey" ]] || fail "SUPublicEDKey missing from Native/TorrentinoApp/Info.plist"

    log_info "Verifying Sparkle public key binding..."
    local keys_pubkey
    keys_pubkey=$("$SPARKLE_GENERATE_KEYS" --account Pavan-Gopa-Torrentino -p 2>/dev/null | xargs || true)
    plist_pubkey=$(echo "$plist_pubkey" | xargs)

    if [[ "$keys_pubkey" != "$plist_pubkey" ]]; then
        fail "Sparkle public key from SPARKLE_GENERATE_KEYS ('$keys_pubkey') does not exactly match Info.plist SUPublicEDKey ('$plist_pubkey')"
    fi
    log_info "Sparkle public key binding verified successfully."

    log_info "Staging DMG in clean appcast input directory..."
    local appcast_stage="$RELEASE_DIR/appcast_staging"
    rm -rf "$appcast_stage"
    mkdir -p "$appcast_stage"

    cp "$target_dmg" "$appcast_stage/"

    local expected_dmg_name
    expected_dmg_name=$(basename "$target_dmg")

    log_info "Invoking generate_appcast using $SPARKLE_GENERATE_APPCAST..."
    "$SPARKLE_GENERATE_APPCAST" \
        --account Pavan-Gopa-Torrentino \
        --download-url-prefix "https://github.com/Pavan-Gopa/Torrentino/releases/download/v${VERSION}/" \
        --link "https://github.com/Pavan-Gopa/Torrentino" \
        --versions "${BUILD_NUMBER}" \
        -o "$appcast_stage/appcast.xml" \
        "$appcast_stage" || fail "generate_appcast execution failed"

    [[ -f "$appcast_stage/appcast.xml" ]] || fail "generate_appcast did not produce appcast.xml"

    cp "$appcast_stage/appcast.xml" "$RELEASE_DIR/appcast.xml"
    rm -rf "$appcast_stage"

    # Require enclosure URL contains exact prefix + DMG basename, short/build versions, and EdDSA signature
    local appcast_content
    appcast_content=$(cat "$RELEASE_DIR/appcast.xml")

    local expected_url="https://github.com/Pavan-Gopa/Torrentino/releases/download/v${VERSION}/${expected_dmg_name}"
    if ! echo "$appcast_content" | grep -q "$expected_url"; then
        fail "Appcast XML enclosure URL does not match expected '$expected_url'"
    fi

    if ! echo "$appcast_content" | grep -qE "<sparkle:version>${BUILD_NUMBER}</sparkle:version>|sparkle:version=\"${BUILD_NUMBER}\""; then
        fail "Appcast XML missing expected build version '${BUILD_NUMBER}'"
    fi

    if ! echo "$appcast_content" | grep -qE "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>|sparkle:shortVersionString=\"${VERSION}\""; then
        fail "Appcast XML missing expected short version '${VERSION}'"
    fi

    if ! echo "$appcast_content" | grep -q "sparkle:edSignature"; then
        fail "Appcast XML missing sparkle:edSignature attribute"
    fi

    log_info "Appcast prepared and verified successfully at $RELEASE_DIR/appcast.xml"
}

# Subcommand: All (Driver)
cmd_all() {
    local dry_run="${DRY_RUN:-0}"
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
    fi

    log_info "Starting end-to-end release pipeline..."
    cmd_preflight
    cmd_archive_export
    cmd_verify_app
    cmd_create_notarization_zip

    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        cmd_notarize_app
        cmd_staple_app
        cmd_package_dmg
        cmd_sign_dmg
        cmd_notarize_dmg
        cmd_staple_dmg
        cmd_verify_dmg
        cmd_collect_evidence
        log_info "Release pipeline completed successfully."
    elif [[ "$dry_run" == "1" ]]; then
        cmd_collect_evidence
        log_info "STAGED CANDIDATE BUILT (Unsigned/Unnotarized - Not release-ready)."
    else
        fail "NOTARY_PROFILE environment variable is required to run the full release pipeline. Pass DRY_RUN=1 or --dry-run for staged candidate build without notarization."
    fi
}

# CLI Router
case "${1:-}" in
    preflight)
        cmd_preflight
        ;;
    archive-export)
        cmd_archive_export
        ;;
    verify-app)
        cmd_verify_app "${2:-$APP_PATH}"
        ;;
    create-notarization-zip)
        cmd_create_notarization_zip "${2:-$APP_PATH}" "${3:-$ZIP_PATH}"
        ;;
    notarize-app)
        cmd_notarize_app "${2:-$ZIP_PATH}"
        ;;
    staple-app)
        cmd_staple_app "${2:-$APP_PATH}"
        ;;
    package-dmg)
        cmd_package_dmg "${2:-$APP_PATH}" "${3:-$DMG_PATH}"
        ;;
    sign-dmg)
        cmd_sign_dmg "${2:-$DMG_PATH}"
        ;;
    notarize-dmg)
        cmd_notarize_dmg "${2:-$DMG_PATH}"
        ;;
    staple-dmg)
        cmd_staple_dmg "${2:-$DMG_PATH}"
        ;;
    verify-dmg)
        cmd_verify_dmg "${2:-$DMG_PATH}"
        ;;
    collect-evidence)
        cmd_collect_evidence
        ;;
    prepare-appcast)
        cmd_prepare_appcast "${2:-$DMG_PATH}"
        ;;
    all)
        cmd_all "${2:-}"
        ;;
    *)
        echo "Usage: $0 {preflight|archive-export|verify-app|create-notarization-zip|notarize-app|staple-app|package-dmg|sign-dmg|notarize-dmg|staple-dmg|verify-dmg|collect-evidence|prepare-appcast|all}"
        exit 1
        ;;
esac
