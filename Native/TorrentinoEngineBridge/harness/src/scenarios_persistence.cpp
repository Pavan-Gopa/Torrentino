// Torrentino engine harness — persistence and fault scenarios (WP-01).
//
// Role: proves the durability guarantees the product is built on — resume data,
//       session state, an exception firewall, and restore after `kill -9` with
//       neither registry nor partial data loss.
// Must not: rely on a graceful shutdown to make state durable; every durable
//       write happens before the crash, through the atomic writer.
#include "torrentino/harness/engine_ops.hpp"
#include "torrentino/harness/scenario.hpp"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>

#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>

#include <cstdlib>

// posix_spawn needs the current environment; in a main executable `environ` is
// the documented way to get it on macOS.
extern "C" char** environ;

namespace torrentino::harness {
namespace {

// A payload whose second half is zeroed: the hash check must accept exactly the
// first half, which gives us a stable "partially downloaded" state to protect.
struct PartialTorrent {
	CreatedTorrent torrent;
	std::int64_t expected_done{0};
};

PartialTorrent make_partial_download(const fs::path& source_dir, const fs::path& download_dir,
	const TorrentSpec& spec)
{
	const CreatedTorrent torrent = create_payload_torrent(source_dir, spec);
	std::error_code ec;
	fs::create_directories(download_dir, ec);
	const fs::path partial = download_dir / torrent.name;
	fs::copy_file(torrent.payload_path, partial, fs::copy_options::overwrite_existing, ec);
	if (ec) {
		throw std::system_error(ec, cat("cannot seed partial data in ", download_dir.string()));
	}
	// Zero from the middle to the end. The offset is piece aligned, so exactly
	// half of the pieces stay valid.
	const std::int64_t half = torrent.total_size / 2;
	zero_file_region(partial, half, torrent.total_size - half);
	return PartialTorrent{torrent, half};
}

SessionOptions options_for(std::string tag)
{
	SessionOptions options;
	options.tag = std::move(tag);
	return options;
}

// Layout shared by the crash child and its parent. Keeping it in one place is
// what makes the restore assertions meaningful instead of magic strings.
struct CrashLayout {
	explicit CrashLayout(const fs::path& root)
		: source(root / "source")
		, download(root / "download")
		, state(root / "state")
		, registry(state / "registry.tsv")
		, session_state(state / "session.dat")
		, resume(state / "torrent.resume")
		, torrent_file(state / "torrent.torrent")
	{
	}

	fs::path source;
	fs::path download;
	fs::path state;
	fs::path registry;
	fs::path session_state;
	fs::path resume;
	fs::path torrent_file;
};

TorrentSpec crash_spec()
{
	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.name = "crash-payload.bin";
	spec.size = 4 * 1024 * 1024;
	spec.piece_size = 64 * 1024;
	spec.seed = 0xC0FFEEULL; // fixed: parent and child must agree bit for bit
	return spec;
}

} // namespace

void scenario_resume_data_roundtrip(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "resume-data", ctx.keep_workspace);

	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.size = 4 * 1024 * 1024;
	spec.piece_size = 64 * 1024;
	const fs::path source = workspace.dir("source");
	const fs::path download = workspace.dir("download");
	const PartialTorrent partial = make_partial_download(source, download, spec);

	const SessionOptions options = options_for("resume");
	Session session(make_session_params(options), options.tag);

	lt::torrent_handle handle
		= add_torrent(session, atp_for(partial.torrent, download), ctx.step_timeout);
	lt::torrent_status status = wait_until_checked(session, handle, ctx.step_timeout);
	TH_REQUIRE_EQ(status.total_done, partial.expected_done,
		"the hash check must accept exactly the intact half of the payload");

	const std::vector<char> resume = save_resume_data(session, handle, ctx.step_timeout);
	const fs::path resume_file = workspace.root() / "torrent.resume";
	write_file_atomic(resume_file, resume);
	remove_torrent_keep_files(session, handle, ctx.step_timeout);

