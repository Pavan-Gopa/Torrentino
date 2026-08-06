// Torrentino engine bridge — headless smoke test (WP-04).
//
// Role: proves the full engine lifecycle through the public EngineBridge API
//       without a GUI or XPC: start → add (generated .torrent) → wait checked →
//       pause → resume → recheck → remove → shutdown. Exit 0 only on success.
// Must not: touch the network (loopback-only session, ephemeral port), fake
//       results, or exit 0 when any assertion fails.
// Invariants: exactly one assertion style (TH_REQUIRE below); every check runs
//       under a bounded wait so a hang surfaces as a timeout, not a stuck test.

#include "EngineBridge.h"

#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/torrent_info.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;
using torrentino::bridge::AddResult;
using torrentino::bridge::AddSpecification;
using torrentino::bridge::BootReport;
using torrentino::bridge::BridgeError;
using torrentino::bridge::EngineAlertDTO;
using torrentino::bridge::EngineBridge;
using torrentino::bridge::HealthDTO;
using torrentino::bridge::RemovalResult;
using torrentino::bridge::RemovalToken;
using torrentino::bridge::SessionConfiguration;
using torrentino::bridge::TorrentLimits;
using torrentino::bridge::TrackerTiers;

int g_failures = 0;

#define TH_REQUIRE(cond, what)                                                                     \
	do {                                                                                           \
		if (!(cond)) {                                                                             \
			std::fprintf(stderr, "FAIL: %s (line %d)\n", (what), __LINE__);                       \
			++g_failures;                                                                          \
		}                                                                                          \
	} while (0)

// Writes deterministic payload bytes and builds a v1 .torrent from them, so the
// engine has real metadata to hash-check against (no fake data, WP-01 rule).
std::vector<char> make_torrent_file(const std::filesystem::path& dir)
{
	const std::filesystem::path payload = dir / "payload.bin";
	{
		std::ofstream out(payload, std::ios::binary);
		for (int i = 0; i < 256; ++i) {
			out.put(static_cast<char>(i));
		}
	}
	const std::filesystem::path content_root = dir;
	const std::filesystem::path torrent_path = dir / "sample.torrent";

	// libtorrent 2.1 file_storage replacement: list_files + create_file_entry.
	const std::vector<lt::create_file_entry> entries = lt::list_files(payload.string());
	lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
	creator.set_creator("Torrentino bridge smoke (WP-04)");

	lt::error_code ec;
	lt::set_piece_hashes(creator, content_root.string(), ec);
	TH_REQUIRE(!ec, "set_piece_hashes must not fail");
	if (ec) {
		return {};
	}

	std::vector<char> buffer = creator.generate_buf();
	return buffer;
}

// A larger torrent for the cancellation test. save_resume_data flushes the
// disk cache before posting its alert, and at this size that flush provably
// outlives the shutdown handshake below, so the in-flight wait cannot win the
// race against shutdown() (no fast-path flake in CI).
std::vector<char> make_large_torrent_file(const std::filesystem::path& dir)
{
	const std::filesystem::path payload = dir / "payload-large.bin";
	{
		std::ofstream out(payload, std::ios::binary);
		const std::size_t size = 4u * 1024u * 1024u; // 4 MiB
		for (std::size_t i = 0; i < size; ++i) {
			out.put(static_cast<char>(i % 251));
		}
	}
	const std::filesystem::path content_root = dir;

	const std::vector<lt::create_file_entry> entries = lt::list_files(payload.string());
	lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
	creator.set_creator("Torrentino bridge smoke large (WP-04)");

	lt::error_code ec;
	lt::set_piece_hashes(creator, content_root.string(), ec);
	TH_REQUIRE(!ec, "set_piece_hashes (large) must not fail");
	if (ec) {
		return {};
	}

	return creator.generate_buf();
}

