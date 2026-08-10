// Torrentino engine bridge — public C++ facade (WP-04).
//
// Role:     the single C++ surface the ObjC++ adapter — and through it the
//           Swift agent — may touch. Owns the libtorrent 2.x session, the
//           torrent primitives (add/pause/resume/recheck/remove), aggregated
//           alert batching and deterministic shutdown.
// Must not: let a libtorrent, Boost or OpenSSL type appear in this header.
//           The PIMPL boundary is what keeps Swift free of C++ types and the
//           exception firewall catches everything before it leaves a call.
// Threading: every public call is internally serialized and bounded by an
//           operation deadline; shutdown() unblocks in-flight waits so a
//           cancelled operation can never hang the agent.
#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace torrentino::bridge {

// Registry identity of a torrent record: the v1 info-hash hex when present,
// otherwise the v2 hex (the identity rule established by the WP-01 bakeoff).
using TorrentRecordID = std::string;
using TrackerTiers = std::vector<std::vector<std::string>>;

// Structured error taxonomy mirroring the Swift EngineCoordinatorError cases.
// Every public method converts a C++/libtorrent exception into one of these
// codes plus a human-readable message (the exception firewall).
enum class BridgeError : std::int32_t {
	none = 0,
	not_started = 1,     // engine never started (or already shut down)
	already_started = 2, // start() called twice
	not_found = 3,       // torrent id unknown to the engine
	timeout = 4,         // bounded wait expired (deadline enforced)
	invalid_argument = 5,
	engine_failure = 6,  // libtorrent/system_error surfaced by an operation
	io = 7,              // filesystem-level failure
	stopped = 8,         // operation aborted because shutdown was requested
	internal = 9,        // unknown exception at the firewall
	unsupported_operation = 10, // capability is not exposed by this libtorrent ABI
};

// Text form used by the ObjC adapter for NSError diagnostics.
const char* bridge_error_name(BridgeError code) noexcept;

// ---------------------------------------------------------------------------
// Value DTOs — plain structs, no third-party types (ADR-005).
// ---------------------------------------------------------------------------

struct SessionConfiguration {
	int listen_port = 0; // 0 = ephemeral loopback port (hermetic, WP-01 rule)
	// The session has no global save-path setting. The bridge keeps this value
	// as the default for an add request that does not provide an explicit path.
	std::string download_dir;
	bool enable_dht = false;
	bool enable_lsd = false;
	bool enable_upnp = false;
	bool enable_natpmp = false;
	bool encryption_enabled = true;
	int max_connections = 120;
	int max_active_downloads = 4;
	int max_active_seeds = 8;
	int max_connection_attempts = 20;
	std::int64_t cache_bytes = 64 * 1024 * 1024;
	std::int64_t max_download_bytes_per_sec = 0;
	std::int64_t max_upload_bytes_per_sec = 0;
	std::string proxy_kind = "none";
	std::string proxy_host;
	std::uint16_t proxy_port = 0;
	std::string proxy_username;
	// Stable prefix libtorrent expands into the 20-byte wire peer ID. The full
	// wire ID is synthesized inside libtorrent and not exposed by any
	// non-deprecated API in 2.x, so the boot report reports this configured,
	// deterministic prefix rather than calling the removed session.id().
	std::string peer_id_prefix = "-TT0400-";
	// Bounded-wait budget for every engine operation. A hanging libtorrent
	// call becomes a timeout Result, never a stuck actor.
	std::uint32_t operation_timeout_ms = 10000;
	std::uint32_t alert_queue_size = 8000;
};

struct TorrentLimits {
	// nil means unlimited for bandwidth fields. Ratio and seed-time goals are
	// optional so the adapter can distinguish an omitted goal from zero.
	std::optional<std::int64_t> max_download_bytes_per_sec;
	std::optional<std::int64_t> max_upload_bytes_per_sec;
	std::optional<double> ratio_limit;
	std::optional<std::int64_t> seed_time_seconds;
};

// Raw limits reported by the native handle. This libtorrent ABI reports 0 for
// an unlimited getter value; keeping the native result lets integration tests
// prove a rejected mutation did not change live engine state.
struct AppliedTorrentLimits {
	std::int64_t max_download_bytes_per_sec = -1;
	std::int64_t max_upload_bytes_per_sec = -1;
};

