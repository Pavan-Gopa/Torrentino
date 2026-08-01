// Torrentino engine harness — core engine scenarios (WP-01).
//
// Role: proves the engine primitives the product depends on: session lifecycle,
//       torrent creation for all three protocol variants, adding by file and by
//       magnet, identity recognition, pause/resume and a real loopback transfer.
// Must not: reach the public network — every peer is an explicit 127.0.0.1
//       endpoint and DHT/LSD/PMP are off.
#include "torrentino/harness/engine_ops.hpp"
#include "torrentino/harness/scenario.hpp"

#include <libtorrent/address.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_info.hpp>

#include <array>
#include <memory>

namespace torrentino::harness {
namespace {

constexpr std::array<Protocol, 3> kProtocols{Protocol::v1, Protocol::v2, Protocol::hybrid};

SessionOptions options_for(std::string tag)
{
	SessionOptions options;
	options.tag = std::move(tag);
	return options;
}

} // namespace

void scenario_session_lifecycle(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "session-lifecycle", ctx.keep_workspace);
	const SessionOptions options = options_for("solo");
	Session session(make_session_params(options), options.tag);

	const int port = session.listen_port(ctx.step_timeout);
	TH_REQUIRE(port > 0, "session must bind an ephemeral loopback TCP port");
	log_info(cat("listening on 127.0.0.1:", port));

	// Clean shutdown is a product requirement (the agent must stop before macOS
	// logout kills it), so it is measured, not just performed.
	const Millis elapsed = session.shutdown(Millis{10000});
	log_info(cat("clean shutdown in ", format_duration(elapsed)));
	for (const std::string& error : session.errors()) {
		log_warn(cat("alert: ", error));
	}
}

void scenario_torrent_creation(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "torrent-creation", ctx.keep_workspace);

	for (Protocol protocol : kProtocols) {
		TorrentSpec spec;
		spec.protocol = protocol;
		spec.name = cat("payload-", protocol_name(protocol), ".bin");
		spec.size = 1 * 1024 * 1024;
		spec.piece_size = 64 * 1024;

		const fs::path content = workspace.dir(cat("content-", protocol_name(protocol)));
		const CreatedTorrent torrent = create_payload_torrent(content, spec);

		TH_REQUIRE_EQ(torrent.total_size, spec.size, protocol_name(protocol), ": total size");
		TH_REQUIRE_EQ(torrent.piece_size, spec.piece_size, protocol_name(protocol), ": piece size");
		TH_REQUIRE(torrent.num_pieces == spec.size / spec.piece_size, protocol_name(protocol),
			": unexpected piece count ", torrent.num_pieces);

		switch (protocol) {
		case Protocol::v1:
			TH_REQUIRE(torrent.hashes.has_v1() && !torrent.hashes.has_v2(),
				"v1-only torrent must carry a v1 hash and no v2 hash");
			break;
		case Protocol::v2:
			TH_REQUIRE(!torrent.hashes.has_v1() && torrent.hashes.has_v2(),
				"v2-only torrent must carry a v2 hash and no v1 hash");
			break;
		case Protocol::hybrid:
			TH_REQUIRE(torrent.hashes.has_v1() && torrent.hashes.has_v2(),
				"hybrid torrent must carry both hashes");
			break;
		}

		// Round-trip through a real .torrent file: this is what the UI will hand
		// to the agent, so parsing it back must reproduce the identity exactly.
		const fs::path file = write_torrent_file(torrent, workspace.dir("torrents"));
		const lt::add_torrent_params loaded = lt::load_torrent_file(file.string());
		TH_REQUIRE(static_cast<bool>(loaded.ti), "loading the written .torrent must yield metadata");
		TH_REQUIRE(loaded.ti->info_hashes() == torrent.hashes, protocol_name(protocol),
			": info hashes must survive a file round-trip");
		log_info(cat("created ", protocol_name(protocol), " torrent: ",
			describe_info_hashes(torrent.hashes), " pieces=", torrent.num_pieces));
	}
}

