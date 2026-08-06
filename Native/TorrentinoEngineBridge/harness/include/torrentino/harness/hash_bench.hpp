// Torrentino engine harness — WP-12 hashing benchmark + independent verifier.
//
// Role:     the §12.5 "libtorrent CPU baseline" measurement row and the §12.7
//           independent BEP validator. `bench-hash` times lt::set_piece_hashes
//           over a corpus and prints CSV rows matching the TorrentinoHashingBench
//           schema (backend=libtorrent). `verify-torrent` loads a .torrent
//           produced by the Swift bench and cross-checks every hash with a
//           freshly computed libtorrent build of the same corpus. `gen-corpus`
//           writes deterministic payloads (splitmix64) so all runs are
//           reproducible.
// Must not: modify the corpus, link anything outside the pinned prefix, or
//           depend on sudo (pmset is queried read-only for thermal evidence).
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace torrentino::harness {

namespace fs = std::filesystem;

struct HashBenchOptions {
	fs::path payload_parent; // directory that contains the corpus (torrent root)
	std::string corpus_name; // corpus dir/file inside payload_parent
	int piece_kib = 1024;
	std::string protocol = "hybrid"; // v1|v2|hybrid
	int reps = 10;
};

struct VerifyTorrentOptions {
	fs::path torrent_file;
	fs::path payload_parent;
	std::string corpus_name;
};

struct GenCorpusOptions {
	fs::path path;
	std::int64_t size = 0;
	std::uint64_t seed = 0x7071;
};

int run_hash_bench(const HashBenchOptions& options);
int run_verify_torrent(const VerifyTorrentOptions& options);
int run_gen_corpus(const GenCorpusOptions& options);

} // namespace torrentino::harness