// Pumps alerts until a predicate matches or the deadline passes. Mirrors the
// harness wait_for_alert idiom with bridge-style bounded deadlines.
bool wait_for_alert(EngineBridge& bridge, std::chrono::milliseconds timeout,
	std::function<bool(const EngineAlertDTO&)> predicate)
{
	const auto deadline = std::chrono::steady_clock::now() + timeout;
	while (std::chrono::steady_clock::now() < deadline) {
		const std::vector<EngineAlertDTO> alerts = bridge.drainAlerts(0);
		for (const EngineAlertDTO& alert : alerts) {
			if (predicate(alert)) {
				return true;
			}
		}
		std::this_thread::sleep_for(10ms);
	}
	return false;
}

bool is_checked(const EngineAlertDTO& alert)
{
	return alert.kind == torrentino::bridge::EngineAlertKind::checked;
}

bool is_paused(const EngineAlertDTO& alert)
{
	return alert.kind == torrentino::bridge::EngineAlertKind::paused;
}

bool is_resumed(const EngineAlertDTO& alert)
{
	return alert.kind == torrentino::bridge::EngineAlertKind::resumed;
}

bool is_removed(const EngineAlertDTO& alert)
{
	return alert.kind == torrentino::bridge::EngineAlertKind::removed;
}

} // namespace

