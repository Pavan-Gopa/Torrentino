// Torrentino engine harness — support layer implementation (WP-01).
//
// Role: see support.hpp. Everything here is engine agnostic; the only libtorrent
// knowledge is the `boost::system::system_error` translation in run_guarded,
// which is how libtorrent reports errors when it throws.
#include "torrentino/harness/support.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

#include <boost/system/system_error.hpp>

#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <system_error>

namespace torrentino::harness {
namespace {

std::mutex& log_mutex()
{
	static std::mutex m;
	return m;
}

const char* level_tag(LogLevel level) noexcept
{
	switch (level) {
	case LogLevel::info: return "INFO";
	case LogLevel::warn: return "WARN";
	case LogLevel::error: return "ERROR";
	}
	return "INFO";
}

// Monotonic counter so workspace names never collide inside one process.
std::atomic<unsigned> g_workspace_counter{0};

} // namespace

const char* status_name(Status status) noexcept
{
	switch (status) {
	case Status::ok: return "ok";
	case Status::assertion_failed: return "assertion_failed";
	case Status::libtorrent_error: return "libtorrent_error";
	case Status::std_exception: return "std_exception";
	case Status::unknown_exception: return "unknown_exception";
	case Status::timeout: return "timeout";
	case Status::usage_error: return "usage_error";
	case Status::io_error: return "io_error";
	}
	return "unknown";
}

void log_message(LogLevel level, std::string_view message)
{
	const std::lock_guard<std::mutex> lock(log_mutex());
	std::ostream& out = (level == LogLevel::error) ? std::cerr : std::cout;
	out << iso8601_utc_now() << ' ' << std::left << std::setw(5) << level_tag(level) << ' '
		<< message << '\n';
	out.flush();
}

Outcome run_guarded(std::string_view label, const std::function<void()>& body) noexcept
{
	const auto started = Clock::now();
	Outcome outcome;
	// Every catch clause below exists so that no exception can reach the C ABI
	// boundary. Order matters: the most specific harness types come first.
	try {
		body();
	} catch (const AssertionFailure& e) {
		outcome.status = Status::assertion_failed;
		outcome.message = e.what();
	} catch (const TimeoutFailure& e) {
		outcome.status = Status::timeout;
		outcome.message = e.what();
	} catch (const boost::system::system_error& e) {
		// libtorrent's throwing overloads report through boost::system.
		outcome.status = Status::libtorrent_error;
		outcome.message = cat(e.what(), " [", e.code().category().name(), ':', e.code().value(),
			' ', e.code().message(), ']');
	} catch (const std::system_error& e) {
		outcome.status = Status::io_error;
		outcome.message = cat(e.what(), " [", e.code().value(), ']');
	} catch (const std::exception& e) {
		outcome.status = Status::std_exception;
		outcome.message = e.what();
	} catch (...) {
		// Non-std throwable: keep the process alive, report the fact.
		outcome.status = Status::unknown_exception;
		outcome.message = "non-standard exception object";
	}
	outcome.duration
		= std::chrono::duration_cast<Millis>(Clock::now() - started);
	if (!outcome.ok()) {
		log_error(cat('[', label, "] ", status_name(outcome.status), ": ", outcome.message));
	}
	return outcome;
}

// --- Workspace -------------------------------------------------------------
Workspace::Workspace(const fs::path& parent, std::string_view label, bool keep)
	: keep_(keep)
{
	const unsigned serial = g_workspace_counter.fetch_add(1);
	root_ = parent / cat(label, '-', ::getpid(), '-', serial);
	std::error_code ec;
	fs::remove_all(root_, ec);
	fs::create_directories(root_, ec);
	if (ec) {
		throw std::system_error(ec, cat("cannot create workspace ", root_.string()));
	}
}

Workspace::~Workspace()
{
	if (keep_) {
		log_info(cat("workspace kept: ", root_.string()));
		return;
	}
	std::error_code ec;
	fs::remove_all(root_, ec); // destructor: report, never throw
	if (ec) {
		log_warn(cat("could not remove workspace ", root_.string(), ": ", ec.message()));
	}
}

fs::path Workspace::dir(std::string_view name) const
{
	fs::path p = root_ / name;
	std::error_code ec;
	fs::create_directories(p, ec);
	if (ec) {
		throw std::system_error(ec, cat("cannot create directory ", p.string()));
	}
	return p;
}

// --- file helpers ----------------------------------------------------------
std::vector<char> read_file(const fs::path& path)
{
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		throw std::system_error(errno, std::generic_category(), cat("cannot open ", path.string()));
	}
	return std::vector<char>((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void write_file_atomic(const fs::path& path, const std::vector<char>& bytes)
{
	// Write to a sibling temp file and rename: a crash in the middle of a save
	// must never leave a truncated resume/session file behind. This mirrors the
	// "atomic generation files" persistence rule of the engine agent.
	const fs::path tmp = path.string() + ".tmp";
	{
		std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
		if (!out) {
			throw std::system_error(errno, std::generic_category(),
				cat("cannot create ", tmp.string()));
		}
		if (!bytes.empty()) {
			out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
		}
		out.flush();
		if (!out) {
			throw std::system_error(errno, std::generic_category(), cat("write failed ", tmp.string()));
		}
	}
	std::error_code ec;
	fs::rename(tmp, path, ec);
	if (ec) {
		throw std::system_error(ec, cat("cannot rename ", tmp.string()));
	}
}

void write_text_atomic(const fs::path& path, std::string_view text)
{
	write_file_atomic(path, std::vector<char>(text.begin(), text.end()));
}

void write_deterministic_file(const fs::path& path, std::uint64_t seed, std::int64_t size)
{
	// splitmix64: tiny, deterministic, and good enough that no two pieces of the
	// payload collide, which keeps piece-level assertions meaningful.
	std::uint64_t state = seed + 0x9E3779B97F4A7C15ULL;
	auto next = [&state]() noexcept -> std::uint64_t {
		std::uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
		z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
		z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
		return z ^ (z >> 31);
	};

	std::error_code ec;
	fs::create_directories(path.parent_path(), ec);
	std::ofstream out(path, std::ios::binary | std::ios::trunc);
	if (!out) {
		throw std::system_error(errno, std::generic_category(), cat("cannot create ", path.string()));
	}

	constexpr std::size_t kChunk = 64 * 1024;
	std::vector<char> chunk(kChunk);
	std::int64_t written = 0;
	while (written < size) {
		const auto want = static_cast<std::size_t>(
			std::min<std::int64_t>(static_cast<std::int64_t>(kChunk), size - written));
		for (std::size_t i = 0; i < want; i += sizeof(std::uint64_t)) {
			const std::uint64_t value = next();
			const auto span = std::min(sizeof(std::uint64_t), want - i);
			std::memcpy(chunk.data() + i, &value, span);
		}
		out.write(chunk.data(), static_cast<std::streamsize>(want));
		if (!out) {
			throw std::system_error(errno, std::generic_category(), cat("write failed ", path.string()));
		}
		written += static_cast<std::int64_t>(want);
	}
}

void zero_file_region(const fs::path& path, std::int64_t offset, std::int64_t length)
{
	std::fstream file(path, std::ios::binary | std::ios::in | std::ios::out);
	if (!file) {
		throw std::system_error(errno, std::generic_category(), cat("cannot open ", path.string()));
	}
	file.seekp(static_cast<std::streamoff>(offset), std::ios::beg);
	const std::vector<char> zeros(static_cast<std::size_t>(std::min<std::int64_t>(length, 64 * 1024)), 0);
	std::int64_t remaining = length;
	while (remaining > 0) {
		const auto want = static_cast<std::streamsize>(
			std::min<std::int64_t>(static_cast<std::int64_t>(zeros.size()), remaining));
		file.write(zeros.data(), want);
		if (!file) {
			throw std::system_error(errno, std::generic_category(), cat("write failed ", path.string()));
		}
		remaining -= want;
	}
	file.flush();
}

std::string sha256_file_hex(const fs::path& path)
{
	// CommonCrypto ships with the system: no extra third-party dependency just
	// to compare payloads in a test harness.
	std::ifstream in(path, std::ios::binary);
	if (!in) {
		throw std::system_error(errno, std::generic_category(), cat("cannot open ", path.string()));
	}
	CC_SHA256_CTX ctx;
	CC_SHA256_Init(&ctx);
	std::vector<char> buffer(64 * 1024);
	while (in) {
		in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
		const auto got = in.gcount();
		if (got > 0) {
			CC_SHA256_Update(&ctx, buffer.data(), static_cast<CC_LONG>(got));
		}
	}
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256_Final(digest, &ctx);

	static const char* kHex = "0123456789abcdef";
	std::string out;
	out.reserve(sizeof(digest) * 2);
	for (unsigned char byte : digest) {
		out.push_back(kHex[byte >> 4]);
		out.push_back(kHex[byte & 0x0F]);
	}
	return out;
}

// --- misc ------------------------------------------------------------------
std::string executable_path()
{
	// The crash-restore scenario re-executes this very binary, so argv[0] is not
	// good enough (it may be relative and the child runs with a different cwd).
	std::uint32_t size = 0;
	_NSGetExecutablePath(nullptr, &size);
	std::string buffer(size, '\0');
	if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
		throw std::runtime_error("cannot determine executable path");
	}
	buffer.resize(std::strlen(buffer.c_str()));
	std::error_code ec;
	const fs::path canonical = fs::canonical(buffer, ec);
	return ec ? buffer : canonical.string();
}

std::uint64_t resident_memory_bytes() noexcept
{
	// Soak evidence: a slow leak has to be visible in the periodic report.
	mach_task_basic_info info{};
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	const kern_return_t rc = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
		reinterpret_cast<task_info_t>(&info), &count);
	return (rc == KERN_SUCCESS) ? static_cast<std::uint64_t>(info.resident_size) : 0;
}

std::string format_duration(Millis value)
{
	const auto total = value.count();
	const auto hours = total / 3600000;
	const auto minutes = (total % 3600000) / 60000;
	const auto seconds = (total % 60000) / 1000;
	const auto millis = total % 1000;
	std::ostringstream out;
	if (hours > 0) {
		out << hours << "h" << std::setfill('0') << std::setw(2) << minutes << "m"
			<< std::setw(2) << seconds << "s";
	} else if (minutes > 0) {
		out << minutes << "m" << std::setfill('0') << std::setw(2) << seconds << "s";
	} else {
		out << seconds << '.' << std::setfill('0') << std::setw(3) << millis << "s";
	}
	return out.str();
}

std::string iso8601_utc_now()
{
	const auto now = std::chrono::system_clock::now();
	const auto secs = std::chrono::time_point_cast<std::chrono::seconds>(now);
	const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now - secs).count();
	const std::time_t tt = std::chrono::system_clock::to_time_t(secs);
	std::tm tm{};
	gmtime_r(&tt, &tm);
	char stamp[32];
	std::strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &tm);
	std::ostringstream out;
	out << stamp << '.' << std::setfill('0') << std::setw(3) << millis << 'Z';
	return out.str();
}

} // namespace torrentino::harness
