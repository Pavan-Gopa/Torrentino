// Torrentino engine harness — scenario registry (WP-01).
//
// Role:     declares the WP-01 acceptance scenarios and the context they run in.
// Must not: hold global mutable state — each scenario gets its own workspace so
//           the suite can be re-run and individual cases can be run in isolation.
#pragma once

#include "torrentino/harness/support.hpp"

#include <string>
#include <string_view>
#include <vector>

namespace torrentino::harness {

struct RunContext {
	fs::path workspace_root; // parent for per-scenario workspaces
	bool keep_workspace = false;
	// Upper bound for every bounded wait inside a scenario. Exceeding it is a
	// hang, which is a gate failure — not something to retry.
	Millis step_timeout{60000};
};

using ScenarioFn = void (*)(RunContext&);

struct Scenario {
	std::string_view name;
	std::string_view description;
	ScenarioFn run;
};

const std::vector<Scenario>& all_scenarios();
const Scenario* find_scenario(std::string_view name);

// --- scenario entry points (scenarios_core.cpp) ----------------------------
void scenario_session_lifecycle(RunContext& ctx);
void scenario_torrent_creation(RunContext& ctx);
void scenario_add_torrent_file(RunContext& ctx);
void scenario_info_hash_recognition(RunContext& ctx);
void scenario_pause_resume(RunContext& ctx);
void scenario_magnet_metadata(RunContext& ctx);
void scenario_data_transfer(RunContext& ctx);

// --- scenario entry points (scenarios_persistence.cpp) ---------------------
void scenario_resume_data_roundtrip(RunContext& ctx);
void scenario_session_state_roundtrip(RunContext& ctx);
void scenario_exception_containment(RunContext& ctx);
void scenario_crash_restore(RunContext& ctx);

// Child half of the crash-restore scenario: sets up durable state and then
// SIGKILLs itself. Never returns.
[[noreturn]] void run_crash_child(const fs::path& workspace);

} // namespace torrentino::harness
