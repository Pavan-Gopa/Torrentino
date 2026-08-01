// Torrentino engine harness — long-running soak (WP-01).
//
// Role:     repeats the full add → transfer → verify → resume → remove cycle for
//           hours to expose leaks, handle exhaustion and hangs that a one-shot
//           test never sees. This is the 24h gate of WP-01.
// Must not: silently continue after a stuck iteration — a hang is a failure and
//           has to be reported as one.
#pragma once

#include "torrentino/harness/support.hpp"

#include <chrono>

namespace torrentino::harness {

struct SoakOptions {
	fs::path workspace_root;
	fs::path report_path;
	std::chrono::seconds duration{std::chrono::hours{24}};
	std::chrono::seconds report_interval{std::chrono::minutes{5}};
	// A single cycle transfers a few MiB over loopback; anything slower than
	// this is a hang, not a slow machine.
	Millis iteration_timeout{300000};
	// Sessions are recreated periodically so the soak also covers repeated
	// start/stop, not only steady state.
	int session_recycle_interval{25};
	bool keep_workspace = false;
};

Status run_soak(const SoakOptions& options);

} // namespace torrentino::harness
