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

// Deterministic three-file torrent for the WP22.D5 file-priority barrier.
// Metainfo order is alphabetical (a.bin, b.bin, c.bin) so a mixed vector is
// expressible as exact indices; the payload bytes are real so the engine has
// genuine metadata to hash-check against (WP-01 rule).
std::vector<char> make_multi_file_torrent_file(const std::filesystem::path& root)
{
	const std::vector<std::pair<const char*, std::size_t>> files = {
		{"a.bin", 256}, {"b.bin", 512}, {"c.bin", 256},
	};
	for (const auto& [name, size] : files) {
		std::ofstream out(root / name, std::ios::binary);
		for (std::size_t i = 0; i < size; ++i) {
			out.put(static_cast<char>(i % 251));
		}
	}

	const std::vector<lt::create_file_entry> entries = lt::list_files(root.string());
	lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
	creator.set_creator("Torrentino bridge smoke multi-file (WP22.D5)");

	lt::error_code ec;
	// list_files() prefixes every entry with the root directory name, so
	// piece hashing is anchored one level up (the containing directory).
	lt::set_piece_hashes(creator, root.parent_path().string(), ec);
	TH_REQUIRE(!ec, "set_piece_hashes (multi-file) must not fail");
	if (ec) {
		std::fprintf(stderr, "multi-file hash error: %s\n", ec.message().c_str());
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

	// --- WP22.D5 / ADR-022: mixed file-priority read-back barrier ---------------
	{
		const std::filesystem::path multi_root = workspace / "multi";
		std::error_code mkdir_ec;
		std::filesystem::create_directories(multi_root, mkdir_ec);
		const std::vector<char> multi = make_multi_file_torrent_file(multi_root);
		TH_REQUIRE(!multi.empty(), "multi-file torrent generation must succeed");

		// Remove the to-be-skipped payload before the add. Nothing may
		// recreate it: a reappearing file would prove libtorrent allocated or
		// wrote the skipped file.
		std::error_code rm_ec;
		std::filesystem::remove(multi_root / "b.bin", rm_ec);

		AddSpecification mspec;
		mspec.torrent_file = multi;
		mspec.save_path = workspace.string();
		mspec.paused = true;
		const auto madded = bridge.add(mspec);
		TH_REQUIRE(madded.is_ok(), "multi-file add must succeed");

		if (madded.is_ok()) {
			const torrentino::bridge::TorrentRecordID multi_id = madded.value().torrent_id;

			// Mixed vector in metainfo order: normal, skip, normal. Success is
			// only reported after the bounded exact get_file_priorities()
			// read-back, so this acknowledgement IS the read-back evidence.
			const auto applied = bridge.setFilePriorities(multi_id, {4, 0, 4});
			TH_REQUIRE(applied.is_ok(), "mixed priority application must pass the exact read-back");

			const auto unknown = bridge.setFilePriorities(std::string(64, '9'), {4, 0, 4});
			TH_REQUIRE(!unknown.is_ok(), "unknown id must fail closed");
			TH_REQUIRE(unknown.error_code() == BridgeError::not_found,
				"unknown id maps to not_found");

			const auto partial = bridge.setFilePriorities(multi_id, {4});
			TH_REQUIRE(!partial.is_ok(), "partial vectors must be rejected");
			TH_REQUIRE(partial.error_code() == BridgeError::invalid_argument,
				"partial vector maps to invalid_argument");

			const auto empty = bridge.setFilePriorities(multi_id, {});
			TH_REQUIRE(!empty.is_ok(), "empty vectors must be rejected");
			TH_REQUIRE(empty.error_code() == BridgeError::invalid_argument,
				"empty vector maps to invalid_argument");

			const auto out_of_range = bridge.setFilePriorities(multi_id, {4, 0, 8});
			TH_REQUIRE(!out_of_range.is_ok(), "out-of-range priorities must be rejected");
			TH_REQUIRE(out_of_range.error_code() == BridgeError::invalid_argument,
				"out-of-range priority maps to invalid_argument");

			std::error_code exists_ec;
			const bool skipped_allocated =
				std::filesystem::exists(multi_root / "b.bin", exists_ec);
			TH_REQUIRE(!skipped_allocated, "skipped file must not be allocated");
			std::printf("priority evidence: files=3 skip=1 normal=2 skipped_allocated=%s\n",
				skipped_allocated ? "true" : "false");

			const auto removed = bridge.prepareRemoval(multi_id);
			TH_REQUIRE(removed.is_ok(), "multi-file prepareRemoval must succeed");
			if (removed.is_ok()) {
				TH_REQUIRE(bridge.commitRemoval(removed.value()).is_ok(),
					"multi-file commitRemoval must succeed");
			}
		}
	}

	// --- WP22.D7 / ADR-022: metadata-only add and guarded commit ---------------
	{
		// Raw torrent_flags bits from torrent_status.flags (pinned 2.1.1):
		// upload_mode = 1_bit, paused = 4_bit, auto_managed = 5_bit.
		constexpr std::uint64_t kUploadMode = 1ull << 1;
		constexpr std::uint64_t kPaused = 1ull << 4;
		constexpr std::uint64_t kAutoManaged = 1ull << 5;

		// Latest flag sample for one id from a fresh drain (the pump emits a
		// live status sample per known torrent on every drain).
		const auto flagsFor = [](EngineBridge& engine,
			const torrentino::bridge::TorrentRecordID& id, std::int64_t& outFlags) {
			outFlags = -1;
			for (const EngineAlertDTO& alert : engine.drainAlerts(0)) {
				if (alert.torrent_id == id && alert.flags >= 0) {
					outFlags = alert.flags;
				}
			}
		};

		// (1) Multi-file .torrent added METADATA-ONLY: guard set, unpaused,
		// zero payload; wrong-shape and untracked commits fail closed; the
		// guarded [4,0,4] paused commit passes and releases the guard last.
		const std::filesystem::path meta_root = workspace / "meta";
		std::error_code mk_ec;
		std::filesystem::create_directories(meta_root, mk_ec);
		const std::vector<char> meta_multi = make_multi_file_torrent_file(meta_root);
		TH_REQUIRE(!meta_multi.empty(), "metadata-only multi-file torrent generation must succeed");
		// Allocation probe: nothing may recreate the skipped file.
		std::error_code rm_ec;
		std::filesystem::remove(meta_root / "b.bin", rm_ec);

		AddSpecification meta_spec;
		meta_spec.torrent_file = meta_multi;
		meta_spec.save_path = workspace.string();
		meta_spec.metadata_only = true;
		const auto meta_added = bridge.add(meta_spec);
		TH_REQUIRE(meta_added.is_ok(), "metadata-only add must succeed");

		if (meta_added.is_ok()) {
			const torrentino::bridge::TorrentRecordID meta_id = meta_added.value().torrent_id;

			std::int64_t pre_flags = -1;
			flagsFor(bridge, meta_id, pre_flags);
			TH_REQUIRE(pre_flags >= 0, "alert sample carries native flags");
			TH_REQUIRE((pre_flags & static_cast<std::uint64_t>(kUploadMode)) != 0,
				"upload_mode guard is set before commit");
			TH_REQUIRE((pre_flags & static_cast<std::uint64_t>(kAutoManaged)) == 0,
				"metadata-only add must never be auto-managed");
			TH_REQUIRE((pre_flags & static_cast<std::uint64_t>(kPaused)) == 0,
				"metadata-only add is unpaused regardless of spec.paused");

			const auto untracked = bridge.commitMetadataOnly(std::string(64, '7'), {4, 0, 4}, true);
			TH_REQUIRE(!untracked.is_ok(), "commit on an untracked id must fail closed");
			TH_REQUIRE(untracked.error_code() == BridgeError::not_found,
				"untracked commit maps to not_found");

			const auto wrong_shape = bridge.commitMetadataOnly(meta_id, {4, 0}, true);
			TH_REQUIRE(!wrong_shape.is_ok(), "wrong-shape priority vector must fail closed");
			TH_REQUIRE(wrong_shape.error_code() == BridgeError::invalid_argument,
				"wrong-shape vector maps to invalid_argument");
			std::int64_t kept_flags = -1;
			flagsFor(bridge, meta_id, kept_flags);
			TH_REQUIRE(kept_flags >= 0 && (kept_flags & static_cast<std::uint64_t>(kUploadMode)) != 0,
				"a failed commit keeps upload_mode set");

			// Success REQUIRES the exact read-back inside the same critical
			// section; the guard clears only afterwards.
			const auto committed = bridge.commitMetadataOnly(meta_id, {4, 0, 4}, true);
			TH_REQUIRE(committed.is_ok(), "guarded commit [4,0,4] paused must pass the barrier");

			std::int64_t post_flags = -1;
			flagsFor(bridge, meta_id, post_flags);
			TH_REQUIRE(post_flags >= 0 && (post_flags & static_cast<std::uint64_t>(kUploadMode)) == 0,
				"guard is released only after the exact read-back");
			TH_REQUIRE(post_flags >= 0 && (post_flags & static_cast<std::uint64_t>(kPaused)) != 0,
				"commit applies the requested paused state");
			std::error_code exists_ec;
			const bool skipped_allocated = std::filesystem::exists(meta_root / "b.bin", exists_ec);
			TH_REQUIRE(!skipped_allocated, "skipped file remains unallocated after commit");
			std::printf("metadata-only evidence: guard_before=%d guard_kept_on_failure=%d "
				"guard_cleared_after_commit=%d paused_applied=%d skipped_allocated=%s\n",
				pre_flags >= 0 && (pre_flags & kUploadMode) != 0 ? 1 : 0,
				kept_flags >= 0 && (kept_flags & kUploadMode) != 0 ? 1 : 0,
				post_flags >= 0 && (post_flags & kUploadMode) == 0 ? 1 : 0,
				post_flags >= 0 && (post_flags & kPaused) != 0 ? 1 : 0,
				skipped_allocated ? "true" : "false");

			const auto recommitted = bridge.commitMetadataOnly(meta_id, {4, 0, 4}, true);
			TH_REQUIRE(!recommitted.is_ok() && recommitted.error_code() == BridgeError::not_found,
				"double commit is rejected after promotion");

			// A durable/normal handle never passes the temporary-tracking check.
			const auto normal_handle = bridge.commitMetadataOnly(add_result.torrent_id, {4}, true);
			TH_REQUIRE(!normal_handle.is_ok() && normal_handle.error_code() == BridgeError::not_found,
				"commit on a normal handle is rejected");
		}

		// (2) Raw metadata-only magnet with unknown metainfo: unpaused metadata
		// networking with zero payload; premature commit fails closed; removal
		// cleans the temporary tracking. Metadata completion is NOT required.
		AddSpecification magnet_spec;
		magnet_spec.magnet_uri =
			"magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=wp22-d7-meta";
		magnet_spec.save_path = workspace.string();
		magnet_spec.metadata_only = true;
		const auto mag_added = bridge.add(magnet_spec);
		TH_REQUIRE(mag_added.is_ok(), "raw metadata-only magnet add must succeed");

		if (mag_added.is_ok()) {
			const torrentino::bridge::TorrentRecordID mag_id = mag_added.value().torrent_id;

			bool mag_guarded = false;
			bool mag_running = true;
			bool mag_zero_payload = true;
			for (const EngineAlertDTO& alert : bridge.drainAlerts(0)) {
				if (alert.torrent_id != mag_id) continue;
				if (alert.flags >= 0) {
					mag_guarded = mag_guarded || (static_cast<std::uint64_t>(alert.flags) & kUploadMode) != 0;
					if ((static_cast<std::uint64_t>(alert.flags) & kAutoManaged) != 0
						|| (static_cast<std::uint64_t>(alert.flags) & kPaused) != 0) {
						mag_running = false;
					}
				}
				if (alert.downloaded_bytes > 0) {
					mag_zero_payload = false;
				}
			}
			TH_REQUIRE(mag_guarded, "magnet metadata-only handle keeps upload_mode set");
			TH_REQUIRE(mag_running, "metadata retrieval runs unpaused and unmanaged");
			TH_REQUIRE(mag_zero_payload, "payload bytes stay zero before commit");

			const auto premature = bridge.commitMetadataOnly(mag_id, {4}, false);
			TH_REQUIRE(!premature.is_ok(), "premature commit without metainfo fails closed");
			TH_REQUIRE(premature.error_code() == BridgeError::invalid_argument,
				"premature commit maps to invalid_argument");
			std::int64_t mag_after_fail = -1;
			flagsFor(bridge, mag_id, mag_after_fail);
			TH_REQUIRE(mag_after_fail >= 0 && (mag_after_fail & static_cast<std::uint64_t>(kUploadMode)) != 0,
				"failed premature commit keeps the guard set");

			const auto prepared = bridge.prepareRemoval(mag_id);
			TH_REQUIRE(prepared.is_ok(), "temporary magnet prepareRemoval must succeed");
			if (prepared.is_ok()) {
				TH_REQUIRE(bridge.commitRemoval(prepared.value()).is_ok(),
					"temporary magnet commitRemoval must succeed");
			}
			TH_REQUIRE(wait_for_alert(bridge, 10s, [&mag_id](const EngineAlertDTO& alert) {
				return is_removed(alert) && alert.torrent_id == mag_id;
			}), "removed alert arrives for the temporary magnet");

			const auto post_remove = bridge.commitMetadataOnly(mag_id, {4}, false);
			TH_REQUIRE(!post_remove.is_ok() && post_remove.error_code() == BridgeError::not_found,
				"removal cleans the metadata-only tracking");
		}
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