struct AddSpecification {
	// Exactly one of torrent_file / magnet_uri must be non-empty.
	std::vector<char> torrent_file;
	std::string magnet_uri;
	std::string save_path; // required
	bool paused = false;   // add paused (the coordinator owns the state machine)
	// Per-task peer-discovery policy (WP-11): -1 = leave engine default,
	// 0 = force disabled, 1 = force enabled. Private torrents must disable
	// DHT/PEX/LSD so peers are only discovered through the tracker.
	int enable_dht = -1;
	int enable_pex = -1;
	int enable_lsd = -1;
};

struct BootReport {
	std::string version;   // bridge + libtorrent versions
	std::string peer_id;   // configured wire peer-id prefix (see above)
	int listen_port = 0;
};

struct AddResult {
	TorrentRecordID torrent_id;
	std::string info_hash;  // "v1=... v2=..." description for diagnostics
	std::string name;
	std::int64_t total_size = 0; // -1 while metadata is unknown (magnet)
};

/// Identities parsed by the pinned libtorrent bridge from an exact torrent
/// byte buffer. Empty hex strings are not used as an implicit presence flag;
/// the booleans make v1/v2/hybrid shape explicit at the Swift boundary.
struct IndependentTorrentIdentity {
	bool has_v1 = false;
	bool has_v2 = false;
	std::string v1_hash;
	std::string v2_hash;
};

enum class EngineAlertKind : std::int32_t {
	state_changed = 0,
	checked = 1,
	finished = 2,
	paused = 3,
	resumed = 4,
	metadata_received = 5,
	error = 6,
	removed = 7,
	session = 8, // session-level notice (e.g. listen succeeded/failed)
	unknown = 9,
	storage_moved = 10,       // WP-10: async move_storage completed
	storage_moved_failed = 11, // WP-10: async move_storage failed
};

// Stable kebab-case names shared with the Swift DTO (plist keys).
const char* engine_alert_kind_name(EngineAlertKind kind) noexcept;

struct EngineAlertDTO {
	EngineAlertKind kind = EngineAlertKind::unknown;
	TorrentRecordID torrent_id; // empty for session-level alerts
	double progress = -1.0;     // -1 when not applicable
	int state = -1;             // raw libtorrent state code when available
	std::string error;          // message for error alerts
	std::string message;        // human-readable summary for logging
	// -1 means status() could not provide this live scalar; zero is a real
	// observation for an idle torrent.
	std::int64_t download_rate = -1;
	std::int64_t upload_rate = -1;
	std::int64_t downloaded_bytes = -1;
	std::int64_t uploaded_bytes = -1;
	int peers_connected = -1;
	int seeds_total = -1;
};

struct HealthDTO {
	std::uint64_t uptime_seconds = 0;
	std::size_t active_torrents = 0;
	int download_rate = 0; // bytes/s, aggregate across torrents
	int upload_rate = 0;   // bytes/s, aggregate across torrents
	std::uint64_t alerts_seen = 0;
	bool running = false;
};

struct ResumeDataDTO {
	TorrentRecordID torrent_id;
	std::vector<char> resume_data; // bencoded, write_resume_data_buf output
};

// Two-phase removal (ADR-010): prepareRemoval validates the record exists and
// freezes removal semantics into an opaque token; commitRemoval performs the
// actual removal. Nothing is deleted at prepare time, so a never-committed
// token is harmless (the torrent simply stays).
// WP-10 (Gate 6): the bridge is permanently delete-free. There is NO
// delete_files flag anywhere in this ABI and commitRemoval never passes
// lt::session_handle::delete_files — payload cleanup is exclusively the
// Swift agent's manifest-scoped Trash (TrashService), never libtorrent.
struct RemovalToken {
	TorrentRecordID torrent_id;
	std::uint64_t nonce = 0;
};

struct RemovalResult {
	TorrentRecordID torrent_id;
};

struct SessionStateDTO {
	std::vector<char> session_state; // bencoded session_params buffer
};

// ---------------------------------------------------------------------------
// Result<T> — value or structured failure. Never throws to the caller.
// ---------------------------------------------------------------------------

namespace detail {

const char* internal_message(const char* fallback) noexcept;

} // namespace detail

template <class T>
class Result final {
public:
	static Result ok(T value) { return Result(std::move(value)); }
	static Result failed(BridgeError code, std::string message)
	{
		return Result(code, std::move(message));
	}

	Result(Result&&) noexcept = default;
	Result& operator=(Result&&) noexcept = default;
	Result(const Result&) = delete;
	Result& operator=(const Result&) = delete;

