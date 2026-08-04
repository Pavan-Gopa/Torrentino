// Torrentino engine bridge — PIMPL implementation (WP-04).
//
// Role:     owns the libtorrent 2.x session, torrent primitives, alert batching
//           and deterministic shutdown behind the EngineBridge facade. This is
//           the only translation unit that includes libtorrent headers.
// Must not: hand libtorrent types to the caller, let an exception escape a
//           public method, or perform unbounded waits.
// Threading: a single operation mutex serializes every public call; the
//           libtorrent session runs its own network thread internally. A
//           cooperative wake flag lets shutdown() unblock a wait loop.
#include "EngineBridge.h"

#include <libtorrent/announce_entry.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <mutex>
#include <string_view>
#include <thread>

namespace torrentino::bridge {
namespace {

namespace lt = libtorrent;

using Clock = std::chrono::steady_clock;
using Millis = std::chrono::milliseconds;
using Deadline = Clock::time_point;

constexpr std::uint32_t kDefaultTimeoutMs = 10000;
constexpr const char* kEngineVersion = "torrentino-bridge/1.0";

bool valid_tracker_port(std::string_view port)
{
	if (port.empty() || port.size() > 5) {
		return false;
	}
	unsigned int value = 0;
	for (const char character : port) {
		if (character < '0' || character > '9') {
			return false;
		}
		value = value * 10u + static_cast<unsigned int>(character - '0');
	}
	return value > 0 && value <= 65535;
}

bool is_ascii_hex_digit(char character)
{
	return (character >= '0' && character <= '9')
		|| (character >= 'a' && character <= 'f')
		|| (character >= 'A' && character <= 'F');
}

bool valid_percent_escapes(std::string_view value)
{
	for (std::size_t index = 0; index < value.size(); ++index) {
		if (value[index] != '%') {
			continue;
		}
		if (index + 2 >= value.size()
			|| !is_ascii_hex_digit(value[index + 1])
			|| !is_ascii_hex_digit(value[index + 2])) {
			return false;
		}
		index += 2;
	}
	return true;
}

bool valid_tracker_ipv4(std::string_view host)
{
	if (host.empty()) {
		return false;
	}

	std::size_t start = 0;
	int segments = 0;
	while (start <= host.size()) {
		const std::size_t end = host.find('.', start);
		const std::size_t length = end == std::string_view::npos
			? host.size() - start : end - start;
		if (length == 0 || length > 3) {
			return false;
		}

		unsigned int value = 0;
		for (std::size_t index = start; index < start + length; ++index) {
			const char character = host[index];
			if (character < '0' || character > '9') {
				return false;
			}
			value = value * 10u + static_cast<unsigned int>(character - '0');
		}
		if (value > 255) {
			return false;
		}
		++segments;

		if (end == std::string_view::npos) {
			break;
		}
		start = end + 1;
	}
	return segments == 4;
}

bool valid_tracker_host(std::string_view host)
{
	if (host.empty() || host.size() > 253 || host.find('%') != std::string_view::npos) {
		return false;
	}

	// A dotted host made only of decimal characters is an IPv4 literal, not a
	// DNS name. Treating it as such prevents malformed addresses such as
	// 999.1.1.1 or 127.0.0 from passing as ordinary hostnames.
	if (host.find('.') != std::string_view::npos) {
		bool decimalDotted = true;
		for (const char character : host) {
			if ((character < '0' || character > '9') && character != '.') {
				decimalDotted = false;
				break;
			}
		}
		if (decimalDotted) {
			return valid_tracker_ipv4(host);
		}
	}

	// A trailing root label is valid DNS syntax, but an otherwise empty name
	// or an empty interior label is not.
	if (host.back() == '.') {
		host.remove_suffix(1);
		if (host.empty() || host.back() == '.') {
			return false;
		}
	}
	if (host.empty()) {
		return false;
	}

	std::size_t start = 0;
	while (start < host.size()) {
		const std::size_t end = host.find('.', start);
		const std::size_t length = end == std::string_view::npos
			? host.size() - start : end - start;
		if (length == 0 || length > 63) {
			return false;
		}
		const std::string_view label = host.substr(start, length);
		if ((label.front() < '0' || label.front() > '9')
			&& (label.front() < 'A' || label.front() > 'Z')
			&& (label.front() < 'a' || label.front() > 'z')) {
			return false;
		}
		if ((label.back() < '0' || label.back() > '9')
			&& (label.back() < 'A' || label.back() > 'Z')
			&& (label.back() < 'a' || label.back() > 'z')) {
			return false;
		}
		for (const char character : label) {
			const bool asciiAlphaNumeric = (character >= '0' && character <= '9')
				|| (character >= 'A' && character <= 'Z')
				|| (character >= 'a' && character <= 'z');
			if (!asciiAlphaNumeric && character != '-') {
				return false;
			}
		}
		if (end == std::string_view::npos) {
			break;
		}
		start = end + 1;
	}
	return true;
}

bool valid_tracker_ipv6_literal(std::string_view host)
{
	if (host.empty() || host.find('%') != std::string_view::npos) {
		return false;
	}

	const std::size_t compression = host.find("::");
	if (compression != std::string_view::npos
		&& (host.find("::", compression + 1) != std::string_view::npos
			|| host.find(":::") != std::string_view::npos)) {
		return false;
	}

	const auto countGroups = [](std::string_view part, bool allowIPv4Tail, int& count) {
		if (part.empty()) {
			return true;
		}
		std::size_t start = 0;
		while (start < part.size()) {
			const std::size_t end = part.find(':', start);
			const std::size_t length = end == std::string_view::npos
				? part.size() - start : end - start;
			if (length == 0) {
				return false;
			}
			const std::string_view token = part.substr(start, length);
			if (token.find('.') != std::string_view::npos) {
				if (!allowIPv4Tail || end != std::string_view::npos
					|| !valid_tracker_ipv4(token)) {
					return false;
				}
				count += 2;
			} else {
				if (length > 4) {
					return false;
				}
				for (const char character : token) {
					if (!is_ascii_hex_digit(character)) {
						return false;
					}
				}
				++count;
			}
			if (end == std::string_view::npos) {
				break;
			}
			start = end + 1;
		}
		return true;
	};

	if (compression == std::string_view::npos) {
		int groups = 0;
		return countGroups(host, true, groups) && groups == 8;
	}

	const std::string_view left = host.substr(0, compression);
	const std::string_view right = host.substr(compression + 2);
	int groups = 0;
	return countGroups(left, false, groups)
		&& countGroups(right, true, groups)
		&& groups < 8;
}

bool valid_tracker_url(std::string_view url)
{
	if (url.empty() || !valid_percent_escapes(url)) {
		return false;
	}
	for (const char character : url) {
		if (std::iscntrl(static_cast<unsigned char>(character))
			|| std::isspace(static_cast<unsigned char>(character))) {
			return false;
		}
	}

	const std::size_t separator = url.find("://");
	if (separator == std::string_view::npos || separator == 0) {
		return false;
	}
	std::string scheme(url.substr(0, separator));
	if (scheme.empty()
		|| ((scheme.front() < 'A' || scheme.front() > 'Z')
			&& (scheme.front() < 'a' || scheme.front() > 'z'))) {
		return false;
	}
	for (char& character : scheme) {
		const bool asciiAlphaNumeric = (character >= '0' && character <= '9')
			|| (character >= 'A' && character <= 'Z')
			|| (character >= 'a' && character <= 'z');
		if (!asciiAlphaNumeric && character != '+' && character != '-' && character != '.') {
			return false;
		}
		character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
	}
	if (scheme != "http" && scheme != "https" && scheme != "udp") {
		return false;
	}

	const std::size_t authorityStart = separator + 3;
	if (authorityStart >= url.size()) {
		return false;
	}
	const std::size_t authorityEnd = url.find_first_of("/?#", authorityStart);
	const std::string_view authority = url.substr(
		authorityStart,
		authorityEnd == std::string_view::npos ? url.size() - authorityStart : authorityEnd - authorityStart);
	if (authority.empty() || authority.find('@') != std::string_view::npos) {
		return false;
	}

	if (authority.front() == '[') {
		const std::size_t closingBracket = authority.find(']');
		if (closingBracket <= 1) {
			return false;
		}
		const std::string_view host = authority.substr(1, closingBracket - 1);
		if (!valid_tracker_ipv6_literal(host)) {
			return false;
		}
		const std::string_view suffix = authority.substr(closingBracket + 1);
		if (!suffix.empty() && (suffix.front() != ':' || !valid_tracker_port(suffix.substr(1)))) {
			return false;
		}
		return authority.find('[', 1) == std::string_view::npos
			&& authority.find(']', closingBracket + 1) == std::string_view::npos;
	}

	if (authority.find('[') != std::string_view::npos
		|| authority.find(']') != std::string_view::npos) {
		return false;
	}
	const std::size_t colon = authority.find(':');
	if (colon == std::string_view::npos) {
		return valid_tracker_host(authority);
	}
	if (colon == 0 || authority.find(':', colon + 1) != std::string_view::npos) {
		return false;
	}
	if (!valid_tracker_host(authority.substr(0, colon))) {
		return false;
	}
	return valid_tracker_port(authority.substr(colon + 1));
}

// Alert categories the engine consumes. `all` would flood the batch queue
// with per-peer/per-piece traffic, which WP-04 explicitly must not deliver.
// status covers state_changed, paused/resumed, checked, finished,
// metadata_received, add/removed; storage covers save_resume_data and
// file-deleted notices.
constexpr lt::alert_category_t kAlertMask = lt::alert_category::error
	| lt::alert_category::status | lt::alert_category::storage
	| lt::alert_category::performance_warning;

lt::settings_pack make_settings(const SessionConfiguration& config)
{
	lt::settings_pack pack;
	// listen_interfaces with port 0 asks the OS for an ephemeral port
	// (hermetic, WP-01 rule); the boot report reads it back via listen_port().
	if (config.listen_port > 0) {
		pack.set_str(lt::settings_pack::listen_interfaces,
			"0.0.0.0:" + std::to_string(config.listen_port));
	} else {
		pack.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
	}
	pack.set_str(lt::settings_pack::user_agent, kEngineVersion);
	pack.set_int(lt::settings_pack::alert_queue_size,
		static_cast<int>(config.alert_queue_size));
	pack.set_int(lt::settings_pack::alert_mask,
		static_cast<int>(static_cast<std::uint32_t>(kAlertMask)));
	pack.set_str(lt::settings_pack::peer_fingerprint, config.peer_id_prefix);
	pack.set_bool(lt::settings_pack::enable_dht, config.enable_dht);
	pack.set_bool(lt::settings_pack::enable_lsd, config.enable_lsd);
	pack.set_bool(lt::settings_pack::enable_upnp, config.enable_upnp);
	pack.set_bool(lt::settings_pack::enable_natpmp, config.enable_natpmp);
	pack.set_int(lt::settings_pack::connections_limit, config.max_connections);
	pack.set_int(lt::settings_pack::active_downloads, config.max_active_downloads);
	pack.set_int(lt::settings_pack::active_seeds, config.max_active_seeds);
	pack.set_int(lt::settings_pack::connection_speed, config.max_connection_attempts);
	pack.set_int(lt::settings_pack::download_rate_limit,
		static_cast<int>(config.max_download_bytes_per_sec));
	pack.set_int(lt::settings_pack::upload_rate_limit,
		static_cast<int>(config.max_upload_bytes_per_sec));

	// Proxy passwords never cross the Swift/XPC boundary. The UI owns that
	// secret in Keychain; the bridge still applies every non-secret proxy field
	// and deliberately clears the unavailable password slot.
	int proxyType = static_cast<int>(lt::settings_pack::none);
	if (config.proxy_kind == "socks5") {
		proxyType = static_cast<int>(config.proxy_username.empty()
			? lt::settings_pack::socks5 : lt::settings_pack::socks5_pw);
	} else if (config.proxy_kind == "http") {
		proxyType = static_cast<int>(config.proxy_username.empty()
			? lt::settings_pack::http : lt::settings_pack::http_pw);
	}
	pack.set_int(lt::settings_pack::proxy_type, proxyType);
	pack.set_int(lt::settings_pack::proxy_port, static_cast<int>(config.proxy_port));
	pack.set_str(lt::settings_pack::proxy_hostname, config.proxy_host);
	pack.set_str(lt::settings_pack::proxy_username, config.proxy_username);
	pack.set_str(lt::settings_pack::proxy_password, "");

	const auto encryptionPolicy = config.encryption_enabled
		? lt::settings_pack::pe_enabled
		: lt::settings_pack::pe_disabled;
	pack.set_int(lt::settings_pack::out_enc_policy,
		static_cast<int>(encryptionPolicy));
	pack.set_int(lt::settings_pack::in_enc_policy,
		static_cast<int>(encryptionPolicy));
	pack.set_int(lt::settings_pack::allowed_enc_level,
		static_cast<int>(config.encryption_enabled
			? lt::settings_pack::pe_both
			: lt::settings_pack::pe_plaintext));
	// Local-first determinism inherited from the WP-01 bakeoff: fast
	// reconnects and short timeouts keep shutdown from leaving a half-open
	// connection storm behind.
	pack.set_int(lt::settings_pack::min_reconnect_time, 1);
	pack.set_int(lt::settings_pack::peer_connect_timeout, 5);
	pack.set_bool(lt::settings_pack::smooth_connects, false);
	return pack;
}

bool validate_configuration(const SessionConfiguration& config, std::string& message)
{
	if (config.listen_port < 0 || config.listen_port > 65535) {
		message = "listen_port must be between 0 and 65535";
		return false;
	}
	if (config.max_connections <= 0) {
		message = "max_connections must be positive";
		return false;
	}
	if (config.max_active_downloads <= 0 || config.max_active_seeds <= 0) {
		message = "active torrent limits must be positive";
		return false;
	}
	if (config.max_connection_attempts < 0 || config.cache_bytes <= 0) {
		message = "connection and cache limits must be non-negative and positive respectively";
		return false;
	}
	if (config.max_download_bytes_per_sec < 0
		|| config.max_download_bytes_per_sec > std::numeric_limits<int>::max()
		|| config.max_upload_bytes_per_sec < 0
		|| config.max_upload_bytes_per_sec > std::numeric_limits<int>::max()) {
		message = "session rate limits must fit a signed 32-bit byte-per-second value";
		return false;
	}
	if (config.alert_queue_size == 0) {
		message = "alert_queue_size must be positive";
		return false;
	}
	if (config.proxy_kind != "none" && config.proxy_kind != "socks5"
		&& config.proxy_kind != "http") {
		message = "proxy_kind is not supported";
		return false;
	}
	if (config.proxy_kind != "none"
		&& (config.proxy_host.empty() || config.proxy_port == 0)) {
		message = "enabled proxy requires a host and port";
		return false;
	}
	return true;
}

std::string id_string(const lt::info_hash_t& hashes)
{
	if (hashes.has_v1()) {
		return lt::aux::to_hex(hashes.v1);
	}
	return lt::aux::to_hex(hashes.v2);
}

std::string describe_hashes(const lt::info_hash_t& hashes)
{
	std::string out;
	out += hashes.has_v1() ? "v1=" + lt::aux::to_hex(hashes.v1) : "v1=-";
	out += hashes.has_v2() ? " v2=" + lt::aux::to_hex(hashes.v2) : " v2=-";
	return out;
}

bool is_tcp_listen(lt::socket_type_t type) noexcept
{
	switch (type) {
	case lt::socket_type_t::tcp:
	case lt::socket_type_t::tcp_ssl:
		return true;
	default:
		return false;
	}
}

} // namespace

const char* bridge_error_name(BridgeError code) noexcept
{
	switch (code) {
	case BridgeError::none: return "none";
	case BridgeError::not_started: return "not_started";
	case BridgeError::already_started: return "already_started";
	case BridgeError::not_found: return "not_found";
	case BridgeError::timeout: return "timeout";
	case BridgeError::invalid_argument: return "invalid_argument";
	case BridgeError::engine_failure: return "engine_failure";
	case BridgeError::io: return "io";
	case BridgeError::stopped: return "stopped";
	case BridgeError::internal: return "internal";
	case BridgeError::unsupported_operation: return "unsupported_operation";
	}
	return "unknown";
}

const char* engine_alert_kind_name(EngineAlertKind kind) noexcept
{
	switch (kind) {
	case EngineAlertKind::state_changed: return "state_changed";
	case EngineAlertKind::checked: return "checked";
	case EngineAlertKind::finished: return "finished";
	case EngineAlertKind::paused: return "paused";
	case EngineAlertKind::resumed: return "resumed";
	case EngineAlertKind::metadata_received: return "metadata_received";
	case EngineAlertKind::error: return "error";
	case EngineAlertKind::removed: return "removed";
	case EngineAlertKind::session: return "session";
	case EngineAlertKind::unknown: return "unknown";
	}
	return "unknown";
}

// ---------------------------------------------------------------------------
// Impl — the only place allowed to mention libtorrent.
// ---------------------------------------------------------------------------

struct EngineBridge::Impl {
	Impl() = default;

