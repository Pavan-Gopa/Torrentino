// Torrentino engine harness — engine operations (WP-01).
//
// Role:     the small set of libtorrent operations every scenario needs
//           (add, wait for check, save resume/session state, durable registry).
//           These are the exact primitives the WP-04 bridge will expose, so the
//           bakeoff proves them once, here.
// Must not: hide a failure behind a default — every helper either succeeds or
//           throws inside the harness.
#pragma once

#include "torrentino/harness/session_fixture.hpp"
#include "torrentino/harness/torrent_factory.hpp"

#include <libtorrent/add_torrent_params.hpp>

#include <cstdint>
#include <string>
#include <vector>

namespace torrentino::harness {

// libtorrent's default flags contain both `auto_managed` and `paused`: a torrent
// added as-is never even starts its hash check. Clearing both is what makes the
// scenarios deterministic, and it is the policy the engine will use as well
// (desired state is owned by the coordinator, not by libtorrent's queue).
void apply_deterministic_flags(lt::add_torrent_params& atp);

// Parsed metadata + save path, with the deterministic flags applied.
lt::add_torrent_params atp_for(const CreatedTorrent& torrent, const fs::path& save_path);

// Magnet-only params (no metadata) pointing at a known local peer.
lt::add_torrent_params magnet_atp(const std::string& uri, const fs::path& save_path, int peer_port);

lt::torrent_handle add_torrent(Session& session, lt::add_torrent_params atp, Millis timeout);

lt::torrent_status wait_until_checked(Session& session, const lt::torrent_handle& handle, Millis timeout);
lt::torrent_status wait_until_seeding(Session& session, const lt::torrent_handle& handle, Millis timeout);
lt::torrent_status wait_until_finished(Session& session, const lt::torrent_handle& handle, Millis timeout);
lt::torrent_status wait_until_metadata(Session& session, const lt::torrent_handle& handle, Millis timeout);

// Triggers save_resume_data and returns the bencoded buffer. Throws if
// libtorrent answers with save_resume_data_failed_alert.
std::vector<char> save_resume_data(Session& session, const lt::torrent_handle& handle, Millis timeout);

// Bencoded session_params (settings + DHT state) for a warm restart.
std::vector<char> save_session_state(Session& session);

void remove_torrent_keep_files(Session& session, const lt::torrent_handle& handle, Millis timeout);

// Two loopback sessions used by every transfer-based scenario. The leecher only
// ever learns about the seeder through an explicit 127.0.0.1 endpoint, so no
// tracker, DHT or LSD traffic is required (or permitted).
class LocalSwarm {
public:
	explicit LocalSwarm(Millis timeout);

	[[nodiscard]] Session& seeder() noexcept { return seeder_; }
	[[nodiscard]] Session& leecher() noexcept { return leecher_; }
	[[nodiscard]] int seeder_port() const noexcept { return seeder_port_; }

	void shutdown();

private:
	Session seeder_;
	Session leecher_;
	int seeder_port_{0};
};

// Minimal durable registry: one record per torrent, atomically rewritten. Stands
// in for the agent's SQLite registry when proving crash restore.
struct RegistryEntry {
	std::string id;
	std::string name;
	std::int64_t total_done{0};
	std::int64_t total_size{0};
	std::string save_path;
};

void write_registry(const fs::path& path, const std::vector<RegistryEntry>& entries);
std::vector<RegistryEntry> read_registry(const fs::path& path);

} // namespace torrentino::harness