int main()
{
	// Isolated workspace under the bridge dir: the engine owns ~/Library/App
	// Support normally, but the headless test must stay hermetic and self-clean.
	std::filesystem::path workspace;
	{
		const char* tmp = std::getenv("TMPDIR");
		workspace = (tmp != nullptr && *tmp != '\0') ? std::filesystem::path(tmp) : "/tmp";
		workspace /= "torrentino-bridge-smoke";
		std::error_code ec;
		std::filesystem::remove_all(workspace, ec);
		std::filesystem::create_directories(workspace, ec);
	}

	EngineBridge bridge;

	// --- start ---------------------------------------------------------------
	{
		SessionConfiguration config;
		config.listen_port = 0; // ephemeral loopback
		config.download_dir = workspace.string();
		config.enable_dht = false;
		config.operation_timeout_ms = 10000;

		const auto report = bridge.start(config);
		TH_REQUIRE(report.is_ok(), "start must succeed");
		if (report.is_ok()) {
			TH_REQUIRE(report.value().listen_port > 0, "boot report carries a bound port");
		}
	}

	// --- health / already-started guard ---------------------------------------
	{
		const HealthDTO health = bridge.health();
		TH_REQUIRE(health.running, "health reports running engine");
		TH_REQUIRE(health.active_torrents == 0, "no torrents yet");
		const auto second_start = bridge.start(SessionConfiguration{});
		TH_REQUIRE(!second_start.is_ok(), "double start must fail");
		TH_REQUIRE(second_start.error_code() == BridgeError::already_started,
			"double start maps to already_started");
	}

	// --- add ------------------------------------------------------------------
	AddResult add_result;
	{
		const std::vector<char> torrent = make_torrent_file(workspace);
		TH_REQUIRE(!torrent.empty(), "torrent file generation must succeed");
		AddSpecification spec;
		spec.torrent_file = torrent;
		spec.save_path = workspace.string();
		spec.paused = false;

		const auto result = bridge.add(spec);
		TH_REQUIRE(result.is_ok(), "add must succeed");
		if (result.is_ok()) {
			add_result = result.value();
			TH_REQUIRE(!add_result.torrent_id.empty(), "add result carries a torrent id");
		}
	}

	// --- checked (hash check completes) ----------------------------------------
	{
		TH_REQUIRE(wait_for_alert(bridge, 30s, is_checked), "torrent becomes checked");
	}

	// --- pause / resume / recheck ----------------------------------------------
	{
		const auto pause = bridge.pause(add_result.torrent_id);
		TH_REQUIRE(pause.is_ok(), "pause must succeed");
		TH_REQUIRE(wait_for_alert(bridge, 10s, is_paused), "pause alert arrives");

		const auto resume = bridge.resume(add_result.torrent_id);
		TH_REQUIRE(resume.is_ok(), "resume must succeed");
		TH_REQUIRE(wait_for_alert(bridge, 10s, is_resumed), "resume alert arrives");

		const auto recheck = bridge.requestRecheck(add_result.torrent_id);
		TH_REQUIRE(recheck.is_ok(), "recheck must succeed");
		TH_REQUIRE(wait_for_alert(bridge, 30s, is_checked), "recheck completes");
	}

	// --- live session settings --------------------------------------------------
	{
		SessionConfiguration applied;
		applied.download_dir = (workspace / "next-downloads").string();
		applied.enable_dht = false;
		applied.enable_lsd = false;
		applied.enable_upnp = false;
		applied.enable_natpmp = false;
		applied.encryption_enabled = true;
		applied.max_download_bytes_per_sec = 4096;
		applied.max_upload_bytes_per_sec = 2048;
		const auto result = bridge.apply(applied);
		TH_REQUIRE(result.is_ok(), "live session settings apply must succeed");
	}

	// --- per-torrent controls and explicit unsupported distinction --------------
	{
		TorrentLimits bandwidth;
		bandwidth.max_download_bytes_per_sec = 8192;
		bandwidth.max_upload_bytes_per_sec = 4096;
		const auto limits = bridge.setLimits(add_result.torrent_id, bandwidth);
		TH_REQUIRE(limits.is_ok(), "per-torrent bandwidth limits must apply");
		const auto appliedLimits = bridge.currentLimits(add_result.torrent_id);
		TH_REQUIRE(appliedLimits.is_ok(), "native bandwidth limits must be readable");
		if (appliedLimits.is_ok()) {
			TH_REQUIRE(appliedLimits.value().max_download_bytes_per_sec == 8192,
				"native download limit must match the applied value");
			TH_REQUIRE(appliedLimits.value().max_upload_bytes_per_sec == 4096,
				"native upload limit must match the applied value");
		}

		TorrentLimits invalidBandwidth;
		invalidBandwidth.max_download_bytes_per_sec = -1;
		const auto negative = bridge.setLimits(add_result.torrent_id, invalidBandwidth);
		TH_REQUIRE(!negative.is_ok(), "negative bandwidth limit must be rejected");
		TH_REQUIRE(negative.error_code() == BridgeError::invalid_argument,
			"negative bandwidth limit maps to invalid_argument");

		TorrentLimits overflowBandwidth;
		overflowBandwidth.max_upload_bytes_per_sec = std::numeric_limits<std::int64_t>::max();
		const auto overflow = bridge.setLimits(add_result.torrent_id, overflowBandwidth);
		TH_REQUIRE(!overflow.is_ok(), "overflow bandwidth limit must be rejected");
		TH_REQUIRE(overflow.error_code() == BridgeError::invalid_argument,
			"overflow bandwidth limit maps to invalid_argument");

		TorrentLimits nonFiniteRatio;
		nonFiniteRatio.ratio_limit = std::numeric_limits<double>::quiet_NaN();
		const auto nonFinite = bridge.setLimits(add_result.torrent_id, nonFiniteRatio);
		TH_REQUIRE(!nonFinite.is_ok(), "non-finite ratio goal must be rejected");
		TH_REQUIRE(nonFinite.error_code() == BridgeError::invalid_argument,
			"non-finite ratio goal maps to invalid_argument");

		TorrentLimits nativeRange;
		nativeRange.seed_time_seconds = std::numeric_limits<std::int64_t>::max();
		const auto nativeRangeFailure = bridge.setLimits(add_result.torrent_id, nativeRange);
		TH_REQUIRE(!nativeRangeFailure.is_ok(), "out-of-native seed range must be rejected");
		TH_REQUIRE(nativeRangeFailure.error_code() == BridgeError::invalid_argument,
			"out-of-native seed range maps to invalid_argument");

		TorrentLimits unsupported;
		unsupported.ratio_limit = 1.5;
		const auto ratio = bridge.setLimits(add_result.torrent_id, unsupported);
		TH_REQUIRE(!ratio.is_ok(), "unsupported ratio goal must not report success");
		TH_REQUIRE(ratio.error_code() == BridgeError::unsupported_operation,
			"unsupported ratio goal maps to typed unsupported_operation");

		TorrentLimits unsupportedSeedTime;
		unsupportedSeedTime.seed_time_seconds = 3600;
		const auto seedTime = bridge.setLimits(add_result.torrent_id, unsupportedSeedTime);
		TH_REQUIRE(!seedTime.is_ok(), "unsupported seed-time goal must not report success");
		TH_REQUIRE(seedTime.error_code() == BridgeError::unsupported_operation,
			"unsupported seed-time goal maps to typed unsupported_operation");

		// ADR-017: tracker edits carry the structured [[String]] topology
		// (TrackerTiers); the scalar overload is a reject-only stub.
		const auto trackers = bridge.editTrackers(add_result.torrent_id,
			TrackerTiers{{"udp://127.0.0.1:1/announce"}});
		TH_REQUIRE(trackers.is_ok(), "tracker replacement must apply");
		const auto validIPv6Tracker = bridge.editTrackers(add_result.torrent_id,
			TrackerTiers{{"udp://[2001:db8::1]:1/announce"}});
		TH_REQUIRE(validIPv6Tracker.is_ok(), "well-formed IPv6 tracker URL must apply");
		const std::vector<std::string> invalidTrackerURLs = {
			"not-a-tracker-url",
			"https://256.1.1.1/announce",
			"https://127.0.0/announce",
			"https://tracker..example/announce",
			"https://-tracker.example/announce",
			"https://[2001:db8:::1]/announce",
			"https://[2001:db8:0:0:0:0:0:0:1]/announce",
			"https://[2001:db8:gg::1]/announce",
			"https://127.0.0.1:0/announce",
			"https://127.0.0.1:65536/announce",
			"https://127.0.0.1:abc/announce",
			"ftp://127.0.0.1/announce",
			"https://127.0.0.1/ann%GGounce",
			"https://127.0.0.1/announce%",
			"https://127.0.0.1/ann\nounce",
		};
		for (const std::string& invalidURL : invalidTrackerURLs) {
			const auto invalidTracker = bridge.editTrackers(add_result.torrent_id,
				TrackerTiers{{invalidURL}});
			TH_REQUIRE(!invalidTracker.is_ok(), "malformed tracker URL must be rejected");
			TH_REQUIRE(invalidTracker.error_code() == BridgeError::invalid_argument,
				"malformed tracker URL maps to invalid_argument");
		}
		const auto emptyTrackers = bridge.editTrackers(add_result.torrent_id, TrackerTiers{});
		TH_REQUIRE(emptyTrackers.is_ok(), "explicitly empty tracker list must apply");
		const auto reannounce = bridge.reannounce(add_result.torrent_id);
		TH_REQUIRE(reannounce.is_ok(), "reannounce must reach the torrent handle");
	}

	// --- missing id error path -------------------------------------------------
	{
		const auto pause = bridge.pause(std::string(64, '0'));
		TH_REQUIRE(!pause.is_ok(), "pause of unknown id must fail");
		TH_REQUIRE(pause.error_code() == BridgeError::not_found, "unknown id maps to not_found");
	}

	// --- resume data ------------------------------------------------------------
	{
		const auto resume = bridge.requestResumeData(add_result.torrent_id);
		TH_REQUIRE(resume.is_ok(), "requestResumeData must succeed");
		if (resume.is_ok()) {
			TH_REQUIRE(!resume.value().resume_data.empty(), "resume data is non-empty");
		}
	}

	// --- deadline: a bounded wait must surface BridgeError::timeout ---------------
	{
		const auto timeout_set = bridge.setOperationTimeout(1);
		TH_REQUIRE(timeout_set.is_ok(), "setOperationTimeout(1) must succeed");
		const auto resume = bridge.requestResumeData(add_result.torrent_id);
		TH_REQUIRE(!resume.is_ok(), "requestResumeData under a 1ms deadline must time out");
		TH_REQUIRE(resume.error_code() == BridgeError::timeout,
			"expired deadline maps to BridgeError::timeout");
		const auto restore = bridge.setOperationTimeout(10000);
		TH_REQUIRE(restore.is_ok(), "restoring the operation deadline must succeed");
	}

	// --- two-phase removal ------------------------------------------------------
	RemovalToken token;
	{
		// WP-10 (Gate 6): prepareRemoval carries no delete-files flag — the
		// bridge cannot permanently delete payload bytes by construction.
		const auto prepared = bridge.prepareRemoval(add_result.torrent_id);
		TH_REQUIRE(prepared.is_ok(), "prepareRemoval must succeed");
		if (prepared.is_ok()) {
			token = prepared.value();
			TH_REQUIRE(token.torrent_id == add_result.torrent_id, "token carries the torrent id");
		}
		const auto committed = bridge.commitRemoval(token);
		TH_REQUIRE(committed.is_ok(), "commitRemoval must succeed");
		if (committed.is_ok()) {
			TH_REQUIRE(committed.value().torrent_id == add_result.torrent_id,
				"removal result carries the torrent id");
		}
		TH_REQUIRE(wait_for_alert(bridge, 10s, is_removed), "removed alert arrives");
	}

	// --- drain-batch semantics --------------------------------------------------
	{
		// A batch drains to zero: identical second call returns nothing left.
		const std::vector<EngineAlertDTO> empty = bridge.drainAlerts(0);
		TH_REQUIRE(empty.empty(), "second drain returns empty batch");
	}

	// --- shutdown + idempotence -------------------------------------------------
	{
		bridge.shutdown();
		bridge.shutdown(); // must be a no-op, not a crash
		const HealthDTO health = bridge.health();
		TH_REQUIRE(!health.running, "health reports stopped engine");
	}

	// --- cancellation: shutdown unblocks an in-flight bounded wait -----------------
	// A second engine waits on requestResumeData (large torrent so the resume-data
	// flush cannot beat the shutdown handshake); shutdown() must release the wait
	// with BridgeError::stopped and the waiter must return without hanging.
	{
		EngineBridge second;
		SessionConfiguration config2;
		config2.download_dir = workspace.string();
		config2.enable_dht = false;
		config2.operation_timeout_ms = 10000;

		const auto report2 = second.start(config2);
		TH_REQUIRE(report2.is_ok(), "cancellation engine start must succeed");
		const std::vector<char> big = make_large_torrent_file(workspace);
		TH_REQUIRE(!big.empty(), "large torrent generation must succeed");
		AddSpecification spec2;
		spec2.torrent_file = big;
		spec2.save_path = workspace.string();
		spec2.paused = false;
		const auto added2 = second.add(spec2);
		TH_REQUIRE(added2.is_ok(), "cancellation engine add must succeed");
		const std::string id2 = added2.value().torrent_id;

		std::atomic<bool> entered{false};
		std::atomic<bool> finished{false};
		std::atomic<torrentino::bridge::BridgeError> outcome{BridgeError::none};
		std::thread waiter([&] {
			entered.store(true);
			const auto result = second.requestResumeData(id2);
			outcome.store(result.error_code());
			finished.store(true);
		});
		// Handshake: wait until the waiter is inside requestResumeData, then give
		// it a few ms to release the operation mutex and sleep in wait_wake_.
		while (!entered.load()) {
			std::this_thread::sleep_for(100us);
		}
		std::this_thread::sleep_for(5ms);
		second.shutdown();

		// Bounded join: the waiter must be unblocked by shutdown, never hang.
		const auto deadline = std::chrono::steady_clock::now() + 10s;
		while (!finished.load() && std::chrono::steady_clock::now() < deadline) {
			std::this_thread::sleep_for(10ms);
		}
		TH_REQUIRE(finished.load(), "in-flight requestResumeData returns after shutdown (no hang)");
		waiter.join();
		TH_REQUIRE(outcome.load() == BridgeError::stopped,
			"shutdown during a bounded wait maps to BridgeError::stopped");
	}

	// --- cleanup ---------------------------------------------------------------
	std::error_code ec;
	std::filesystem::remove_all(workspace, ec);

	if (g_failures != 0) {
		std::fprintf(stderr, "bridge smoke: %d failure(s)\n", g_failures);
		return 1;
	}
	std::printf("bridge smoke: PASS\n");
	return 0;
}
