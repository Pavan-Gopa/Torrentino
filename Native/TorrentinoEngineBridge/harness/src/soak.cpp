// Torrentino engine harness — long-running soak (WP-01).
// See soak.hpp for the role of this module.
#include "torrentino/harness/soak.hpp"

#include "torrentino/harness/engine_ops.hpp"

#include <libtorrent/address.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/torrent_flags.hpp>

#include <csignal>
#include <memory>
#include <sstream>

namespace torrentino::harness {
namespace {

// Set from a signal handler: async-signal-safe, checked between iterations so a
// Ctrl-C or `launchctl stop` produces a clean report instead of a lost run.
volatile std::sig_atomic_t g_stop_requested = 0;

extern "C" void on_stop_signal(int) { g_stop_requested = 1; }

struct SoakStats {
	std::uint64_t iterations{0};
	std::uint64_t bytes_transferred{0};
	std::uint64_t torrents_created{0};
	std::uint64_t resume_restores{0};
	std::uint64_t session_recycles{0};
	std::uint64_t alerts{0};
	std::uint64_t error_alerts{0};
	std::uint64_t rss_start{0};
	std::uint64_t rss_peak{0};
	std::uint64_t rss_last{0};
	Millis slowest_iteration{0};
	Millis elapsed{0};
};

Protocol protocol_for(std::uint64_t iteration) noexcept
{
	switch (iteration % 3) {
	case 0: return Protocol::hybrid;
	case 1: return Protocol::v1;
	default: return Protocol::v2;
	}
}

std::int64_t payload_size_for(std::uint64_t iteration) noexcept
{
	constexpr std::int64_t kMiB = 1024 * 1024;
	static const std::int64_t sizes[] = {1 * kMiB, 2 * kMiB, 4 * kMiB, 8 * kMiB};
	return sizes[iteration % 4];
}

// Deterministic disk-I/O barrier: wait until libtorrent has flushed every
// outstanding write for `handle` to the operating system. See the call site in
// run_cycle for why this — not save_resume_data(flush_disk_cache) — is what
// makes the subsequent sha256_file_hex read race-free. cache_flushed_alert is in
// alert_category::storage, which the session fixture already enables.
void flush_torrent_to_disk(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	handle.flush_cache();
	session.wait_for_alert(timeout, "cache_flushed_alert (disk I/O drained)",
		[&handle](const lt::alert& alert) {
			const auto* flushed = lt::alert_cast<lt::cache_flushed_alert>(&alert);
			return flushed != nullptr && flushed->handle == handle;
		});
}

// One full lifecycle: create → seed → download → verify → resume round-trip →
// pause/resume → remove. Any deviation throws and fails the soak.
std::int64_t run_cycle(LocalSwarm& swarm, const fs::path& root, std::uint64_t iteration,
	Millis timeout, SoakStats& stats)
{
	const fs::path seed_dir = root / cat("seed-", iteration);
	const fs::path leech_dir = root / cat("leech-", iteration);
	std::error_code ec;
	fs::create_directories(seed_dir, ec);
	fs::create_directories(leech_dir, ec);

	TorrentSpec spec;
	spec.protocol = protocol_for(iteration);
	spec.name = cat("soak-", iteration, ".bin");
	spec.size = payload_size_for(iteration);
	spec.piece_size = 64 * 1024;
	spec.seed = 0xA5A5ULL + iteration;

	const CreatedTorrent torrent = create_payload_torrent(seed_dir, spec);
	++stats.torrents_created;

	const lt::torrent_handle seed = add_torrent(swarm.seeder(), atp_for(torrent, seed_dir), timeout);
	wait_until_seeding(swarm.seeder(), seed, timeout);

	lt::add_torrent_params atp = atp_for(torrent, leech_dir);
	atp.peers.emplace_back(lt::make_address_v4("127.0.0.1"),
		static_cast<std::uint16_t>(swarm.seeder_port()));
	lt::torrent_handle leech = add_torrent(swarm.leecher(), std::move(atp), timeout);
	const lt::torrent_status finished = wait_until_finished(swarm.leecher(), leech, timeout);
	if (finished.total_done != torrent.total_size) {
		throw AssertionFailure(cat("iteration ", iteration, ": downloaded ", finished.total_done,
			" of ", torrent.total_size));
	}
	// Deterministic disk-I/O barrier. `wait_until_finished` only proves the piece
	// picker holds every piece (received + hash-checked); the final pwrite() jobs
	// can still be queued on libtorrent's async disk thread when it returns.
	// Reading the file with plain std::ifstream at that instant races the disk
	// thread and, under sustained soak load, occasionally sees incomplete bytes —
	// the root cause of the intermittent "payload digest mismatch". flush_cache()
	// + cache_flushed_alert is libtorrent's documented guarantee that "whatever
	// cached data libtorrent had by the time you called flush_cache() has been
	// written to disk", i.e. the exact barrier the digest comparison needs.
	// (The previous fix — save_resume_data(flush_disk_cache) — did NOT provide it:
	// that flag only corrects resume-data timestamps, and save_resume_data_alert
	// fires when the resume buffer is built, not when the torrent's writes land.)
	flush_torrent_to_disk(swarm.leecher(), leech, timeout);

	// Resume round-trip on live data: this is the operation the agent performs on
	// every checkpoint, so it is the one most likely to leak or corrupt.
	const std::vector<char> resume = save_resume_data(swarm.leecher(), leech, timeout);

	const fs::path leech_file = leech_dir / torrent.name;
	const std::string actual_sha256 = sha256_file_hex(leech_file);
	if (actual_sha256 != torrent.payload_sha256) {
		// A mismatch AFTER the disk barrier would mean genuine data corruption, not
		// a read-before-flush race, so capture everything needed to tell the two
		// apart in a post-mortem: expected vs actual hash, on-disk size vs expected
		// size, and when the file was last written.
		std::error_code stat_ec;
		const std::uintmax_t file_size = fs::file_size(leech_file, stat_ec);
		const fs::file_time_type last_write = fs::last_write_time(leech_file, stat_ec);
		const auto last_write_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
			last_write.time_since_epoch()).count();
		log_error(cat("iteration ", iteration, ": payload digest mismatch | expected=",
			torrent.payload_sha256, " actual=", actual_sha256, " file=", leech_file.string(),
			" size=", (stat_ec ? std::string("<unavailable>")
				: std::to_string(static_cast<unsigned long long>(file_size))),
			" expected_size=", torrent.total_size,
			" last_write_ms_since_epoch=", last_write_ms));
		throw AssertionFailure(cat("iteration ", iteration, ": payload digest mismatch (expected ",
			torrent.payload_sha256, ", got ", actual_sha256, ')'));
	}
	remove_torrent_keep_files(swarm.leecher(), leech, timeout);
	lt::error_code parse_ec;
	lt::add_torrent_params restored = lt::read_resume_data(resume, parse_ec);
	if (parse_ec) {
		throw AssertionFailure(cat("iteration ", iteration, ": resume data unreadable: ",
			parse_ec.message()));
	}
	apply_deterministic_flags(restored);
	if (!restored.ti) {
		restored.ti = lt::load_torrent_buffer(torrent.bencoded).ti;
	}
	leech = add_torrent(swarm.leecher(), std::move(restored), timeout);
	const lt::torrent_status rechecked = wait_until_checked(swarm.leecher(), leech, timeout);
	if (rechecked.total_done != torrent.total_size) {
		throw AssertionFailure(cat("iteration ", iteration, ": restore lost data (",
			rechecked.total_done, " of ", torrent.total_size, ')'));
	}
	++stats.resume_restores;

