// Torrentino engine harness — C ABI boundary and CLI (WP-01).
//
// Role:     the exception firewall. Everything the harness does is invoked from
//           here inside try/catch, so `torrentino_harness_main` can be used like
//           a C function — the same contract the ObjC++ facade must honour in
//           WP-04.
// Must not: let a C++ exception, a libtorrent error object or a std::terminate
//           reach the caller.
#include "torrentino/harness/harness_api.h"

#include "torrentino/harness/scenario.hpp"
#include "torrentino/harness/soak.hpp"
#include "torrentino/harness/support.hpp"

#include <libtorrent/version.hpp>

#include <cstdlib>
#include <exception>
#include <iostream>
#include <string>
#include <vector>

namespace torrentino::harness {
namespace {

struct CliOptions {
	std::string command = "run-all";
	std::string argument;
	fs::path workspace_root;
	fs::path report_path;
	Millis step_timeout{120000};
	std::chrono::seconds soak_duration{std::chrono::hours{24}};
	std::chrono::seconds soak_report_interval{std::chrono::minutes{5}};
	bool keep_workspace = false;
};

void print_usage()
{
	std::cout << R"(torrentino-harness — headless libtorrent bakeoff harness (WP-01)

Usage:
  torrentino-harness [command] [options]

Commands:
  run-all                 run every scenario (default)
  run <scenario>          run a single scenario
  list                    list scenarios
  soak                    run the long-running soak
  version                 print harness and libtorrent versions
  internal-crash-child <dir>
                          internal: used by the crash_restore scenario

Options:
  --workspace <dir>       parent directory for scratch data (default: $TMPDIR)
  --keep-workspace        keep scratch data for post-mortem
  --timeout <seconds>     per-step timeout (default: 120)
  --duration <seconds>    soak duration (default: 86400)
  --report-interval <s>   soak progress interval (default: 300)
  --report <file>         soak JSON report path
)";
}

fs::path default_workspace_root()
{
	const char* tmp = std::getenv("TMPDIR");
	return fs::path(tmp != nullptr ? tmp : "/tmp") / "torrentino-harness";
}

// Deliberately minimal: a bakeoff harness must not grow a CLI framework.
CliOptions parse_arguments(const std::vector<std::string>& args)
{
	CliOptions options;
	options.workspace_root = default_workspace_root();

	std::size_t index = 0;
	if (index < args.size() && !args[index].empty() && args[index].rfind("--", 0) != 0) {
		options.command = args[index++];
		if (options.command == "run" || options.command == "internal-crash-child") {
			if (index >= args.size()) {
				throw AssertionFailure(cat("command '", options.command, "' needs an argument"));
			}
			options.argument = args[index++];
		}
	}

	for (; index < args.size(); ++index) {
		const std::string flag = args[index];
		auto value = [&args, &index, &flag]() -> std::string {
			if (index + 1 >= args.size()) {
				throw AssertionFailure(cat("option ", flag, " needs a value"));
			}
			return args[++index];
		};
		if (flag == "--workspace") {
			options.workspace_root = value();
		} else if (flag == "--keep-workspace") {
			options.keep_workspace = true;
		} else if (flag == "--timeout") {
			options.step_timeout = Millis{std::stoll(value()) * 1000};
		} else if (flag == "--duration") {
			options.soak_duration = std::chrono::seconds{std::stoll(value())};
		} else if (flag == "--report-interval") {
			options.soak_report_interval = std::chrono::seconds{std::stoll(value())};
		} else if (flag == "--report") {
			options.report_path = value();
		} else if (flag == "--help" || flag == "-h") {
			options.command = "help";
		} else {
			throw AssertionFailure(cat("unknown option: ", flag));
		}
	}
	return options;
}

void print_versions()
{
	std::cout << "torrentino-harness WP-01\n"
			  << "libtorrent " << LIBTORRENT_VERSION << " (num " << LIBTORRENT_VERSION_NUM << ")\n"
#if defined(TORRENT_USE_OPENSSL)
			  << "tls: openssl\n"
#else
			  << "tls: none\n"
#endif
			  << "abi: " << TORRENT_ABI_VERSION << '\n';
}

RunContext make_context(const CliOptions& options)
{
	RunContext ctx;
	ctx.workspace_root = options.workspace_root;
	ctx.keep_workspace = options.keep_workspace;
	ctx.step_timeout = options.step_timeout;
	std::error_code ec;
	fs::create_directories(ctx.workspace_root, ec);
	return ctx;
}

Status run_all(const CliOptions& options)
{
	RunContext ctx = make_context(options);
	std::size_t failed = 0;
	std::size_t passed = 0;
	Millis total{0};
	for (const Scenario& scenario : all_scenarios()) {
		log_info(cat("=== ", scenario.name, ": ", scenario.description));
		const Outcome outcome
			= run_guarded(scenario.name, [&scenario, &ctx]() { scenario.run(ctx); });
		total += outcome.duration;
		if (outcome.ok()) {
			++passed;
			log_info(cat("--- PASS ", scenario.name, " (", format_duration(outcome.duration), ')'));
		} else {
			++failed;
			log_error(cat("--- FAIL ", scenario.name, " [", status_name(outcome.status), "] ",
				outcome.message));
		}
	}
	log_info(
		cat("summary: ", passed, " passed, ", failed, " failed, total ", format_duration(total)));
	return failed == 0 ? Status::ok : Status::assertion_failed;
}

Status run_single(const CliOptions& options)
{
	const Scenario* scenario = find_scenario(options.argument);
	if (scenario == nullptr) {
		log_error(cat("unknown scenario: ", options.argument));
		return Status::usage_error;
	}
	RunContext ctx = make_context(options);
	log_info(cat("=== ", scenario->name, ": ", scenario->description));
	const Outcome outcome = run_guarded(scenario->name, [scenario, &ctx]() { scenario->run(ctx); });
	log_info(cat(outcome.ok() ? "--- PASS " : "--- FAIL ", scenario->name, " (",
		format_duration(outcome.duration), ')'));
	return outcome.status;
}

Status dispatch(const CliOptions& options)
{
	if (options.command == "help") {
		print_usage();
		return Status::ok;
	}
	if (options.command == "version") {
		print_versions();
		return Status::ok;
	}
	if (options.command == "list") {
		for (const Scenario& scenario : all_scenarios()) {
			std::cout << scenario.name << '\t' << scenario.description << '\n';
		}
		return Status::ok;
	}
	if (options.command == "run-all") {
		return run_all(options);
	}
	if (options.command == "run") {
		return run_single(options);
	}
	if (options.command == "soak") {
		SoakOptions soak;
		soak.workspace_root = options.workspace_root;
		soak.report_path = options.report_path.empty()
			? options.workspace_root / "soak-report.json"
			: options.report_path;
		soak.duration = options.soak_duration;
		soak.report_interval = options.soak_report_interval;
		soak.iteration_timeout = options.step_timeout;
		soak.keep_workspace = options.keep_workspace;
		std::error_code ec;
		fs::create_directories(soak.workspace_root, ec);
		return run_soak(soak);
	}
	if (options.command == "internal-crash-child") {
		run_crash_child(options.argument); // never returns
	}
	log_error(cat("unknown command: ", options.command));
	print_usage();
	return Status::usage_error;
}

// Last line of defence. If anything ever unwinds past run_guarded, say so loudly
// instead of dying with an unhelpful abort.
void on_terminate()
{
	std::cerr << "FATAL: std::terminate reached — an exception escaped the harness firewall\n";
	// Print what was in flight: without this a terminate is undebuggable, and a
	// terminate is exactly the failure mode this WP has to rule out.
	if (const std::exception_ptr in_flight = std::current_exception()) {
		try {
			std::rethrow_exception(in_flight);
		} catch (const std::exception& e) {
			std::cerr << "FATAL: in-flight exception: " << e.what() << '\n';
		} catch (...) {
			std::cerr << "FATAL: in-flight non-standard exception\n";
		}
	}
	std::cerr.flush();
	std::_Exit(static_cast<int>(Status::unknown_exception));
}

} // namespace
} // namespace torrentino::harness

int torrentino_harness_main(int argc, char* const argv[])
{
	using namespace torrentino::harness;
	std::set_terminate(&on_terminate);

	// The firewall itself: no exception, from libtorrent or from our own code,
	// may leave this function.
	try {
		std::vector<std::string> args;
		args.reserve(static_cast<std::size_t>(argc > 0 ? argc - 1 : 0));
		for (int i = 1; i < argc; ++i) {
			args.emplace_back(argv[i]);
		}
		const CliOptions options = parse_arguments(args);
		return static_cast<int>(dispatch(options));
	} catch (const AssertionFailure& e) {
		log_error(cat("usage: ", e.what()));
		return static_cast<int>(Status::usage_error);
	} catch (const std::exception& e) {
		log_error(cat("unhandled std::exception at the boundary: ", e.what()));
		return static_cast<int>(Status::std_exception);
	} catch (...) {
		log_error("unhandled non-standard exception at the boundary");
		return static_cast<int>(Status::unknown_exception);
	}
}
