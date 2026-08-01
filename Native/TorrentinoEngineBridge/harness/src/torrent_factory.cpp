// Torrentino engine harness — deterministic torrent factory (WP-01).
// See torrent_factory.hpp for the role of this module.
#include "torrentino/harness/torrent_factory.hpp"

#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/version.hpp>

#if LIBTORRENT_VERSION_NUM < 20100
#include <libtorrent/file_storage.hpp>
#endif

namespace torrentino::harness {
namespace {

lt::create_flags_t protocol_flags(Protocol protocol) noexcept
{
	switch (protocol) {
	case Protocol::v1: return lt::create_torrent::v1_only;
	case Protocol::v2: return lt::create_torrent::v2_only;
	case Protocol::hybrid: break; // hybrid is the default: both hash trees
	}
	return {};
}

CreatedTorrent build(const fs::path& content_root, const TorrentSpec& spec, bool generate_payload)
{
	const fs::path payload = content_root / spec.name;
	if (generate_payload) {
		write_deterministic_file(payload, spec.seed, spec.size);
	}
	if (!fs::exists(payload)) {
		throw std::runtime_error(cat("payload missing: ", payload.string()));
	}

	// The only version-dependent code in the harness. libtorrent 2.1 replaced the
	// mutable file_storage builder with an explicit create_file_entry list; both
	// paths must stay compilable while the bakeoff compares 2.0.x and 2.1.x.
#if LIBTORRENT_VERSION_NUM >= 20100
	std::vector<lt::create_file_entry> entries = lt::list_files(payload.string());
	lt::create_torrent creator(std::move(entries), spec.piece_size, protocol_flags(spec.protocol));
#else
	lt::file_storage storage;
	lt::add_files(storage, payload.string());
	lt::create_torrent creator(storage, spec.piece_size, protocol_flags(spec.protocol));
#endif
	creator.set_creator("Torrentino harness (WP-01)");

	lt::error_code ec;
	// Hashing reads the payload relative to the parent of the torrent root, which
	// is why content_root — not payload — is passed here.
	lt::set_piece_hashes(creator, content_root.string(), ec);
	if (ec) {
		throw lt::system_error(ec);
	}

	CreatedTorrent result;
	result.bencoded = creator.generate_buf();
	// Parse the freshly generated metadata instead of trusting the builder: this
	// is also a round-trip check that what we write can be read back.
	const lt::add_torrent_params parsed = lt::load_torrent_buffer(result.bencoded);
	if (!parsed.ti) {
		throw std::runtime_error("generated torrent could not be parsed back");
	}
	result.hashes = parsed.ti->info_hashes();
	result.name = parsed.ti->name();
	result.total_size = parsed.ti->total_size();
	result.piece_size = parsed.ti->piece_length();
	result.num_pieces = parsed.ti->num_pieces();
	result.content_root = content_root;
	result.payload_path = payload;
	result.payload_sha256 = sha256_file_hex(payload);
	return result;
}

} // namespace

const char* protocol_name(Protocol protocol) noexcept
{
	switch (protocol) {
	case Protocol::v1: return "v1";
	case Protocol::v2: return "v2";
	case Protocol::hybrid: return "hybrid";
	}
	return "unknown";
}

CreatedTorrent create_payload_torrent(const fs::path& content_root, const TorrentSpec& spec)
{
	std::error_code ec;
	fs::create_directories(content_root, ec);
	return build(content_root, spec, /*generate_payload=*/true);
}

CreatedTorrent rebuild_torrent(const fs::path& content_root, const TorrentSpec& spec)
{
	return build(content_root, spec, /*generate_payload=*/false);
}

fs::path write_torrent_file(const CreatedTorrent& torrent, const fs::path& directory)
{
	std::error_code ec;
	fs::create_directories(directory, ec);
	const fs::path path = directory / (torrent.name + ".torrent");
	write_file_atomic(path, torrent.bencoded);
	return path;
}

} // namespace torrentino::harness