	leech.pause();
	swarm.leecher().wait_for_status(leech, timeout, "soak torrent to pause",
		[](const lt::torrent_status& status) {
			return (status.flags & lt::torrent_flags::paused) != lt::torrent_flags_t{};
		});
	leech.resume();

	remove_torrent_keep_files(swarm.leecher(), leech, timeout);
	remove_torrent_keep_files(swarm.seeder(), seed, timeout);
	fs::remove_all(seed_dir, ec);
	fs::remove_all(leech_dir, ec);
	return torrent.total_size;
}

void write_report(const SoakOptions& options, const SoakStats& stats, const Outcome& outcome)
{
	if (options.report_path.empty()) {
		return;
	}
	std::ostringstream out;
	out << "{\n"
		<< "  \"generated_at\": \"" << iso8601_utc_now() << "\",\n"
		<< "  \"status\": \"" << status_name(outcome.status) << "\",\n"
		<< "  \"message\": \"" << outcome.message << "\",\n"
		<< "  \"elapsed_ms\": " << stats.elapsed.count() << ",\n"
		<< "  \"planned_duration_s\": " << options.duration.count() << ",\n"
		<< "  \"iterations\": " << stats.iterations << ",\n"
		<< "  \"torrents_created\": " << stats.torrents_created << ",\n"
		<< "  \"resume_restores\": " << stats.resume_restores << ",\n"
		<< "  \"session_recycles\": " << stats.session_recycles << ",\n"
		<< "  \"bytes_transferred\": " << stats.bytes_transferred << ",\n"
		<< "  \"alerts\": " << stats.alerts << ",\n"
		<< "  \"error_alerts\": " << stats.error_alerts << ",\n"
		<< "  \"slowest_iteration_ms\": " << stats.slowest_iteration.count() << ",\n"
		<< "  \"rss_start_bytes\": " << stats.rss_start << ",\n"
		<< "  \"rss_peak_bytes\": " << stats.rss_peak << ",\n"
		<< "  \"rss_end_bytes\": " << stats.rss_last << "\n"
		<< "}\n";
	write_text_atomic(options.report_path, out.str());
	log_info(cat("soak report written to ", options.report_path.string()));
}

} // namespace

