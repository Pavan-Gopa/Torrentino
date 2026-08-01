// Torrentino engine harness — libtorrent session fixture (WP-01).
// See session_fixture.hpp for the role of this module.
#include "torrentino/harness/session_fixture.hpp"

#include <libtorrent/alert_types.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/settings_pack.hpp>

#include <algorithm>
#include <thread>

namespace torrentino::harness {
namespace {

// Alert categories the harness needs. `all` would flood the queue with peer and
// DHT chatter during the soak without adding evidence.
constexpr lt::alert_category_t kAlertMask = lt::alert_category::error
	| lt::alert_category::status | lt::alert_category::storage
	| lt::alert_category::performance_warning | lt::alert_category::port_mapping;

constexpr Millis kPollInterval{50};

} // namespace

lt::settings_pack make_settings(const SessionOptions& options)
{
	lt::settings_pack pack;
	pack.set_str(lt::settings_pack::listen_interfaces, options.listen_interfaces);
	pack.set_str(lt::settings_pack::user_agent, options.user_agent);
	pack.set_int(lt::settings_pack::alert_queue_size, options.alert_queue_size);
	// alert_mask is a plain int setting, while the categories are a typed
	// bitfield — the conversion has to be explicit.
	pack.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(kAlertMask)));
	pack.set_bool(lt::settings_pack::enable_dht, options.enable_dht);
	pack.set_bool(lt::settings_pack::enable_lsd, options.enable_lsd);
	pack.set_bool(lt::settings_pack::enable_upnp, options.enable_upnp);
	pack.set_bool(lt::settings_pack::enable_natpmp, options.enable_natpmp);
	pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip,
		options.allow_multiple_connections_per_ip);
	// Keep the harness off the public network even if a tracker or peer address
	// sneaks into a generated torrent.
	pack.set_bool(lt::settings_pack::announce_to_all_trackers, false);
	pack.set_bool(lt::settings_pack::announce_to_all_tiers, false);
	pack.set_int(lt::settings_pack::tracker_completion_timeout, 5);
	pack.set_int(lt::settings_pack::tracker_receive_timeout, 5);
	pack.set_int(lt::settings_pack::stop_tracker_timeout, 1);
	// Fast, deterministic local peering.
	pack.set_int(lt::settings_pack::min_reconnect_time, 1);
	pack.set_int(lt::settings_pack::peer_connect_timeout, 5);
	pack.set_bool(lt::settings_pack::smooth_connects, false);
	return pack;
}

lt::session_params make_session_params(const SessionOptions& options)
{
	return lt::session_params(make_settings(options));
}

std::string torrent_id(const lt::info_hash_t& hashes)
{
	// Hybrid torrents carry both hashes; the v1 hash is the stable cross-client
	// identity, so the registry keys on it and falls back to v2 for v2-only.
	if (hashes.has_v1()) {
		return lt::aux::to_hex(hashes.v1);
	}
	return lt::aux::to_hex(hashes.v2);
}

std::string describe_info_hashes(const lt::info_hash_t& hashes)
{
	std::string out;
	out += hashes.has_v1() ? cat("v1=", lt::aux::to_hex(hashes.v1)) : std::string("v1=-");
	out += hashes.has_v2() ? cat(" v2=", lt::aux::to_hex(hashes.v2)) : std::string(" v2=-");
	return out;
}

Session::Session(lt::session_params params, std::string tag)
	: session_(std::make_unique<lt::session>(std::move(params)))
	, tag_(std::move(tag))
{
	log_info(cat('[', tag_, "] session started"));
}

Session::~Session()
{
	// Destructor contract: never throw. A shutdown that misses its deadline is
	// logged here; scenarios assert on the explicit shutdown() call instead.
	if (stopped_) {
		return;
	}
	try {
		shutdown();
	} catch (const std::exception& e) {
		log_warn(cat('[', tag_, "] shutdown during destruction failed: ", e.what()));
	} catch (...) {
		log_warn(cat('[', tag_, "] shutdown during destruction failed: unknown"));
	}
}