	[[nodiscard]] bool is_ok() const noexcept { return error_code_ == BridgeError::none; }
	[[nodiscard]] BridgeError error_code() const noexcept { return error_code_; }
	[[nodiscard]] const std::string& error_message() const noexcept { return message_; }
	[[nodiscard]] const T& value() const noexcept { return value_; }

private:
	Result(T value) : value_(std::move(value)) {}
	Result(BridgeError code, std::string message)
		: error_code_(code), message_(std::move(message))
	{
	}
	T value_;
	BridgeError error_code_{BridgeError::none};
	std::string message_;
};

template <>
class Result<void> final {
public:
	// `ok` as a static factory name is shadowed by the non-static member below;
	// the template specialization therefore uses a named success factory.
	static Result success() { return Result(); }
	static Result failed(BridgeError code, std::string message)
	{
		return Result(code, std::move(message));
	}

	// The compiler resolves this member by name lookup inside the class, which
	// is unaffected by the static factory: only the return type differs.
	[[nodiscard]] bool is_ok() const noexcept { return error_code_ == BridgeError::none; }
	[[nodiscard]] BridgeError error_code() const noexcept { return error_code_; }
	[[nodiscard]] const std::string& error_message() const noexcept { return message_; }

private:
	Result() = default;
	Result(BridgeError code, std::string message)
		: error_code_(code), message_(std::move(message))
	{
	}
	BridgeError error_code_{BridgeError::none};
	std::string message_;
};

// ---------------------------------------------------------------------------
// EngineBridge — PIMPL facade over libtorrent (ADR-005).
// ---------------------------------------------------------------------------

class EngineBridge final {
public:
	EngineBridge();
	~EngineBridge();

	EngineBridge(const EngineBridge&) = delete;
	EngineBridge& operator=(const EngineBridge&) = delete;

	Result<BootReport> start(const SessionConfiguration& config) noexcept;
	// Applies live session settings without destroying torrent handles. The
	// download directory is retained as the default for subsequent adds.
	Result<void> apply(const SessionConfiguration& config) noexcept;
	Result<AddResult> add(const AddSpecification& spec) noexcept;
	/// Parses a complete .torrent byte buffer with the pinned libtorrent
	/// loader. This is a read-only verifier and does not require a running
	/// session or create an engine handle.
	Result<IndependentTorrentIdentity> verifyTorrent(const std::vector<char>& torrent_file) noexcept;
	Result<void> pause(const TorrentRecordID& id) noexcept;
	Result<void> resume(const TorrentRecordID& id) noexcept;
	Result<void> requestRecheck(const TorrentRecordID& id) noexcept;
	// WP-10: async storage move. Bounded wait for storage_moved_alert /
	// storage_moved_failed_alert. `dont_replace` semantics: files already
	// present at the destination are adopted, never overwritten.
	Result<void> moveStorage(const TorrentRecordID& id, const std::string& path) noexcept;
	Result<void> setLimits(const TorrentRecordID& id, const TorrentLimits& limits) noexcept;
	Result<AppliedTorrentLimits> currentLimits(const TorrentRecordID& id) noexcept;
	Result<void> editTrackers(const TorrentRecordID& id, const TrackerTiers& tracker_tiers) noexcept;
	// Reject-only compatibility stub; accepted edits use TrackerTiers.
	Result<void> editTrackers(const TorrentRecordID& id, const std::vector<std::string>& trackers) noexcept;
	Result<void> reannounce(const TorrentRecordID& id) noexcept;
	// WP-10 (Gate 6): no delete_files parameter — the bridge can never delete
	// payload bytes. Payload cleanup is the Swift agent's manifest-scoped Trash.
	Result<RemovalToken> prepareRemoval(const TorrentRecordID& id) noexcept;
	Result<RemovalResult> commitRemoval(const RemovalToken& token) noexcept;
	// Aggregated alert batch (never one alert per peer/piece). Returns an
	// empty batch when the engine is not running or has been shut down.
	std::vector<EngineAlertDTO> drainAlerts(std::size_t max_count) noexcept;
	Result<ResumeDataDTO> requestResumeData(const TorrentRecordID& id) noexcept;
	Result<SessionStateDTO> saveSessionState() noexcept;
	HealthDTO health() const noexcept;
	// Re-bounds the operation deadline (deadline/cancellation control).
	Result<void> setOperationTimeout(std::uint32_t millis) noexcept;
	// Deterministic shutdown: idempotent, noexcept, unblocks in-flight waits.
	void shutdown() noexcept;

private:
	struct Impl;
	std::unique_ptr<Impl> impl_;
};

} // namespace torrentino::bridge