Status run_soak(const SoakOptions& options)
{
	std::signal(SIGINT, on_stop_signal);
	std::signal(SIGTERM, on_stop_signal);

	SoakStats stats;
	stats.rss_start = resident_memory_bytes();
	stats.rss_peak = stats.rss_start;
	stats.rss_last = stats.rss_start;

	const auto started = Clock::now();
	const Outcome outcome = run_guarded("soak", [&]() {
		Workspace workspace(options.workspace_root, "soak", options.keep_workspace);
		log_info(cat("soak started: duration=", options.duration.count(), "s workspace=",
			workspace.root().string()));

		std::unique_ptr<LocalSwarm> swarm = std::make_unique<LocalSwarm>(options.iteration_timeout);
		auto next_report = Clock::now() + options.report_interval;
		const auto deadline = started + options.duration;

		while (Clock::now() < deadline && g_stop_requested == 0) {
			const auto iteration_started = Clock::now();
			stats.bytes_transferred += static_cast<std::uint64_t>(run_cycle(*swarm,
				workspace.root(), stats.iterations, options.iteration_timeout, stats));
			++stats.iterations;

			const auto iteration_time
				= std::chrono::duration_cast<Millis>(Clock::now() - iteration_started);
			stats.slowest_iteration = std::max(stats.slowest_iteration, iteration_time);
			stats.rss_last = resident_memory_bytes();
			stats.rss_peak = std::max(stats.rss_peak, stats.rss_last);

			// Recycling the sessions keeps the soak honest about repeated
			// start/stop, which is what the agent does across user sessions.
			if (options.session_recycle_interval > 0
				&& stats.iterations % static_cast<std::uint64_t>(options.session_recycle_interval) == 0) {
				stats.alerts += swarm->seeder().alerts_seen() + swarm->leecher().alerts_seen();
				stats.error_alerts += swarm->seeder().errors().size() + swarm->leecher().errors().size();
				swarm->shutdown();
				swarm.reset();
				swarm = std::make_unique<LocalSwarm>(options.iteration_timeout);
				++stats.session_recycles;
			}

			if (Clock::now() >= next_report) {
				const auto elapsed = std::chrono::duration_cast<Millis>(Clock::now() - started);
				log_info(cat("soak progress: elapsed=", format_duration(elapsed), " iterations=",
					stats.iterations, " bytes=", stats.bytes_transferred, " rss=",
					stats.rss_last / (1024 * 1024), "MiB peak=", stats.rss_peak / (1024 * 1024),
					"MiB slowest=", format_duration(stats.slowest_iteration)));
				next_report = Clock::now() + options.report_interval;
			}
		}

		stats.alerts += swarm->seeder().alerts_seen() + swarm->leecher().alerts_seen();
		stats.error_alerts += swarm->seeder().errors().size() + swarm->leecher().errors().size();
		swarm->shutdown();
		if (g_stop_requested != 0) {
			log_warn("soak stopped early on signal");
		}
	});

	stats.elapsed = std::chrono::duration_cast<Millis>(Clock::now() - started);
	stats.rss_last = resident_memory_bytes();
	write_report(options, stats, outcome);

	log_info(cat("soak finished: status=", status_name(outcome.status), " elapsed=",
		format_duration(stats.elapsed), " iterations=", stats.iterations, " bytes=",
		stats.bytes_transferred, " rss ", stats.rss_start / (1024 * 1024), "MiB -> ",
		stats.rss_last / (1024 * 1024), "MiB (peak ", stats.rss_peak / (1024 * 1024), "MiB)"));
	return outcome.status;
}

} // namespace torrentino::harness