	~Impl()
	{
		// shutdown() is idempotent and noexcept; destruction after a clean
		// shutdown is a no-op, and destruction without shutdown (error paths)
		// still tears the session down deterministically.
		shutdown();
	}

	// --- start / stop ------------------------------------------------------

	Result<BootReport> start(const SessionConfiguration& config)
	{
		// unique_lock because waitForListenLocked releases the mutex while
		// sleeping (shutdown() must be able to acquire it and wake us).
		std::unique_lock<std::mutex> lock(mutex_);
		if (session_) {
			return Result<BootReport>::failed(BridgeError::already_started,
				"engine is already running");
		}
		std::string configurationError;
		if (!validate_configuration(config, configurationError)) {
			return Result<BootReport>::failed(BridgeError::invalid_argument,
				std::move(configurationError));
		}
		stop_requested_.store(false);
		handles_.clear();
		pending_.clear();
		alerts_seen_ = 0;
		// The boot report must reflect what the engine actually runs with, so
		// the configured peer-id prefix (not the default) is what gets reported.
		last_peer_id_ = config.peer_id_prefix;
		default_download_dir_ = config.download_dir;
		timeout_ = Millis{config.operation_timeout_ms > 0
			? config.operation_timeout_ms : kDefaultTimeoutMs};
		started = Clock::now();

		try {
			lt::session_params params(make_settings(config));
			session_ = std::make_unique<lt::session>(std::move(params));

			// Give the listen socket a bounded chance to bind. session() takes
			// settings asynchronously, so wait for the critical listen alert.
			const int listen_wait = waitForListenLocked(lock, timeout_);
			if (listen_wait == -2) {
				shutdownLocked();
				return Result<BootReport>::failed(BridgeError::stopped,
					"engine start cancelled by shutdown");
			}

			const int port = session_->listen_port();
			if (port <= 0) {
				shutdownLocked();
				return Result<BootReport>::failed(BridgeError::engine_failure,
					"session did not bind any listening TCP socket within the deadline");
			}

			BootReport report;
			report.version = kEngineVersion;
			report.peer_id = last_peer_id_;
			report.listen_port = port;
			return Result<BootReport>::ok(std::move(report));
		} catch (const lt::system_error& e) {
			session_.reset();
			return Result<BootReport>::failed(
				BridgeError::engine_failure, std::string("session start failed: ") + e.what());
		} catch (const std::exception& e) {
			session_.reset();
			return Result<BootReport>::failed(BridgeError::internal,
				std::string("session start failed: ") + e.what());
		} catch (...) {
			session_.reset();
			return Result<BootReport>::failed(BridgeError::internal,
				"session start failed: unknown exception");
		}
	}

