// Torrentino engine bridge — alert dump debug helper (temporary, WP-04).
//
// Role: prints every alert converted by the bridge after adding a torrent so
//       the smoke test's missing alerts can be diagnosed.
#include "EngineBridge.h"

#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/load_torrent.hpp>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

int main()
{
	using namespace std::chrono_literals;
	namespace fs = std::filesystem;
	using torrentino::bridge::EngineAlertDTO;
	using torrentino::bridge::EngineBridge;
	using torrentino::bridge::SessionConfiguration;

	fs::path workspace = fs::temp_directory_path() / "torrentino-alert-dump";
	std::error_code ec;
	fs::remove_all(workspace, ec);
	fs::create_directories(workspace, ec);

	const fs::path payload = workspace / "payload.bin";
	{
		std::ofstream out(payload, std::ios::binary);
		for (int i = 0; i < 256; ++i) {
			out.put(static_cast<char>(i));
		}
	}
	const std::vector<lt::create_file_entry> entries = lt::list_files(payload.string());
	lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
	creator.set_creator("Torrentino alert dump (WP-04)");
	lt::error_code lec;
	lt::set_piece_hashes(creator, workspace.string(), lec);
	const std::vector<char> torrent = creator.generate_buf();

	EngineBridge bridge;
	SessionConfiguration config;
	config.download_dir = workspace.string();
	config.operation_timeout_ms = 8000;
	const auto report = bridge.start(config);
	std::printf("start: ok=%d port=%d\n", report.is_ok(),
		report.is_ok() ? report.value().listen_port : -1);

	torrentino::bridge::AddSpecification spec;
	spec.torrent_file = torrent;
	spec.save_path = workspace.string();
	spec.paused = false;
	const auto added = bridge.add(spec);
	std::printf("add: ok=%d id=%s\n", added.is_ok(),
		added.is_ok() ? added.value().torrent_id.c_str() : "-");

	const auto deadline = std::chrono::steady_clock::now() + 5s;
	int count = 0;
	while (std::chrono::steady_clock::now() < deadline) {
		const std::vector<EngineAlertDTO> alerts = bridge.drainAlerts(0);
		for (const EngineAlertDTO& a : alerts) {
			std::printf("alert[%d] kind=%d torrent=%s msg=%s\n", count++,
				static_cast<int>(a.kind), a.torrent_id.c_str(), a.message.c_str());
		}
		std::this_thread::sleep_for(50ms);
	}

	const auto removed = bridge.prepareRemoval(added.value().torrent_id, false);
	std::printf("prepareRemoval: ok=%d\n", removed.is_ok());
	const auto committed = bridge.commitRemoval(removed.value());
	std::printf("commitRemoval: ok=%d\n", committed.is_ok());
	const auto end = std::chrono::steady_clock::now() + 3s;
	while (std::chrono::steady_clock::now() < end) {
		const std::vector<EngineAlertDTO> alerts = bridge.drainAlerts(0);
		for (const EngineAlertDTO& a : alerts) {
			std::printf("alert[%d] kind=%d torrent=%s msg=%s\n", count++,
				static_cast<int>(a.kind), a.torrent_id.c_str(), a.message.c_str());
		}
		std::this_thread::sleep_for(50ms);
	}

	bridge.shutdown();
	fs::remove_all(workspace, ec);
	return 0;
}