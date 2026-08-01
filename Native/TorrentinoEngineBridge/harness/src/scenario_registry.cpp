// Torrentino engine harness — scenario registry (WP-01).
//
// Role: the ordered list of WP-01 acceptance scenarios. Order matters: cheap
//       structural checks run before anything that needs a live transfer, so a
//       broken build fails in seconds instead of minutes.
#include "torrentino/harness/scenario.hpp"

#include <algorithm>

namespace torrentino::harness {

const std::vector<Scenario>& all_scenarios()
{
	static const std::vector<Scenario> scenarios = {
		{"session_lifecycle", "start a session, bind loopback, shut down cleanly",
			&scenario_session_lifecycle},
		{"torrent_creation", "create v1 / v2 / hybrid torrents and re-read them",
			&scenario_torrent_creation},
		{"add_torrent_file", "add a .torrent from disk and verify existing data",
			&scenario_add_torrent_file},
		{"info_hash_recognition", "v1 / v2 / hybrid identity, magnet round-trip",
			&scenario_info_hash_recognition},
		{"pause_resume", "per-torrent and session-wide pause / resume",
			&scenario_pause_resume},
		{"resume_data", "save and reload resume data without losing partial data",
			&scenario_resume_data_roundtrip},
		{"session_state", "save and reload session state (settings survive restart)",
			&scenario_session_state_roundtrip},
		{"exception_containment", "every libtorrent exception stays inside the harness",
			&scenario_exception_containment},
		{"magnet_metadata", "fetch metadata from a local peer through a magnet link",
			&scenario_magnet_metadata},
		{"data_transfer", "transfer a payload over loopback and verify the digest",
			&scenario_data_transfer},
		{"crash_restore", "kill -9 a child mid-flight and restore registry + partial data",
			&scenario_crash_restore},
	};
	return scenarios;
}

const Scenario* find_scenario(std::string_view name)
{
	const std::vector<Scenario>& scenarios = all_scenarios();
	const auto it = std::find_if(scenarios.begin(), scenarios.end(),
		[name](const Scenario& scenario) { return scenario.name == name; });
	return it == scenarios.end() ? nullptr : &*it;
}

} // namespace torrentino::harness