	Result<void> apply(const SessionConfiguration& config)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> startedResult = requireStartedLocked();
		if (!startedResult.is_ok()) {
			return startedResult;
		}
		std::string configurationError;
		if (!validate_configuration(config, configurationError)) {
			return Result<void>::failed(BridgeError::invalid_argument,
				std::move(configurationError));
		}
		try {
			// apply_settings is asynchronous inside libtorrent, but the call itself
			// is the documented live configuration boundary and does not drop handles.
			session_->apply_settings(make_settings(config));
			default_download_dir_ = config.download_dir;
			last_peer_id_ = config.peer_id_prefix;
			timeout_ = Millis{config.operation_timeout_ms > 0
				? config.operation_timeout_ms : kDefaultTimeoutMs};
			return Result<void>::success();
		} catch (const lt::system_error& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string("session settings apply failed: ") + e.what());
		} catch (const std::exception& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string("session settings apply failed: ") + e.what());
		} catch (...) {
			return Result<void>::failed(BridgeError::internal,
				"session settings apply failed: unknown exception");
		}
	}

	void shutdown() noexcept
	{
		std::lock_guard<std::mutex> lock(mutex_);
		shutdownLocked();
	}

	void shutdownLocked() noexcept
	{
		if (stop_requested_.load()) {
			return;
		}
		stop_requested_.store(true);
		wait_wake_.notify_all();
		if (!session_) {
			return;
		}
		try {
			// The exact teardown rule from the WP-01 session fixture: pause the
			// session, drain remaining alerts, then abort() and let the proxy
			// destructor join the network thread. Destroying a still-joinable
			// session_proxy by overwrite would std::terminate.
			session_->pause();
			pumpLocked();
			{
				const lt::session_proxy proxy = session_->abort();
				session_.reset();
			}
			handles_.clear();
			pending_.clear();
		} catch (...) {
			// shutdown must never throw; a raw session leak at worst
			session_.reset();
			handles_.clear();
			pending_.clear();
		}
	}

	// --- alert pumping -----------------------------------------------------

	void pumpLocked()
	{
		scratch_.clear();
		session_->pop_alerts(&scratch_);
		for (const lt::alert* alert : scratch_) {
			alerts_seen_++;
			pending_.push_back(convertAlert(*alert));
		}
	}

	std::vector<EngineAlertDTO> drainAlerts(std::size_t max_count)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return drainLocked(max_count);
	}

	std::vector<EngineAlertDTO> drainLocked(std::size_t max_count)
	{
		// Pump new alerts from the session before draining the pending queue.
		// Without this, alerts posted after startup (e.g., add_torrent_alert,
		// state_changed_alert, torrent_checked_alert) would never be seen.
		pumpLocked();

		// 0 is documented as "no cap": the default drain request must never
		// accidentally keep alerts queued (that is how a batch is missed).
		const std::size_t take = max_count == 0 ? pending_.size()
												: std::min(max_count, pending_.size());
		std::vector<EngineAlertDTO> out;
		out.reserve(take);
		for (std::size_t i = 0; i < take; ++i) {
			out.push_back(std::move(pending_[i]));
		}
		if (take < pending_.size()) {
			pending_.erase(pending_.begin(),
				pending_.begin() + static_cast<std::ptrdiff_t>(take));
		} else {
			pending_.clear();
		}
		return out;
	}

	EngineAlertDTO convertAlert(const lt::alert& alert)
	{
		EngineAlertDTO dto;
		dto.kind = EngineAlertKind::unknown;

		// Progress comes from the live handle status, not the alert payload:
		// the alert only carries state/error, so a per-alert status() poll is
		// the only truthful source (and it is cheap: no disk or network work).
		const auto fill_progress = [&dto](const lt::torrent_handle& h) {
			try {
				const lt::torrent_status status = h.status();
				dto.progress = static_cast<double>(status.progress);
			} catch (...) {
				// a handle that died mid-conversion keeps the -1 sentinel
			}
		};

		// torrent_alert::alert_type only exists under ABI v1 and would be a
		// [[deprecated]] dejure global base, so per-case extracts take the
		// handle from each concrete alert instead of casting to the base.
		switch (alert.type()) {
		case lt::state_changed_alert::alert_type: {
			const auto* a = static_cast<const lt::state_changed_alert*>(&alert);
			dto.kind = EngineAlertKind::state_changed;
			dto.state = static_cast<int>(a->state);
			fill_progress(a->handle);
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			break;
		}
		case lt::torrent_checked_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_checked_alert*>(&alert);
			dto.kind = EngineAlertKind::checked;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::torrent_finished_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_finished_alert*>(&alert);
			dto.kind = EngineAlertKind::finished;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::torrent_paused_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_paused_alert*>(&alert);
			dto.kind = EngineAlertKind::paused;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::torrent_resumed_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_resumed_alert*>(&alert);
			dto.kind = EngineAlertKind::resumed;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::metadata_received_alert::alert_type: {
			const auto* a = static_cast<const lt::metadata_received_alert*>(&alert);
			dto.kind = EngineAlertKind::metadata_received;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::torrent_error_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_error_alert*>(&alert);
			dto.kind = EngineAlertKind::error;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.error = a->error.message();
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::torrent_removed_alert::alert_type: {
			const auto* a = static_cast<const lt::torrent_removed_alert*>(&alert);
			dto.kind = EngineAlertKind::removed;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::add_torrent_alert::alert_type: {
			const auto* a = static_cast<const lt::add_torrent_alert*>(&alert);
			dto.kind = EngineAlertKind::state_changed;
			dto.torrent_id = id_string(a->handle.info_hashes());
			dto.message = a->message();
			fill_progress(a->handle);
			break;
		}
		case lt::listen_succeeded_alert::alert_type: {
			const auto* a = static_cast<const lt::listen_succeeded_alert*>(&alert);
			if (is_tcp_listen(a->socket_type)) {
				dto.kind = EngineAlertKind::session;
				last_tcp_listen_port_ = static_cast<int>(a->port);
			}
			dto.message = a->message();
			break;
		}
		case lt::listen_failed_alert::alert_type:
		case lt::performance_alert::alert_type: {
			dto.kind = EngineAlertKind::session;
			dto.message = alert.message();
			break;
		}
		case lt::save_resume_data_alert::alert_type:
		case lt::save_resume_data_failed_alert::alert_type:
			// Consumed synchronously inside requestResumeData; never batched.
			dto.kind = EngineAlertKind::unknown;
			return dto;
		default:
			break;
		}

		if (dto.message.empty()) {
			dto.message = alert.message();
		}
		return dto;
	}

	// Bounded wait for the TCP listen socket. Returns 0 once bound, -2 if
	// shutdown was requested, or -1 on deadline. Uses the listen alert (only
	// when the alert is for a TCP socket; udp/utp sockets post too). The mutex
	// is released while sleeping so shutdown() can acquire it and wake us.
	int waitForListenLocked(std::unique_lock<std::mutex>& lock, Millis timeout)
	{
		last_tcp_listen_port_ = -1;
		const Deadline deadline = Clock::now() + timeout;
		while (Clock::now() < deadline) {
			if (stop_requested_.load()) {
				return -2;
			}
			pumpLocked();
			if (last_tcp_listen_port_ > 0) {
				return 0;
			}
			// Release the mutex for a bounded slice; a concurrent shutdown()
			// sets stop_requested_ and notify_all()s, ending the wait early.
			wait_wake_.wait_for(lock, std::min(Millis{50}, timeout),
				[this] { return stop_requested_.load(); });
		}
		return -1;
	}

	// --- torrent operations ------------------------------------------------

	Result<AddResult> add(const AddSpecification& spec)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return Result<AddResult>::failed(started.error_code(), started.error_message());
		}
		const std::string savePath = spec.save_path.empty()
			? default_download_dir_ : spec.save_path;
		if (savePath.empty()) {
			return Result<AddResult>::failed(BridgeError::invalid_argument,
				"add: save_path and configured download_dir must not both be empty");
		}
		const bool has_file = !spec.torrent_file.empty();
		const bool has_magnet = !spec.magnet_uri.empty();
		if (has_file == has_magnet) {
			return Result<AddResult>::failed(BridgeError::invalid_argument,
				"add: provide exactly one of torrent_file or magnet_uri");
		}

		try {
			lt::add_torrent_params atp;
			if (has_file) {
				atp = lt::load_torrent_buffer(spec.torrent_file);
			} else {
				atp = lt::parse_magnet_uri(spec.magnet_uri);
			}
			atp.save_path = savePath;
			// Deterministic flags: the coordinator owns the state machine, so
			// the engine neither auto-manages nor inherits seed-mode flags.
			atp.flags &= ~lt::torrent_flags::auto_managed;
			atp.flags &= ~lt::torrent_flags::paused;
			if (spec.paused) {
				atp.flags |= lt::torrent_flags::paused;
			}

			// NOTE: add_torrent can throw duplicate_torrent; caught below and
			// reported as a structured engine_failure.
			const lt::torrent_handle handle = session_->add_torrent(std::move(atp));
			if (!handle.is_valid()) {
				return Result<AddResult>::failed(BridgeError::engine_failure,
					"add_torrent returned an invalid handle");
			}
			const lt::info_hash_t hashes = handle.info_hashes();
			const TorrentRecordID id = id_string(hashes);
			handles_[id] = handle;

			AddResult result;
			result.torrent_id = id;
			result.info_hash = describe_hashes(hashes);
			const lt::torrent_status status = handle.status();
			result.name = status.name.empty() ? "(unknown)" : status.name;
			result.total_size = status.total_wanted > 0 ? status.total_wanted : -1;
			return Result<AddResult>::ok(std::move(result));
		} catch (const lt::system_error& e) {
			if (e.code() == lt::errors::duplicate_torrent) {
				return Result<AddResult>::failed(BridgeError::engine_failure,
					std::string("duplicate torrent: ") + e.what());
			}
			return Result<AddResult>::failed(BridgeError::engine_failure,
				std::string("add failed: ") + e.what());
		} catch (const std::exception& e) {
			return Result<AddResult>::failed(BridgeError::internal,
				std::string("add failed: ") + e.what());
		} catch (...) {
			return Result<AddResult>::failed(BridgeError::internal,
				"add failed: unknown exception");
		}
	}

	Result<void> withHandleLocked(const TorrentRecordID& id, std::string_view what,
		const std::function<void(const lt::torrent_handle&)>& fn)
	{
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return started;
		}
		Result<lt::torrent_handle> handle = findHandleLocked(id);
		if (!handle.is_ok()) {
			return Result<void>::failed(handle.error_code(), handle.error_message());
		}
		try {
			fn(handle.value());
			if (stop_requested_.load()) {
				return Result<void>::failed(BridgeError::stopped,
					std::string(what) + " aborted by shutdown");
			}
			return Result<void>::success();
		} catch (const lt::system_error& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string(what) + " failed: " + e.what());
		} catch (const std::exception& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string(what) + " failed: " + e.what());
		} catch (...) {
			return Result<void>::failed(BridgeError::internal,
				std::string(what) + " failed: unknown exception");
		}
	}

	Result<void> pause(const TorrentRecordID& id)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return withHandleLocked(id, "pause", [](const lt::torrent_handle& h) { h.pause(); });
	}

	Result<void> resume(const TorrentRecordID& id)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return withHandleLocked(id, "resume", [](const lt::torrent_handle& h) { h.resume(); });
	}

	Result<void> requestRecheck(const TorrentRecordID& id)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return withHandleLocked(id, "recheck", [](const lt::torrent_handle& h) {
			h.force_recheck();
		});
	}

	Result<void> setLimits(const TorrentRecordID& id, const TorrentLimits& limits)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> startedResult = requireStartedLocked();
		if (!startedResult.is_ok()) {
			return startedResult;
		}
		if (limits.max_download_bytes_per_sec.has_value()
			&& (*limits.max_download_bytes_per_sec < 0
				|| *limits.max_download_bytes_per_sec > std::numeric_limits<int>::max())) {
			return Result<void>::failed(BridgeError::invalid_argument,
				"setLimits: download limit is outside the supported range");
		}
		if (limits.max_upload_bytes_per_sec.has_value()
			&& (*limits.max_upload_bytes_per_sec < 0
				|| *limits.max_upload_bytes_per_sec > std::numeric_limits<int>::max())) {
			return Result<void>::failed(BridgeError::invalid_argument,
				"setLimits: upload limit is outside the supported range");
		}
		if (limits.ratio_limit.has_value()
			&& (!std::isfinite(*limits.ratio_limit) || *limits.ratio_limit < 0)) {
			return Result<void>::failed(BridgeError::invalid_argument,
				"setLimits: ratio limit must be finite and non-negative");
		}
		if (limits.seed_time_seconds.has_value() && *limits.seed_time_seconds < 0) {
			return Result<void>::failed(BridgeError::invalid_argument,
				"setLimits: seed time must be non-negative");
		}
		// Swift intentionally validates seed goals only as non-negative because
		// this native boundary owns the signed range of its ABI-facing values.
		// Rejecting an unrepresentable value here gives the full IPC path a native
		// invalidArgument case without persisting or applying it.
		if (limits.seed_time_seconds.has_value()
			&& *limits.seed_time_seconds > std::numeric_limits<int>::max()) {
			return Result<void>::failed(BridgeError::invalid_argument,
				"setLimits: seed time is outside the native signed range");
		}
		// libtorrent 2.x exposes per-torrent bandwidth setters, but its ABI 2
		// public handle has no per-torrent ratio or seed-time setter. Refusing
		// those fields is safer than persisting a goal the engine will ignore.
		if ((limits.ratio_limit.has_value() && *limits.ratio_limit > 0)
			|| (limits.seed_time_seconds.has_value() && *limits.seed_time_seconds > 0)) {
			return Result<void>::failed(BridgeError::unsupported_operation,
				"setLimits: ratio and seed-time goals are unsupported by libtorrent ABI 2");
		}

		const Result<lt::torrent_handle> found = findHandleLocked(id);
		if (!found.is_ok()) {
			return Result<void>::failed(found.error_code(), found.error_message());
		}

		const auto toLimit = [](const std::optional<std::int64_t>& value) {
			return value.has_value() && *value > 0 ? static_cast<int>(*value) : -1;
		};
		try {
			const lt::torrent_handle& handle = found.value();
			handle.set_download_limit(toLimit(limits.max_download_bytes_per_sec));
			handle.set_upload_limit(toLimit(limits.max_upload_bytes_per_sec));
			return Result<void>::success();
		} catch (const std::exception& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string("setLimits failed: ") + e.what());
		} catch (...) {
			return Result<void>::failed(BridgeError::internal,
				"setLimits failed: unknown exception");
		}
	}

	Result<AppliedTorrentLimits> currentLimits(const TorrentRecordID& id)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> startedResult = requireStartedLocked();
		if (!startedResult.is_ok()) {
			return Result<AppliedTorrentLimits>::failed(
				startedResult.error_code(), startedResult.error_message());
		}
		const Result<lt::torrent_handle> found = findHandleLocked(id);
		if (!found.is_ok()) {
			return Result<AppliedTorrentLimits>::failed(found.error_code(), found.error_message());
		}
		try {
			AppliedTorrentLimits result;
			result.max_download_bytes_per_sec = found.value().download_limit();
			result.max_upload_bytes_per_sec = found.value().upload_limit();
			return Result<AppliedTorrentLimits>::ok(std::move(result));
		} catch (const std::exception& e) {
			return Result<AppliedTorrentLimits>::failed(
				BridgeError::engine_failure, std::string("currentLimits failed: ") + e.what());
		} catch (...) {
			return Result<AppliedTorrentLimits>::failed(
				BridgeError::internal, "currentLimits failed: unknown exception");
		}
	}

	Result<void> editTrackers(const TorrentRecordID& id,
		const std::vector<std::string>& trackers)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> startedResult = requireStartedLocked();
		if (!startedResult.is_ok()) {
			return startedResult;
		}
		const Result<lt::torrent_handle> found = findHandleLocked(id);
		if (!found.is_ok()) {
			return Result<void>::failed(found.error_code(), found.error_message());
		}
		std::vector<lt::announce_entry> entries;
		entries.reserve(trackers.size());
		for (const std::string& tracker : trackers) {
			if (!valid_tracker_url(tracker)) {
				return Result<void>::failed(BridgeError::invalid_argument,
					"editTrackers: tracker URL is malformed or uses an unsupported scheme");
			}
			entries.emplace_back(tracker);
		}
		try {
			found.value().replace_trackers(entries);
			return Result<void>::success();
		} catch (const std::exception& e) {
			return Result<void>::failed(BridgeError::engine_failure,
				std::string("editTrackers failed: ") + e.what());
		} catch (...) {
			return Result<void>::failed(BridgeError::internal,
				"editTrackers failed: unknown exception");
		}
	}

	Result<void> reannounce(const TorrentRecordID& id)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return withHandleLocked(id, "reannounce", [](const lt::torrent_handle& h) {
			h.force_reannounce(0, lt::torrent_handle::high_priority);
		});
	}

	Result<RemovalToken> prepareRemoval(const TorrentRecordID& id, bool delete_files)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return Result<RemovalToken>::failed(started.error_code(), started.error_message());
		}
		Result<lt::torrent_handle> handle = findHandleLocked(id);
		if (!handle.is_ok()) {
			return Result<RemovalToken>::failed(handle.error_code(), handle.error_message());
		}
		// The lookup validates the record exists; the token carries the
		// semantics and an opaque nonce so a stale token cannot be reused
		// against a different lifecycle (defense against token confusion).
		RemovalToken token;
		token.torrent_id = id;
		token.delete_files = delete_files;
		token.nonce = static_cast<std::uint64_t>(alerts_seen_)
			^ std::hash<std::string>{}(id)
			^ static_cast<std::uint64_t>(
				Clock::now().time_since_epoch().count());
		return Result<RemovalToken>::ok(std::move(token));
	}

	Result<RemovalResult> commitRemoval(const RemovalToken& token)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return Result<RemovalResult>::failed(started.error_code(), started.error_message());
		}
		Result<lt::torrent_handle> handle = findHandleLocked(token.torrent_id);
		if (!handle.is_ok()) {
			return Result<RemovalResult>::failed(handle.error_code(), handle.error_message());
		}

		try {
			lt::remove_flags_t flags{};
			if (token.delete_files) {
				flags |= lt::session_handle::delete_files;
			}
			// Non-blocking; libtorrent removes the torrent from the session
			// synchronously and posts torrent_removed_alert (status category,
			// in our mask). The record dies here so later ops fail fast.
			session_->remove_torrent(handle.value(), flags);
			handles_.erase(token.torrent_id);

			RemovalResult result;
			result.torrent_id = token.torrent_id;
			result.files_deleted = token.delete_files;
			return Result<RemovalResult>::ok(std::move(result));
		} catch (const std::exception& e) {
			return Result<RemovalResult>::failed(BridgeError::engine_failure,
				std::string("remove failed: ") + e.what());
		} catch (...) {
			return Result<RemovalResult>::failed(BridgeError::internal,
				"remove failed: unknown exception");
		}
	}

	Result<ResumeDataDTO> requestResumeData(const TorrentRecordID& id)
	{
		// unique_lock so the wait loop can release the mutex while sleeping
		// (shutdown() must be able to acquire it and wake us).
		std::unique_lock<std::mutex> lock(mutex_);
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return Result<ResumeDataDTO>::failed(started.error_code(), started.error_message());
		}
		Result<lt::torrent_handle> handle = findHandleLocked(id);
		if (!handle.is_ok()) {
			return Result<ResumeDataDTO>::failed(handle.error_code(), handle.error_message());
		}

		try {
			handle.value().save_resume_data(lt::torrent_handle::save_info_dict
				| lt::torrent_handle::flush_disk_cache);
			const Deadline deadline = Clock::now() + timeout_;
			while (Clock::now() < deadline) {
				if (stop_requested_.load()) {
					return Result<ResumeDataDTO>::failed(BridgeError::stopped,
						"resume data request aborted by shutdown");
				}
				pumpLocked();
				// scan the raw alerts; save_resume_data alerts are filtered
				// out of pending_ by convertAlert, so they are only reachable
				// through the scratch buffer here.
				for (const lt::alert* a : scratch_) {
					if (const auto* saved = lt::alert_cast<lt::save_resume_data_alert>(a)) {
						if (saved->handle == handle.value()) {
							ResumeDataDTO dto;
							dto.torrent_id = id;
							dto.resume_data = lt::write_resume_data_buf(saved->params);
							return Result<ResumeDataDTO>::ok(std::move(dto));
						}
					}
					if (const auto* failed = lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
						if (failed->handle == handle.value()) {
							return Result<ResumeDataDTO>::failed(
								BridgeError::engine_failure,
								std::string("save_resume_data failed: ")
									+ failed->error.message());
						}
					}
				}
				// Release the mutex while sleeping; shutdown() can then acquire
				// it, set stop_requested_, and notify_all() to end this wait.
				wait_wake_.wait_for(lock, std::min(Millis{50}, timeout_),
					[this] { return stop_requested_.load(); });
			}
			return Result<ResumeDataDTO>::failed(BridgeError::timeout,
				"resume data request timed out");
		} catch (const std::exception& e) {
			return Result<ResumeDataDTO>::failed(BridgeError::engine_failure,
				std::string("requestResumeData failed: ") + e.what());
		} catch (...) {
			return Result<ResumeDataDTO>::failed(BridgeError::internal,
				"requestResumeData failed: unknown exception");
		}
	}

	Result<SessionStateDTO> saveSessionState()
	{
		std::lock_guard<std::mutex> lock(mutex_);
		const Result<void> started = requireStartedLocked();
		if (!started.is_ok()) {
			return Result<SessionStateDTO>::failed(started.error_code(), started.error_message());
		}
		try {
			const lt::session_params params = session_->session_state(
				lt::session_handle::save_settings | lt::session_handle::save_dht_state);
			SessionStateDTO dto;
			dto.session_state = lt::write_session_params_buf(params);
			return Result<SessionStateDTO>::ok(std::move(dto));
		} catch (const std::exception& e) {
			return Result<SessionStateDTO>::failed(BridgeError::engine_failure,
				std::string("saveSessionState failed: ") + e.what());
		} catch (...) {
			return Result<SessionStateDTO>::failed(BridgeError::internal,
				"saveSessionState failed: unknown exception");
		}
	}

	HealthDTO health() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		HealthDTO h;
		h.running = (session_ != nullptr);
		h.uptime_seconds = static_cast<std::uint64_t>(
			std::chrono::duration_cast<std::chrono::seconds>(Clock::now() - started).count());
		h.active_torrents = handles_.size();
		h.alerts_seen = alerts_seen_;
		if (!session_) {
			return h;
		}
		int down = 0;
		int up = 0;
		for (const auto& [id, handle] : handles_) {
			(void)id;
			try {
				const lt::torrent_status status = handle.status(
					lt::torrent_handle::query_accurate_download_counters);
				down += status.download_rate;
				up += status.upload_rate;
			} catch (...) {
				// a handle that died mid-poll simply contributes 0
			}
		}
		h.download_rate = down;
		h.upload_rate = up;
		return h;
	}

	Result<void> setOperationTimeout(std::uint32_t millis)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		timeout_ = Millis{millis > 0 ? millis : kDefaultTimeoutMs};
		return Result<void>::success();
	}

	// --- guarded helpers (caller holds mutex_) ---------------------------

	Result<void> requireStartedLocked() const noexcept
	{
		if (!session_) {
			return Result<void>::failed(BridgeError::not_started,
				"engine is not running (start() was not called or shutdown completed)");
		}
		return Result<void>::success();
	}

	Result<lt::torrent_handle> findHandleLocked(const TorrentRecordID& id) const noexcept
	{
		const auto it = handles_.find(id);
		if (it == handles_.end()) {
			return Result<lt::torrent_handle>::failed(BridgeError::not_found,
				"no torrent registered for id " + id);
		}
		return Result<lt::torrent_handle>::ok(it->second);
	}

	// --- members -----------------------------------------------------------

	std::atomic<bool> stop_requested_{false};
	mutable std::mutex mutex_;
	std::condition_variable wait_wake_;
	std::unique_ptr<lt::session> session_;
	std::map<TorrentRecordID, lt::torrent_handle> handles_;
	std::vector<EngineAlertDTO> pending_;
	std::vector<lt::alert*> scratch_;
	std::uint64_t alerts_seen_{0};
	int last_tcp_listen_port_{-1};
	std::string last_peer_id_{"-TT0400-"};
	std::string default_download_dir_;
	Millis timeout_{kDefaultTimeoutMs};
	Clock::time_point started{Clock::now()};
};

