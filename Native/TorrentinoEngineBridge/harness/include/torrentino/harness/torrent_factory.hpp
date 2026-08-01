// Torrentino engine harness — deterministic torrent factory (WP-01).
//
// Role:     builds v1 / v2 / hybrid torrents from generated payloads and is the
//           single place that knows how torrent creation differs between
//           libtorrent 2.0.x (file_storage) and 2.1.x (create_file_entry).
// Must not: depend on network or on any pre-existing fixture file — every byte
//           is generated from a seed so runs are reproducible.
#pragma once

#include "torrentino/harness/support.hpp"

#include <libtorrent/info_hash.hpp>

#include <cstdint>
#include <string>
#include <vector>

namespace torrentino::harness {

namespace lt = libtorrent;

// BitTorrent protocol variant of a generated torrent.
enum class Protocol { v1, v2, hybrid };

const char* protocol_name(Protocol protocol) noexcept;

struct TorrentSpec {
	std::string name = "payload.bin";
	std::int64_t size = 4 * 1024 * 1024;
	// v2 requires a power-of-two piece size of at least 16 KiB.
	int piece_size = 64 * 1024;
	std::uint64_t seed = 0x7071ULL;
	Protocol protocol = Protocol::hybrid;
};

struct CreatedTorrent {
	std::vector<char> bencoded;   // contents of the .torrent file
	lt::info_hash_t hashes;
	std::string name;
	std::int64_t total_size{0};
	int piece_size{0};
	int num_pieces{0};
	fs::path content_root;        // directory to use as save_path
	fs::path payload_path;        // content_root / name
	std::string payload_sha256;   // digest of the generated payload
};

// Generates the payload inside `content_root` and returns the built torrent.
CreatedTorrent create_payload_torrent(const fs::path& content_root, const TorrentSpec& spec);

// Rebuilds the torrent metadata for an existing payload (same bytes on disk).
// Used by the crash-restore child/parent pair, which must agree on the info hash
// without shipping the .torrent between them.
CreatedTorrent rebuild_torrent(const fs::path& content_root, const TorrentSpec& spec);

// Writes the .torrent to disk and returns its path.
fs::path write_torrent_file(const CreatedTorrent& torrent, const fs::path& directory);

} // namespace torrentino::harness