	// Restore path: read from disk, not from the buffer we still hold in memory.
	lt::error_code ec;
	lt::add_torrent_params restored = lt::read_resume_data(read_file(resume_file), ec);
	TH_REQUIRE(!ec, cat("read_resume_data failed: ", ec.message()));
	TH_REQUIRE(restored.info_hashes == partial.torrent.hashes
			|| (restored.ti && restored.ti->info_hashes() == partial.torrent.hashes),
		"resume data must carry the torrent identity");
	TH_REQUIRE_EQ(restored.save_path, download.string(), "resume data must carry the save path");
	apply_deterministic_flags(restored);

	handle = add_torrent(session, std::move(restored), ctx.step_timeout);
	status = wait_until_checked(session, handle, ctx.step_timeout);
	TH_REQUIRE_EQ(status.total_done, partial.expected_done,
		"restored torrent must keep every verified piece");
	TH_REQUIRE_EQ(status.num_pieces, partial.torrent.num_pieces / 2,
		"restored torrent must keep the same piece count");
	log_info(cat("resume round-trip preserved ", status.total_done, " of ",
		partial.torrent.total_size, " bytes"));

	session.shutdown();
}

void scenario_session_state_roundtrip(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "session-state", ctx.keep_workspace);
	const fs::path state_file = workspace.root() / "session.dat";

	constexpr int kConnectionsLimit = 137; // distinctive value: no default matches it
	const std::string user_agent = "Torrentino-Harness/state-probe";

	{
		SessionOptions options = options_for("state-writer");
		options.user_agent = user_agent;
		lt::session_params params = make_session_params(options);
		params.settings.set_int(lt::settings_pack::connections_limit, kConnectionsLimit);

		Session session(std::move(params), options.tag);
		session.listen_port(ctx.step_timeout);
		write_file_atomic(state_file, save_session_state(session));
		session.shutdown();
	}

	// A warm restart must reproduce the settings the user configured; losing them
	// silently is exactly the class of bug this gate exists for.
	const lt::session_params reloaded = lt::read_session_params(read_file(state_file));
	TH_REQUIRE_EQ(reloaded.settings.get_str(lt::settings_pack::user_agent), user_agent,
		"user agent must survive a session state round-trip");
	TH_REQUIRE_EQ(reloaded.settings.get_int(lt::settings_pack::connections_limit),
		kConnectionsLimit, "connections limit must survive a session state round-trip");

	Session restarted(lt::session_params(reloaded), "state-reader");
	const int port = restarted.listen_port(ctx.step_timeout);
	TH_REQUIRE(port > 0, "a session restored from saved state must still listen");
	TH_REQUIRE_EQ(restarted.raw().get_settings().get_int(lt::settings_pack::connections_limit),
		kConnectionsLimit, "restored session must apply the restored settings");
	log_info(cat("session state round-trip ok, restarted on 127.0.0.1:", port));
	restarted.shutdown();
}