namespace detail {
const char* internal_message(const char* fallback) noexcept
{
	return fallback != nullptr ? fallback : "internal failure";
}
} // namespace detail

// --- EngineBridge public methods (thin noexcept firewall) -------------------

EngineBridge::EngineBridge() : impl_(std::make_unique<Impl>()) {}

EngineBridge::~EngineBridge() = default;

Result<BootReport> EngineBridge::start(const SessionConfiguration& config) noexcept
{
	try {
		return impl_->start(config);
	} catch (const std::exception& e) {
		return Result<BootReport>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<BootReport>::failed(BridgeError::internal,
			detail::internal_message("start: unknown exception"));
	}
}

Result<void> EngineBridge::apply(const SessionConfiguration& config) noexcept
{
	try {
		return impl_->apply(config);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("apply: unknown exception"));
	}
}

Result<AddResult> EngineBridge::add(const AddSpecification& spec) noexcept
{
	try {
		return impl_->add(spec);
	} catch (const std::exception& e) {
		return Result<AddResult>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<AddResult>::failed(BridgeError::internal,
			detail::internal_message("add: unknown exception"));
	}
}

Result<void> EngineBridge::pause(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->pause(id);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("pause: unknown exception"));
	}
}

Result<void> EngineBridge::resume(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->resume(id);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("resume: unknown exception"));
	}
}