void Session::consume(const lt::alert& alert)
{
	++alerts_seen_;
	if ((alert.category() & lt::alert_category::error) != lt::alert_category_t{}) {
		// Keep the text only: alert pointers die on the next pop_alerts().
		errors_.push_back(cat('[', tag_, "] ", alert.what(), ": ", alert.message()));
	}
}

void Session::pump()
{
	scratch_.clear();
	session_->pop_alerts(&scratch_);
	for (const lt::alert* a : scratch_) {
		consume(*a);
	}
}

void Session::pump_for(Millis duration)
{
	const auto deadline = Clock::now() + duration;
	while (Clock::now() < deadline) {
		session_->wait_for_alert(kPollInterval);
		pump();
	}
}

void Session::wait_for_alert(Millis timeout, std::string_view what,
	const std::function<bool(const lt::alert&)>& predicate)
{
	const auto deadline = Clock::now() + timeout;
	while (Clock::now() < deadline) {
		session_->wait_for_alert(kPollInterval);
		scratch_.clear();
		session_->pop_alerts(&scratch_);
		bool matched = false;
		for (const lt::alert* a : scratch_) {
			consume(*a);
			// Consume the whole batch even after a match: bailing out early would
			// drop error alerts that belong to the same step.
			if (!matched && predicate(*a)) {
				matched = true;
			}
		}
		if (matched) {
			return;
		}
	}
	throw TimeoutFailure(
		cat('[', tag_, "] timed out after ", format_duration(timeout), " waiting for ", what));
}

lt::torrent_status Session::wait_for_status(const lt::torrent_handle& handle, Millis timeout,
	std::string_view what, const std::function<bool(const lt::torrent_status&)>& predicate)
{
	const auto deadline = Clock::now() + timeout;
	lt::torrent_status status;
	while (Clock::now() < deadline) {
		pump();
		status = handle.status();
		if (predicate(status)) {
			return status;
		}
		std::this_thread::sleep_for(kPollInterval);
	}
	throw TimeoutFailure(cat('[', tag_, "] timed out after ", format_duration(timeout),
		" waiting for ", what, " (state=", static_cast<int>(status.state),
		" progress=", status.progress, ')'));
}

int Session::listen_port(Millis timeout)
{
	int port = 0;
	wait_for_alert(timeout, "listen_succeeded_alert on loopback TCP",
		[&port](const lt::alert& alert) {
			const auto* listen = lt::alert_cast<lt::listen_succeeded_alert>(&alert);
			if (listen == nullptr) {
				return false;
			}
			// Only the TCP endpoint can accept the peer connection the other
			// harness session makes; uTP/SSL sockets raise their own alerts.
			if (listen->socket_type != lt::socket_type_t::tcp) {
				return false;
			}
			port = int{listen->port};
			return port != 0;
		});
	return port;
}

Millis Session::shutdown(Millis timeout)
{
	const auto started = Clock::now();
	if (stopped_) {
		return Millis{0};
	}
	stopped_ = true;

	session_->pause();
	pump();
	// abort() detaches the session; only the *destructor* of the returned proxy
	// joins libtorrent's network thread. Assigning over a live proxy would
	// destroy a still-joinable std::thread and abort the process, so the proxy
	// must go out of scope naturally — WP-04 has to follow the same rule.
	{
		const lt::session_proxy proxy = session_->abort();
		session_.reset();
	}

	const auto elapsed = std::chrono::duration_cast<Millis>(Clock::now() - started);
	log_info(
		cat('[', tag_, "] session stopped in ", format_duration(elapsed), ", alerts=", alerts_seen_));
	if (elapsed > timeout) {
		throw TimeoutFailure(cat('[', tag_, "] shutdown took ", format_duration(elapsed),
			", limit ", format_duration(timeout)));
	}
	return elapsed;
}

} // namespace torrentino::harness