void scenario_exception_containment(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "exception-containment", ctx.keep_workspace);

	// 1. Corrupt .torrent data: libtorrent throws, the firewall converts.
	const std::vector<char> garbage{'n', 'o', 't', ' ', 'b', 'e', 'n', 'c', 'o', 'd', 'e'};
	const Outcome parse = run_guarded("load_torrent_buffer(garbage)", [&garbage]() {
		const lt::add_torrent_params atp = lt::load_torrent_buffer(garbage);
		TH_REQUIRE(false, "parsing garbage must not succeed (name=", atp.name, ')');
	});
	TH_REQUIRE_EQ(static_cast<int>(parse.status), static_cast<int>(Status::libtorrent_error),
		"a libtorrent parse failure must surface as libtorrent_error");
	TH_REQUIRE(!parse.message.empty(), "translated errors must keep a diagnosable message");

	// 2. The error_code overloads must not throw at all — that is the shape the
	//    bridge will use on hot paths.
	lt::error_code ec;
	const lt::add_torrent_params bad_resume = lt::read_resume_data(garbage, ec);
	TH_REQUIRE(static_cast<bool>(ec), "read_resume_data must report an error_code for garbage");
	TH_REQUIRE(!bad_resume.ti, "a failed parse must not produce metadata");

	// 3. An invalid add_torrent (no metadata, no info hash) throws from inside the
	//    session; the session must stay usable afterwards.
	SessionOptions options = options_for("firewall");
	Session session(make_session_params(options), options.tag);
	const Outcome bad_add = run_guarded("add_torrent(empty)", [&session, &workspace]() {
		lt::add_torrent_params empty;
		empty.save_path = workspace.root().string();
		const lt::torrent_handle handle = session.raw().add_torrent(std::move(empty));
		TH_REQUIRE(!handle.is_valid(), "adding params without an identity must fail");
	});
	TH_REQUIRE(!bad_add.ok(), "adding an empty torrent must be reported as a failure");
	TH_REQUIRE_EQ(static_cast<int>(bad_add.status), static_cast<int>(Status::libtorrent_error),
		"invalid add_torrent must surface as libtorrent_error");

	// 4. A non-std throwable must not escape either.
	const Outcome exotic = run_guarded("throw int", []() { throw 42; });
	TH_REQUIRE_EQ(static_cast<int>(exotic.status), static_cast<int>(Status::unknown_exception),
		"a non-standard exception must be contained as unknown_exception");

	// 5. Proof of survival: the same session still performs real work.
	TorrentSpec spec;
	spec.size = 512 * 1024;
	spec.piece_size = 32 * 1024;
	const fs::path content = workspace.dir("content");
	const CreatedTorrent torrent = create_payload_torrent(content, spec);
	const lt::torrent_handle handle
		= add_torrent(session, atp_for(torrent, content), ctx.step_timeout);
	const lt::torrent_status status = wait_until_seeding(session, handle, ctx.step_timeout);
	TH_REQUIRE_EQ(status.total_done, torrent.total_size,
		"the session must remain fully functional after contained exceptions");
	log_info("all injected failures were contained inside the harness");

	session.shutdown();
}

void run_crash_child(const fs::path& workspace)
{
	// Child half of the crash test. Everything durable is written *before* the
	// process is killed; nothing here may rely on a destructor running.
	const CrashLayout layout(workspace);
	const TorrentSpec spec = crash_spec();

	// The child owns the whole layout: the parent only knows the root, so every
	// directory the child writes into has to exist before the first write.
	std::error_code ec;
	fs::create_directories(layout.source, ec);
	fs::create_directories(layout.download, ec);
	fs::create_directories(layout.state, ec);

	const PartialTorrent partial = make_partial_download(layout.source, layout.download, spec);
	write_file_atomic(layout.torrent_file, partial.torrent.bencoded);

	SessionOptions options;
	options.tag = "crash-child";
	Session session(make_session_params(options), options.tag);
	session.listen_port(Millis{30000});

	const lt::torrent_handle handle
		= add_torrent(session, atp_for(partial.torrent, layout.download), Millis{30000});
	const lt::torrent_status status = wait_until_checked(session, handle, Millis{60000});
	if (status.total_done != partial.expected_done) {
		log_error(cat("child: unexpected verified size ", status.total_done, ", expected ",
			partial.expected_done));
		std::_Exit(static_cast<int>(Status::assertion_failed));
	}

	write_file_atomic(layout.resume, save_resume_data(session, handle, Millis{30000}));
	write_file_atomic(layout.session_state, save_session_state(session));
	write_registry(layout.registry,
		{RegistryEntry{torrent_id(partial.torrent.hashes), partial.torrent.name, status.total_done,
			partial.torrent.total_size, layout.download.string()}});

	log_info(cat("child: state persisted (", status.total_done, " bytes verified), killing self"));
	// SIGKILL: no unwinding, no destructors, no libtorrent shutdown path — the
	// same thing a user's forced restart or an OOM kill would do.
	::kill(::getpid(), SIGKILL);
	// Unreachable; only here so the compiler sees a terminating path.
	std::_Exit(static_cast<int>(Status::unknown_exception));
}