Result<void> EngineBridge::requestRecheck(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->requestRecheck(id);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("recheck: unknown exception"));
	}
}

Result<void> EngineBridge::setLimits(const TorrentRecordID& id,
	const TorrentLimits& limits) noexcept
{
	try {
		return impl_->setLimits(id, limits);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("setLimits: unknown exception"));
	}
}

Result<AppliedTorrentLimits> EngineBridge::currentLimits(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->currentLimits(id);
	} catch (const std::exception& e) {
		return Result<AppliedTorrentLimits>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<AppliedTorrentLimits>::failed(
			BridgeError::internal,
			detail::internal_message("currentLimits: unknown exception"));
	}
}

Result<void> EngineBridge::editTrackers(const TorrentRecordID& id,
	const std::vector<std::string>& trackers) noexcept
{
	try {
		return impl_->editTrackers(id, trackers);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("editTrackers: unknown exception"));
	}
}

Result<void> EngineBridge::reannounce(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->reannounce(id);
	} catch (const std::exception& e) {
		return Result<void>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("reannounce: unknown exception"));
	}
}

Result<RemovalToken> EngineBridge::prepareRemoval(const TorrentRecordID& id, bool delete_files) noexcept
{
	try {
		return impl_->prepareRemoval(id, delete_files);
	} catch (const std::exception& e) {
		return Result<RemovalToken>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<RemovalToken>::failed(BridgeError::internal,
			detail::internal_message("prepareRemoval: unknown exception"));
	}
}