void scenario_add_torrent_file(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "add-torrent-file", ctx.keep_workspace);

	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.size = 4 * 1024 * 1024;
	const fs::path content = workspace.dir("content");
	const CreatedTorrent torrent = create_payload_torrent(content, spec);
	const fs::path file = write_torrent_file(torrent, workspace.dir("torrents"));

	const SessionOptions options = options_for("adder");
	Session session(make_session_params(options), options.tag);

	// Load exactly the way the app will: from a file on disk, not from memory.
	lt::add_torrent_params atp = lt::load_torrent_file(file.string());
	atp.save_path = content.string();
	apply_deterministic_flags(atp);

	const lt::torrent_handle handle = add_torrent(session, std::move(atp), ctx.step_timeout);
	const lt::torrent_status status = wait_until_seeding(session, handle, ctx.step_timeout);

	TH_REQUIRE_EQ(status.name, torrent.name, "added torrent name");
	TH_REQUIRE_EQ(status.total_wanted, torrent.total_size, "added torrent size");
	TH_REQUIRE(handle.info_hashes() == torrent.hashes, "handle must report the created hashes");
	TH_REQUIRE_EQ(status.total_done, torrent.total_size,
		"an already-complete payload must verify as complete after the hash check");
	log_info(cat("added from file, verified ", status.total_done, " bytes"));

	session.shutdown();
}

void scenario_info_hash_recognition(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "info-hash-recognition", ctx.keep_workspace);
	const SessionOptions options = options_for("ids");
	Session session(make_session_params(options), options.tag);

	for (Protocol protocol : kProtocols) {
		TorrentSpec spec;
		spec.protocol = protocol;
		spec.name = cat("id-", protocol_name(protocol), ".bin");
		spec.size = 512 * 1024;
		spec.piece_size = 32 * 1024;
		const fs::path content = workspace.dir(cat("content-", protocol_name(protocol)));
		const CreatedTorrent torrent = create_payload_torrent(content, spec);

		const lt::add_torrent_params source = atp_for(torrent, content);
		const std::string magnet = lt::make_magnet_uri(source);
		TH_REQUIRE(!magnet.empty(), "magnet URI must be produced for ", protocol_name(protocol));

		// btih = v1 identity, btmh = v2 identity. A hybrid torrent advertises both
		// so that v1-only clients can still join the swarm.
		const bool has_btih = magnet.find("urn:btih:") != std::string::npos;
		const bool has_btmh = magnet.find("urn:btmh:") != std::string::npos;
		TH_REQUIRE_EQ(has_btih, torrent.hashes.has_v1(), protocol_name(protocol), ": btih presence");
		TH_REQUIRE_EQ(has_btmh, torrent.hashes.has_v2(), protocol_name(protocol), ": btmh presence");

		const lt::add_torrent_params parsed = lt::parse_magnet_uri(magnet);
		TH_REQUIRE(parsed.info_hashes == torrent.hashes, protocol_name(protocol),
			": magnet round-trip must preserve the identity");

		// Registry id: v1 hex for v1/hybrid, v2 hex for v2-only.
		const std::string id = torrent_id(torrent.hashes);
		TH_REQUIRE_EQ(id.size(), protocol == Protocol::v2 ? std::size_t{64} : std::size_t{40},
			protocol_name(protocol), ": unexpected id length");

		// A magnet-only torrent must be recognised by the session before any
		// metadata exists — that is how the UI can show a row immediately.
		lt::add_torrent_params pending = lt::parse_magnet_uri(magnet);
		pending.save_path = workspace.dir("pending").string();
		apply_deterministic_flags(pending);
		const lt::torrent_handle handle = add_torrent(session, std::move(pending), ctx.step_timeout);
		TH_REQUIRE(handle.info_hashes() == torrent.hashes, protocol_name(protocol),
			": magnet-added handle must expose the same identity");
		TH_REQUIRE(!handle.status().has_metadata, "a magnet without peers must have no metadata");
		remove_torrent_keep_files(session, handle, ctx.step_timeout);
		log_info(cat(protocol_name(protocol), " id=", id, " (",
			describe_info_hashes(torrent.hashes), ')'));
	}

	session.shutdown();
}

void scenario_pause_resume(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "pause-resume", ctx.keep_workspace);

	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.size = 2 * 1024 * 1024;
	const fs::path content = workspace.dir("content");
	const CreatedTorrent torrent = create_payload_torrent(content, spec);

	const SessionOptions options = options_for("pauser");
	Session session(make_session_params(options), options.tag);
	const lt::torrent_handle handle
		= add_torrent(session, atp_for(torrent, content), ctx.step_timeout);
	wait_until_seeding(session, handle, ctx.step_timeout);

	auto paused = [](const lt::torrent_status& status) {
		return (status.flags & lt::torrent_flags::paused) != lt::torrent_flags_t{};
	};

	handle.pause(lt::torrent_handle::graceful_pause);
	session.wait_for_status(handle, ctx.step_timeout, "torrent to report paused", paused);
	log_info("torrent paused");

	handle.resume();
	session.wait_for_status(handle, ctx.step_timeout, "torrent to report resumed",
		[&paused](const lt::torrent_status& status) { return !paused(status); });
	log_info("torrent resumed");

	// Session-wide pause is what the agent uses before a checkpoint or shutdown;
	// it must not be confused with the per-torrent flag above.
	session.raw().pause();
	session.pump();
	TH_REQUIRE(session.raw().is_paused(), "session must report itself paused");
	session.raw().resume();
	session.pump();
	TH_REQUIRE(!session.raw().is_paused(), "session must report itself resumed");

	// Still functional after the pause cycle.
	const lt::torrent_status status = wait_until_seeding(session, handle, ctx.step_timeout);
	TH_REQUIRE_EQ(status.total_done, torrent.total_size, "data must survive a pause cycle");

	session.shutdown();
}

