#!/usr/bin/env bash
#
# QA WP-07 — HTTPSourceFetcher limits (plan WP-07 #4).
#
# Verifies via TransferSmokeTests (URLProtocol stubs + 127.0.0.1 loopback
# python server for redirects; no external network):
#   * https and http succeed; ftp/file/gopher → .unsupportedScheme
#   * >5 redirects → .tooManyRedirects; exactly 5 → success
#   * redirect to unsupported scheme → .redirectToUnsupportedScheme
#   * body >10 MiB → .responseTooLarge (expected-length and streaming)
#   * deadline: a never-responding source aborts with .deadlineExceeded
#   * content-type allowlist: application/x-bittorrent OK, absent OK,
#     text/html → .unacceptableContentType; 404 → .nonSuccessStatus
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running HTTP source fetcher limit tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchSuccess \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchHTTPSchemeAllowed \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsUnsupportedScheme \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchAllowsExactlyFiveRedirects \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsMoreThanFiveRedirects \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsRedirectToUnsupportedScheme \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsOversizeBody \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchDeadlineEnforced \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchMissingContentTypeAllowed \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsWrongContentType \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsNonSuccess \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHTTPSourceFetchRejectsInvalidURL \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "HTTP source fetcher tests FAILED"
fi
qa_ok "HTTP scheme/redirect/size/deadline/content-type limits GREEN"

qa_pass
