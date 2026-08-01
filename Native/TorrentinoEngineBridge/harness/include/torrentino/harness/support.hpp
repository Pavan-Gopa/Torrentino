// Torrentino engine harness — shared support layer (WP-01).
//
// Role:     status codes, the exception firewall helper, logging, workspaces
//           and deterministic payload generation used by every scenario.
// Must not: perform any libtorrent work — this header stays engine agnostic so
//           the same conventions can be reused by the WP-04 bridge tests.
// Invariant: `run_guarded` is the only place that decides how a C++ exception
//           becomes a status code.
#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace torrentino::harness {

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
using Millis = std::chrono::milliseconds;

// Mirrors torrentino_harness_status in harness_api.h.
enum class Status : int {
	ok = 0,
	assertion_failed = 1,
	libtorrent_error = 2,
	std_exception = 3,
	unknown_exception = 4,
	timeout = 5,
	usage_error = 6,
	io_error = 7,
};

const char* status_name(Status status) noexcept;

struct Outcome {
	Status status{Status::ok};
	std::string message;
	Millis duration{0};

	[[nodiscard]] bool ok() const noexcept { return status == Status::ok; }
};

// Scenario-level failure. Never escapes the harness: run_guarded turns it into
// Status::assertion_failed.
class AssertionFailure final : public std::runtime_error {
public:
	explicit AssertionFailure(const std::string& what) : std::runtime_error(what) {}
};

// A wait predicate did not become true in time. Distinct from a plain
// assertion so a hang is visible as a hang in the report (soak gate).
class TimeoutFailure final : public std::runtime_error {
public:
	explicit TimeoutFailure(const std::string& what) : std::runtime_error(what) {}
};

// --- string helpers --------------------------------------------------------
namespace detail {
inline void cat_into(std::ostringstream&) {}

template <class T, class... Rest>
void cat_into(std::ostringstream& out, const T& value, const Rest&... rest)
{
	out << value;
	cat_into(out, rest...);
}
} // namespace detail

// Small ostringstream-based concatenation: keeps log/assert call sites short
// without pulling in a formatting library.
template <class... Ts>
std::string cat(const Ts&... parts)
{
	std::ostringstream out;
	detail::cat_into(out, parts...);
	return out.str();
}

#define TH_REQUIRE(cond, ...)                                                                \
	do {                                                                                     \
		if (!(cond)) {                                                                       \
			throw ::torrentino::harness::AssertionFailure(::torrentino::harness::cat(        \
				__VA_ARGS__, " | failed: ", #cond, " @ ", __FILE__, ":", __LINE__));         \
		}                                                                                    \
	} while (false)

#define TH_REQUIRE_EQ(lhs, rhs, ...)                                                         \
	do {                                                                                     \
		const auto th_lhs = (lhs);                                                           \
		const auto th_rhs = (rhs);                                                           \
		if (!(th_lhs == th_rhs)) {                                                           \
			throw ::torrentino::harness::AssertionFailure(::torrentino::harness::cat(        \
				__VA_ARGS__, " | expected ", th_rhs, ", got ", th_lhs, " @ ", __FILE__, ":", \
				__LINE__));                                                                  \
		}                                                                                    \
	} while (false)

// --- logging ---------------------------------------------------------------
enum class LogLevel { info, warn, error };

void log_message(LogLevel level, std::string_view message);
inline void log_info(std::string_view m) { log_message(LogLevel::info, m); }
inline void log_warn(std::string_view m) { log_message(LogLevel::warn, m); }
inline void log_error(std::string_view m) { log_message(LogLevel::error, m); }

// --- exception firewall ----------------------------------------------------
// Runs `body` and converts anything it throws into an Outcome. This is the only
// function in the harness allowed to catch (...).
Outcome run_guarded(std::string_view label, const std::function<void()>& body) noexcept;

// --- filesystem ------------------------------------------------------------
// Scenario scratch directory. Removed on destruction unless `keep` is set, so a
// failing run can be inspected with --keep-workspace.
class Workspace {
public:
	Workspace(const fs::path& parent, std::string_view label, bool keep);
	~Workspace();

	Workspace(const Workspace&) = delete;
	Workspace& operator=(const Workspace&) = delete;

	[[nodiscard]] const fs::path& root() const noexcept { return root_; }
	// Creates (if needed) and returns a subdirectory of the workspace.
	[[nodiscard]] fs::path dir(std::string_view name) const;

private:
	fs::path root_;
	bool keep_;
};

std::vector<char> read_file(const fs::path& path);
void write_file_atomic(const fs::path& path, const std::vector<char>& bytes);
void write_text_atomic(const fs::path& path, std::string_view text);

// Deterministic payload: the same seed always yields the same bytes, so info
// hashes are stable across processes (crash-restore child vs parent) and runs.
void write_deterministic_file(const fs::path& path, std::uint64_t seed, std::int64_t size);
// Overwrites [offset, offset+length) with zeros to simulate a partially
// downloaded file: those pieces must then fail the hash check.
void zero_file_region(const fs::path& path, std::int64_t offset, std::int64_t length);

std::string sha256_file_hex(const fs::path& path);

// --- misc ------------------------------------------------------------------
std::string executable_path();
std::uint64_t resident_memory_bytes() noexcept;
std::string format_duration(Millis value);
std::string iso8601_utc_now();

} // namespace torrentino::harness
