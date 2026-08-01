// Torrentino engine harness — engine operations (WP-01).
// See engine_ops.hpp for the role of this module.
#include "torrentino/harness/engine_ops.hpp"

#include <libtorrent/alert_types.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session_handle.hpp>
#include <libtorrent/socket.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <fstream>
#include <sstream>

namespace torrentino::harness {
namespace {

bool is_checking(const lt::torrent_status& status) noexcept
{
	return status.state == lt::torrent_status::checking_files
		|| status.state == lt::torrent_status::checking_resume_data;
}

} // namespace

void apply_deterministic_flags(lt::add_torrent_params& atp)
{
	// Auto management would queue and unpause torrents behind our back, and the
	// default `paused` flag would stop the hash check before it starts.
	atp.flags &= ~lt::torrent_flags::auto_managed;
	atp.flags &= ~lt::torrent_flags::paused;
}

lt::add_torrent_params atp_for(const CreatedTorrent& torrent, const fs::path& save_path)
{
	lt::add_torrent_params atp = lt::load_torrent_buffer(torrent.bencoded);
	atp.save_path = save_path.string();
	apply_deterministic_flags(atp);
	return atp;
}

lt::add_torrent_params magnet_atp(const std::string& uri, const fs::path& save_path, int peer_port)
{
	lt::add_torrent_params atp = lt::parse_magnet_uri(uri);
	atp.save_path = save_path.string();
	apply_deterministic_flags(atp);
	if (peer_port > 0) {
		// The harness has no tracker and no DHT, so the seeding session is handed
		// over explicitly. This keeps the metadata test hermetic and offline.
		atp.peers.emplace_back(lt::make_address_v4("127.0.0.1"),
			static_cast<std::uint16_t>(peer_port));
	}
	return atp;
}

lt::torrent_handle add_torrent(Session& session, lt::add_torrent_params atp, Millis timeout)
{
	const lt::torrent_handle handle = session.raw().add_torrent(std::move(atp));
	TH_REQUIRE(handle.is_valid(), "add_torrent must return a valid handle");
	// add_torrent_alert confirms the session actually took ownership; without it a
	// later status poll could race with torrent construction.
	session.wait_for_alert(timeout, "add_torrent_alert", [&handle](const lt::alert& alert) {
		const auto* added = lt::alert_cast<lt::add_torrent_alert>(&alert);
		return added != nullptr && added->handle == handle;
	});
	return handle;
}

lt::torrent_status wait_until_checked(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	return session.wait_for_status(handle, timeout, "hash check to finish",
		[](const lt::torrent_status& status) { return !is_checking(status); });
}

lt::torrent_status wait_until_seeding(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	return session.wait_for_status(handle, timeout, "torrent to become a seed",
		[](const lt::torrent_status& status) { return status.is_seeding; });
}

lt::torrent_status wait_until_finished(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	return session.wait_for_status(handle, timeout, "download to finish",
		[](const lt::torrent_status& status) { return status.is_finished; });
}

lt::torrent_status wait_until_metadata(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	return session.wait_for_status(handle, timeout, "metadata to arrive",
		[](const lt::torrent_status& status) { return status.has_metadata; });
}

std::vector<char> save_resume_data(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	std::vector<char> buffer;
	std::string failure;
	// flush_disk_cache + save_info_dict: the saved buffer must be enough to
	// restore the torrent on its own, including metadata for magnet-added ones.
	handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
	session.wait_for_alert(timeout, "save_resume_data_alert",
		[&](const lt::alert& alert) {
			if (const auto* saved = lt::alert_cast<lt::save_resume_data_alert>(&alert)) {
				if (saved->handle != handle) {
					return false;
				}
				buffer = lt::write_resume_data_buf(saved->params);
				return true;
			}
			if (const auto* failed = lt::alert_cast<lt::save_resume_data_failed_alert>(&alert)) {
				if (failed->handle != handle) {
					return false;
				}
				failure = failed->message();
				return true;
			}
			return false;
		});
	TH_REQUIRE(failure.empty(), cat("save_resume_data failed: ", failure));
	TH_REQUIRE(!buffer.empty(), "resume data buffer must not be empty");
	return buffer;
}

std::vector<char> save_session_state(Session& session)
{
	// Settings and DHT state only: proxy/encryption sub-states are deprecated
	// flags in libtorrent 2.x and must not be requested by new code.
	const lt::session_params params = session.raw().session_state(
		lt::session_handle::save_settings | lt::session_handle::save_dht_state);
	std::vector<char> buffer = lt::write_session_params_buf(params);
	TH_REQUIRE(!buffer.empty(), "session state buffer must not be empty");
	return buffer;
}

void remove_torrent_keep_files(Session& session, const lt::torrent_handle& handle, Millis timeout)
{
	const lt::info_hash_t hashes = handle.info_hashes();
	session.raw().remove_torrent(handle); // no delete_files: partial data must survive
	session.wait_for_alert(timeout, "torrent_removed_alert", [&hashes](const lt::alert& alert) {
		const auto* removed = lt::alert_cast<lt::torrent_removed_alert>(&alert);
		return removed != nullptr && removed->info_hashes == hashes;
	});
}

// --- local swarm -----------------------------------------------------------
namespace {

SessionOptions swarm_options(std::string tag)
{
	SessionOptions options;
	options.tag = std::move(tag);
	return options;
}

} // namespace

LocalSwarm::LocalSwarm(Millis timeout)
	: seeder_(make_session_params(swarm_options("seeder")), "seeder")
	, leecher_(make_session_params(swarm_options("leecher")), "leecher")
{
	seeder_port_ = seeder_.listen_port(timeout);
	TH_REQUIRE(seeder_port_ > 0, "seeder must bind a loopback TCP port");
	// The leecher must be listening too, otherwise its outgoing connection can
	// race with the seeder's socket setup on a busy machine.
	const int leecher_port = leecher_.listen_port(timeout);
	TH_REQUIRE(leecher_port > 0, "leecher must bind a loopback TCP port");
	log_info(cat("local swarm ready: seeder=127.0.0.1:", seeder_port_, " leecher=127.0.0.1:",
		leecher_port));
}

void LocalSwarm::shutdown()
{
	leecher_.shutdown();
	seeder_.shutdown();
}

// --- registry --------------------------------------------------------------
// Tab-separated records: trivially parseable, trivially diffable in a crash
// post-mortem, and written through the atomic writer so a kill -9 can only ever
// leave the previous complete generation behind.
void write_registry(const fs::path& path, const std::vector<RegistryEntry>& entries)
{
	std::ostringstream out;
	out << "# torrentino harness registry v1\n";
	for (const RegistryEntry& e : entries) {
		out << e.id << '\t' << e.name << '\t' << e.total_done << '\t' << e.total_size << '\t'
			<< e.save_path << '\n';
	}
	write_text_atomic(path, out.str());
}

std::vector<RegistryEntry> read_registry(const fs::path& path)
{
	std::ifstream in(path);
	TH_REQUIRE(in.good(), cat("registry missing: ", path.string()));
	std::vector<RegistryEntry> entries;
	std::string line;
	while (std::getline(in, line)) {
		if (line.empty() || line[0] == '#') {
			continue;
		}
		std::istringstream fields(line);
		RegistryEntry entry;
		std::string done;
		std::string size;
		if (!std::getline(fields, entry.id, '\t') || !std::getline(fields, entry.name, '\t')
			|| !std::getline(fields, done, '\t') || !std::getline(fields, size, '\t')
			|| !std::getline(fields, entry.save_path)) {
			throw AssertionFailure(cat("corrupt registry line: ", line));
		}
		entry.total_done = std::stoll(done);
		entry.total_size = std::stoll(size);
		entries.push_back(std::move(entry));
	}
	return entries;
}

} // namespace torrentino::harness