void scenario_crash_restore(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "crash-restore", ctx.keep_workspace);
	const CrashLayout layout(workspace.root());
	const TorrentSpec spec = crash_spec();

	// --- phase 1: a child process builds durable state and is SIGKILLed -----
	const std::string self = executable_path();
	const std::string root = workspace.root().string();
	std::string arg0 = self;
	std::string arg1 = "internal-crash-child";
	std::string arg2 = root;
	char* argv[] = {arg0.data(), arg1.data(), arg2.data(), nullptr};

	::pid_t child = 0;
	const int spawned = ::posix_spawn(&child, self.c_str(), nullptr, nullptr, argv, environ);
	TH_REQUIRE_EQ(spawned, 0, "posix_spawn of the crash child failed");
	log_info(cat("spawned crash child pid=", child));

	int wait_status = 0;
	const ::pid_t reaped = ::waitpid(child, &wait_status, 0);
	TH_REQUIRE_EQ(reaped, child, "waitpid must reap the crash child");
	TH_REQUIRE(WIFSIGNALED(wait_status),
		"the child must die from a signal, not exit normally (status=", wait_status, ')');
	TH_REQUIRE_EQ(WTERMSIG(wait_status), SIGKILL, "the child must be killed by SIGKILL");
	log_info("child terminated by SIGKILL as expected");

	// --- phase 2: nothing durable may be missing after the crash ------------
	TH_REQUIRE(fs::exists(layout.registry), "registry must survive the crash");
	TH_REQUIRE(fs::exists(layout.session_state), "session state must survive the crash");
	TH_REQUIRE(fs::exists(layout.resume), "resume data must survive the crash");
	TH_REQUIRE(fs::exists(layout.torrent_file), "torrent metadata must survive the crash");
	// A half-written generation would show up as a leftover .tmp file.
	for (const fs::directory_entry& entry : fs::directory_iterator(layout.state)) {
		TH_REQUIRE(entry.path().extension() != ".tmp",
			"a partially written state file survived the crash: ", entry.path().string());
	}

	const std::vector<RegistryEntry> registry = read_registry(layout.registry);
	TH_REQUIRE_EQ(registry.size(), std::size_t{1}, "registry must contain exactly one torrent");
	const RegistryEntry& record = registry.front();

	// Recomputing the metadata from the (partial) source proves the identity in
	// the registry is the identity of the data still on disk.
	const CreatedTorrent rebuilt = rebuild_torrent(layout.source, spec);
	TH_REQUIRE_EQ(record.id, torrent_id(rebuilt.hashes), "registry id must match the payload");

	// --- phase 3: restore ---------------------------------------------------
	const lt::session_params restored_params = lt::read_session_params(read_file(layout.session_state));
	Session session(lt::session_params(restored_params), "crash-parent");
	session.listen_port(ctx.step_timeout);

	lt::error_code ec;
	lt::add_torrent_params resumed = lt::read_resume_data(read_file(layout.resume), ec);
	TH_REQUIRE(!ec, cat("resume data written before the crash is unreadable: ", ec.message()));
	apply_deterministic_flags(resumed);
	if (!resumed.ti) {
		// Magnet-style resume data keeps no info dict; fall back to the .torrent
		// exactly as the agent would when rebuilding its registry.
		resumed.ti = lt::load_torrent_buffer(read_file(layout.torrent_file)).ti;
	}

	const lt::torrent_handle handle = add_torrent(session, std::move(resumed), ctx.step_timeout);
	const lt::torrent_status status = wait_until_checked(session, handle, ctx.step_timeout);

	TH_REQUIRE_EQ(status.total_done, record.total_done,
		"restore must not lose a single verified byte of partial data");
	TH_REQUIRE_EQ(status.total_wanted, record.total_size, "restore must keep the torrent size");
	TH_REQUIRE_EQ(torrent_id(handle.info_hashes()), record.id, "restore must keep the identity");
	TH_REQUIRE_EQ(status.save_path, record.save_path, "restore must keep the save path");
	log_info(cat("restored ", status.total_done, "/", status.total_wanted,
		" bytes after kill -9 (id=", record.id, ')'));

	session.shutdown();
}

} // namespace torrentino::harness
