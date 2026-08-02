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

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
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

	// --- two-phase removal ------------------------------------------------------
	RemovalToken token;
	{
		const auto prepared = bridge.prepareRemoval(add_result.torrent_id, false);
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
			TH_REQUIRE(!committed.value().files_deleted, "files kept on removal");
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