Result<RemovalResult> EngineBridge::commitRemoval(const RemovalToken& token) noexcept
{
	try {
		return impl_->commitRemoval(token);
	} catch (const std::exception& e) {
		return Result<RemovalResult>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<RemovalResult>::failed(BridgeError::internal,
			detail::internal_message("commitRemoval: unknown exception"));
	}
}

std::vector<EngineAlertDTO> EngineBridge::drainAlerts(std::size_t max_count) noexcept
{
	try {
		return impl_->drainAlerts(max_count);
	} catch (...) {
		return {};
	}
}

Result<ResumeDataDTO> EngineBridge::requestResumeData(const TorrentRecordID& id) noexcept
{
	try {
		return impl_->requestResumeData(id);
	} catch (const std::exception& e) {
		return Result<ResumeDataDTO>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<ResumeDataDTO>::failed(BridgeError::internal,
			detail::internal_message("requestResumeData: unknown exception"));
	}
}

Result<SessionStateDTO> EngineBridge::saveSessionState() noexcept
{
	try {
		return impl_->saveSessionState();
	} catch (const std::exception& e) {
		return Result<SessionStateDTO>::failed(BridgeError::internal, e.what());
	} catch (...) {
		return Result<SessionStateDTO>::failed(BridgeError::internal,
			detail::internal_message("saveSessionState: unknown exception"));
	}
}

HealthDTO EngineBridge::health() const noexcept
{
	try {
		return impl_->health();
	} catch (...) {
		HealthDTO health;
		health.running = false;
		return health;
	}
}

Result<void> EngineBridge::setOperationTimeout(std::uint32_t millis) noexcept
{
	try {
		return impl_->setOperationTimeout(millis);
	} catch (...) {
		return Result<void>::failed(BridgeError::internal,
			detail::internal_message("setOperationTimeout: unknown exception"));
	}
}

void EngineBridge::shutdown() noexcept
{
	impl_->shutdown();
}

} // namespace torrentino::bridge