void scenario_magnet_metadata(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "magnet-metadata", ctx.keep_workspace);

	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.size = 2 * 1024 * 1024;
	const fs::path seed_dir = workspace.dir("seed");
	const fs::path leech_dir = workspace.dir("leech");
	const CreatedTorrent torrent = create_payload_torrent(seed_dir, spec);

	LocalSwarm swarm(ctx.step_timeout);
	const lt::torrent_handle seed
		= add_torrent(swarm.seeder(), atp_for(torrent, seed_dir), ctx.step_timeout);
	wait_until_seeding(swarm.seeder(), seed, ctx.step_timeout);

	// Metadata must arrive over the ut_metadata extension from the local seed —
	// there is no tracker and no DHT in this harness.
	const std::string magnet = lt::make_magnet_uri(atp_for(torrent, seed_dir));
	const lt::torrent_handle leech = add_torrent(swarm.leecher(),
		magnet_atp(magnet, leech_dir, swarm.seeder_port()), ctx.step_timeout);
	TH_REQUIRE(!leech.status().has_metadata, "magnet must start without metadata");

	swarm.leecher().wait_for_alert(ctx.step_timeout, "metadata_received_alert",
		[&leech](const lt::alert& alert) {
			const auto* received = lt::alert_cast<lt::metadata_received_alert>(&alert);
			return received != nullptr && received->handle == leech;
		});

	const lt::torrent_status status = wait_until_metadata(swarm.leecher(), leech, ctx.step_timeout);
	TH_REQUIRE(status.has_metadata, "torrent must report metadata after the alert");
	const std::shared_ptr<const lt::torrent_info> info = leech.torrent_file();
	TH_REQUIRE(static_cast<bool>(info), "torrent_file() must be available after metadata");
	TH_REQUIRE(info->info_hashes() == torrent.hashes,
		"metadata fetched over the wire must match the source identity");
	TH_REQUIRE_EQ(info->total_size(), torrent.total_size, "metadata size");
	log_info(cat("magnet metadata received: ", describe_info_hashes(info->info_hashes())));

	swarm.shutdown();
}

void scenario_data_transfer(RunContext& ctx)
{
	Workspace workspace(ctx.workspace_root, "data-transfer", ctx.keep_workspace);

	TorrentSpec spec;
	spec.protocol = Protocol::hybrid;
	spec.size = 8 * 1024 * 1024;
	const fs::path seed_dir = workspace.dir("seed");
	const fs::path leech_dir = workspace.dir("leech");
	const CreatedTorrent torrent = create_payload_torrent(seed_dir, spec);

	LocalSwarm swarm(ctx.step_timeout);
	const lt::torrent_handle seed
		= add_torrent(swarm.seeder(), atp_for(torrent, seed_dir), ctx.step_timeout);
	wait_until_seeding(swarm.seeder(), seed, ctx.step_timeout);

	lt::add_torrent_params atp = atp_for(torrent, leech_dir);
	atp.peers.emplace_back(lt::make_address_v4("127.0.0.1"),
		static_cast<std::uint16_t>(swarm.seeder_port()));
	const lt::torrent_handle leech = add_torrent(swarm.leecher(), std::move(atp), ctx.step_timeout);

	const lt::torrent_status status = wait_until_finished(swarm.leecher(), leech, ctx.step_timeout);
	TH_REQUIRE_EQ(status.total_done, torrent.total_size, "the whole payload must be downloaded");

	// Byte-level proof: libtorrent's own accounting is not enough evidence for a
	// storage engine that we are about to trust with user data.
	const std::string downloaded = sha256_file_hex(leech_dir / torrent.name);
	TH_REQUIRE_EQ(downloaded, torrent.payload_sha256, "downloaded payload digest");
	log_info(cat("transferred ", torrent.total_size, " bytes, sha256 ", downloaded));

	swarm.shutdown();
}

} // namespace torrentino::harness
