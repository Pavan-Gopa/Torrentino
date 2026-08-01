// Torrentino engine harness — libtorrent session fixture (WP-01).
//
// Role:     owns a libtorrent session for the duration of a scenario, drains
//           alerts, and provides bounded waits so that a hang shows up as a
//           TimeoutFailure instead of a stuck process.
// Must not: hand out raw libtorrent alert pointers — they are only valid until
//           the next pop_alerts() call, which is exactly the trap the WP-04
//           bridge has to avoid as well.
// Threading: single-threaded by contract. The libtorrent session runs its own
//           threads internally; scenarios only touch it from the calling thread.
#pragma once

#include "torrentino/harness/support.hpp"

#include <libtorrent/alert.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace torrentino::harness {

namespace lt = libtorrent;

struct SessionOptions {
	std::string tag = "session";
	// Loopback only with an ephemeral port: the harness must be hermetic and
	// must never advertise itself to the real swarm during CI or the soak.
	std::string listen_interfaces = "127.0.0.1:0";
	std::string user_agent = "Torrentino-Harness/1.0";
	bool enable_dht = false;
	bool enable_lsd = false;
	bool enable_upnp = false;
	bool enable_natpmp = false;
	// Two harness sessions share 127.0.0.1, so per-IP connection limiting has to
	// be relaxed or they can never talk to each other.
	bool allow_multiple_connections_per_ip = true;
	int alert_queue_size = 8000;
};

lt::settings_pack make_settings(const SessionOptions& options);
lt::session_params make_session_params(const SessionOptions& options);

// Text form of a torrent identity: v1 hash when present, otherwise the v2 hash.
// This is the identity rule the engine registry will use for hybrid torrents.
std::string torrent_id(const lt::info_hash_t& hashes);
std::string describe_info_hashes(const lt::info_hash_t& hashes);

class Session {
public:
	Session(lt::session_params params, std::string tag);
	~Session();

	Session(const Session&) = delete;
	Session& operator=(const Session&) = delete;

	[[nodiscard]] lt::session& raw() noexcept { return *session_; }
	[[nodiscard]] const std::string& tag() const noexcept { return tag_; }

	// Pumps the alert queue until `predicate` accepts an alert or the deadline
	// expires. Throws TimeoutFailure on expiry so hangs are never silent.
	void wait_for_alert(Millis timeout, std::string_view what,
		const std::function<bool(const lt::alert&)>& predicate);

	// Same, but driven by torrent_status polling; alerts are still drained so the
	// queue cannot overflow while we wait.
	lt::torrent_status wait_for_status(const lt::torrent_handle& handle, Millis timeout,
		std::string_view what, const std::function<bool(const lt::torrent_status&)>& predicate);

	// Drains whatever is queued right now (non-blocking).
	void pump();
	// Drains for at least `duration` — used to let the swarm make progress.
	void pump_for(Millis duration);

	// TCP port the session actually bound on loopback.
	int listen_port(Millis timeout);

	[[nodiscard]] std::uint64_t alerts_seen() const noexcept { return alerts_seen_; }
	[[nodiscard]] const std::vector<std::string>& errors() const noexcept { return errors_; }

	// Deterministic shutdown: pause, abort, wait for the session proxy to settle.
	// Returns how long it took; throws TimeoutFailure if it exceeds `timeout`.
	Millis shutdown(Millis timeout = Millis{15000});

private:
	void consume(const lt::alert& alert);

	std::unique_ptr<lt::session> session_;
	std::string tag_;
	std::vector<lt::alert*> scratch_;
	std::vector<std::string> errors_;
	std::uint64_t alerts_seen_{0};
	bool stopped_{false};
};

} // namespace torrentino::harness
