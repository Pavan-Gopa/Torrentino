// Torrentino engine harness — WP-12 hashing benchmark + verifier implementation.
// See hash_bench.hpp for the role of this module.
#include "torrentino/harness/hash_bench.hpp"

#include "torrentino/harness/support.hpp"

#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/version.hpp>

#include <boost/utility/string_view.hpp>

#if LIBTORRENT_VERSION_NUM < 20100
#include <libtorrent/file_storage.hpp>
#endif

#include <sys/resource.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace torrentino::harness {
namespace {

lt::create_flags_t protocol_flags(const std::string& protocol)
{
	if (protocol == "v1") {
		return lt::create_torrent::v1_only;
	}
	if (protocol == "v2") {
		return lt::create_torrent::v2_only;
	}
	if (protocol != "hybrid") {
		throw AssertionFailure(cat("protocol must be v1|v2|hybrid, got: ", protocol));
	}
	return {}; // hybrid is the default: both hash trees
}

// create_torrent must not be moved after construction (2.0.x file_storage
// keeps internal offsets into itself), so it is always constructed in place
// and handed to the visitor by reference.
template <typename F>
void with_creator(const fs::path& corpus, int piece_size, const std::string& protocol, F&& visitor)
{
#if LIBTORRENT_VERSION_NUM >= 20100
	std::vector<lt::create_file_entry> entries = lt::list_files(corpus.string());
	lt::create_torrent creator(std::move(entries), piece_size, protocol_flags(protocol));
#else
	lt::file_storage storage;
	lt::add_files(storage, corpus.string());
	lt::create_torrent creator(storage, piece_size, protocol_flags(protocol));
#endif
	visitor(creator);
}

// Read-only thermal evidence (no sudo): pmset -g therm prints the current
// CPU_Speed_Limit percent. Returns "n/a" when the tool is unavailable and
// "100" when the system reports no CPU power status has been recorded
// (i.e. no limit observed). Note: the pmset path differs across macOS
// releases; probe both.
std::string cpu_speed_limit_percent()
{
	FILE* pipe = ::popen("/usr/bin/pmset -g therm 2>/dev/null || /usr/sbin/pmset -g therm 2>/dev/null", "r");
	if (pipe == nullptr) {
		return "n/a";
	}
	std::string out;
	char buffer[256];
	while (::fgets(buffer, static_cast<int>(sizeof(buffer)), pipe) != nullptr) {
		out += buffer;
	}
	::pclose(pipe);

	const std::string key = "CPU_Speed_Limit";
	const std::size_t pos = out.find(key);
	if (pos == std::string::npos) {
		if (out.find("No CPU power status") != std::string::npos) {
			return "100";
		}
		return "n/a";
	}
	const std::size_t eq = out.find('=', pos);
	if (eq == std::string::npos) {
		return "n/a";
	}
	std::size_t end = eq + 1;
	while (end < out.size() && (out[end] == ' ' || out[end] == '\t')) {
		++end;
	}
	const std::size_t start = end;
	while (end < out.size() && std::isdigit(static_cast<unsigned char>(out[end])) != 0) {
		++end;
	}
	if (start == end) {
		return "n/a";
	}
	return out.substr(start, end - start);
}

std::string sha256_hex(const lt::sha256_hash& hash)
{
	return lt::aux::to_hex(hash.to_string());
}

std::string sha1_hex(const lt::sha1_hash& hash)
{
	return lt::aux::to_hex(hash.to_string());
}

// Walks a bencoded torrent's "info"/"file tree" and returns, in tree order,
// the (size, pieces root) pairs of every file that has a root. libtorrent's
// own bdecode is the independent parser here (vs the Swift writer).
std::vector<std::pair<std::int64_t, lt::sha256_hash>> file_roots(const std::vector<char>& bytes)
{
	std::vector<std::pair<std::int64_t, lt::sha256_hash>> roots;
	lt::error_code ec;
	const lt::bdecode_node root = lt::bdecode(lt::span<char const>(bytes.data(), static_cast<std::ptrdiff_t>(bytes.size())), ec);
	if (ec || root.type() != lt::bdecode_node::dict_t) {
		return roots;
	}
	const lt::bdecode_node info = root.dict_find("info");
	if (info.type() != lt::bdecode_node::dict_t) {
		return roots;
	}
	const lt::bdecode_node tree = info.dict_find("file tree");
	if (tree.type() != lt::bdecode_node::dict_t) {
		return roots;
	}
	std::function<void(const lt::bdecode_node&)> walk = [&](const lt::bdecode_node& node) {
		for (int i = 0; i < node.dict_size(); ++i) {
			const lt::bdecode_node value = node.dict_at(i).second;
			if (value.type() != lt::bdecode_node::dict_t) {
				continue;
			}
			const lt::bdecode_node empty = value.dict_find("");
			if (empty.type() == lt::bdecode_node::dict_t) {
				const lt::bdecode_node length_node = empty.dict_find_int("length");
				const std::int64_t length = length_node.type() == lt::bdecode_node::int_t
					? length_node.int_value()
					: 0;
				const lt::bdecode_node root_node = empty.dict_find("pieces root");
				if (root_node.type() == lt::bdecode_node::string_t && root_node.string_length() == 32) {
					lt::sha256_hash hash;
					std::memcpy(hash.data(), root_node.string_ptr(), 32);
					roots.emplace_back(length, hash);
				}
			}
			walk(value);
		}
	};
	walk(tree);
	return roots;
}

// Piece layer self-consistency over our bencode: every multi-block file must
// carry a well-formed layer entry and single-block files must not carry one.
struct LayerCheck {
	std::int64_t expected = 0;
	std::int64_t present = 0;
	bool ok = true;
	std::string detail;
};

LayerCheck check_piece_layers(const std::vector<char>& bytes)
{
	LayerCheck check;
	lt::error_code ec;
	const lt::bdecode_node root = lt::bdecode(lt::span<char const>(bytes.data(), static_cast<std::ptrdiff_t>(bytes.size())), ec);
	if (ec || root.type() != lt::bdecode_node::dict_t) {
		check.ok = false;
		check.detail = cat("bdecode failed: ", ec.message());
		return check;
	}
	const lt::bdecode_node info = root.dict_find("info");
	if (info.type() != lt::bdecode_node::dict_t) {
		check.ok = false;
		check.detail = "info dict missing";
		return check;
	}
	const lt::bdecode_node layers = root.dict_find("piece layers");
	if (layers.type() != lt::bdecode_node::dict_t) {
		check.ok = false;
		check.detail = "piece layers dict missing";
		return check;
	}
	const lt::bdecode_node length_node = info.dict_find_int("piece length");
	if (length_node.type() != lt::bdecode_node::int_t || length_node.int_value() <= 0) {
		check.ok = false;
		check.detail = "piece length missing";
		return check;
	}
	const std::int64_t piece_length = length_node.int_value();

	// BEP-52: a file carries a "piece layers" entry iff it spans more than one
	// piece; the entry is one hash per piece, and layer hashes covering only
	// padding are omitted.
	const std::vector<std::pair<std::int64_t, lt::sha256_hash>> files = file_roots(bytes);
	for (const auto& entry : files) {
		const std::int64_t pieces = (entry.first + piece_length - 1) / piece_length;
		const std::int64_t expected = pieces > 1 ? pieces : 0;
		check.expected += expected;
		const lt::bdecode_node layer = layers.dict_find(boost::string_view(reinterpret_cast<char const*>(entry.second.data()), 32));
		if (expected == 0) {
			if (layer.type() == lt::bdecode_node::string_t) {
				check.ok = false;
				check.detail = cat("unexpected layer for single-piece file: ", sha256_hex(entry.second));
			}
			continue;
		}
		if (layer.type() != lt::bdecode_node::string_t) {
			check.ok = false;
			check.detail = cat("missing layer for ", sha256_hex(entry.second), " (", entry.first, " bytes)");
			continue;
		}
		if (layer.string_length() != static_cast<int>(expected * 32)) {
			check.ok = false;
			check.detail = cat("layer length ", layer.string_length(), " != expected ", expected * 32,
				" for ", sha256_hex(entry.second));
			continue;
		}
		++check.present;
	}
	check.detail = cat("files=", files.size(), " layers_expected=", check.expected,
		" layers_present=", check.present);
	return check;
}

} // namespace

int run_hash_bench(const HashBenchOptions& options)
{
	if (options.payload_parent.empty() || options.corpus_name.empty()) {
		log_error("bench-hash requires --dir and --name");
		return static_cast<int>(Status::usage_error);
	}
	const fs::path corpus = options.payload_parent / options.corpus_name;
	if (!fs::is_directory(corpus)) {
		log_error(cat("bench-hash requires --name to be a directory inside --dir (corpus dir), got: ",
			corpus.string()));
		return static_cast<int>(Status::usage_error);
	}
	const int piece_size = options.piece_kib * 1024;

	std::int64_t total_bytes = 0;
	with_creator(corpus, piece_size, options.protocol, [&](lt::create_torrent& probe) {
		total_bytes = probe.total_size();
	});

	log_info(cat("bench-hash: corpus=", corpus.string(), " bytes=", total_bytes,
		" piece=", piece_size, " format=", options.protocol, " reps=", options.reps));

	std::cout << "run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,"
				 "cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s\n";
	for (int rep = 0; rep < options.reps; ++rep) {
		const std::string therm_before = cpu_speed_limit_percent();

		struct rusage usage_before {};
		struct rusage usage_after {};
		::getrusage(RUSAGE_SELF, &usage_before);
		const auto wall_before = Clock::now();

		lt::error_code ec;
		with_creator(corpus, piece_size, options.protocol, [&](lt::create_torrent& creator) {
			lt::set_piece_hashes(creator, options.payload_parent.string(), ec);
		});
		if (ec) {
			log_error(cat("set_piece_hashes failed: ", ec.message()));
			return static_cast<int>(Status::libtorrent_error);
		}

		const auto wall_after = Clock::now();
		::getrusage(RUSAGE_SELF, &usage_after);
		const std::string therm_after = cpu_speed_limit_percent();

		const double wall_s = std::chrono::duration<double>(wall_after - wall_before).count();
		const double cpu_s = (static_cast<double>(usage_after.ru_utime.tv_sec)
								 + static_cast<double>(usage_after.ru_stime.tv_sec)
								 - static_cast<double>(usage_before.ru_utime.tv_sec)
								 - static_cast<double>(usage_before.ru_stime.tv_sec))
			+ (static_cast<double>(usage_after.ru_utime.tv_usec)
				   + static_cast<double>(usage_after.ru_stime.tv_usec)
				   - static_cast<double>(usage_before.ru_utime.tv_usec)
				   - static_cast<double>(usage_before.ru_stime.tv_usec))
				/ 1000000.0;
		const double rss_mb = static_cast<double>(usage_after.ru_maxrss) / (1024.0 * 1024.0);
		const double mib_per_s = wall_s > 0.000001
			? (static_cast<double>(total_bytes) / (1024.0 * 1024.0)) / wall_s
			: 0.0;

		std::cout << rep << ',' << options.corpus_name << '/' << options.piece_kib << "KiB,libtorrent,"
				  << wall_s << ',' << cpu_s << ',' << rss_mb << ','
				  << therm_before << ',' << therm_after << ',' << therm_after << ",0,0,"
				  << total_bytes << ',' << mib_per_s << '\n';
	}
	std::cout.flush();
	return static_cast<int>(Status::ok);
}

int run_verify_torrent(const VerifyTorrentOptions& options)
{
	if (options.torrent_file.empty() || options.payload_parent.empty() || options.corpus_name.empty()) {
		log_error("verify-torrent requires --torrent, --dir and --name");
		return static_cast<int>(Status::usage_error);
	}

	lt::add_torrent_params loaded;
	try {
		loaded = lt::load_torrent_file(options.torrent_file.string());
	} catch (const lt::system_error& e) {
		log_error(cat("load_torrent_file failed: ", e.what()));
		return static_cast<int>(Status::libtorrent_error);
	}
	if (!loaded.ti) {
		log_error("loaded torrent has no torrent_info");
		return static_cast<int>(Status::libtorrent_error);
	}
	const std::shared_ptr<lt::torrent_info> ours = loaded.ti;

	const fs::path corpus = options.payload_parent / options.corpus_name;
	const std::string protocol = ours->info_hashes().has_v1() && ours->info_hashes().has_v2()
		? "hybrid"
		: (ours->info_hashes().has_v2() ? "v2" : "v1");
	lt::error_code recompute_ec;
	std::vector<char> expected_bytes;
	with_creator(corpus, ours->piece_length(), protocol, [&](lt::create_torrent& creator) {
		lt::set_piece_hashes(creator, options.payload_parent.string(), recompute_ec);
		if (!recompute_ec) {
			expected_bytes = creator.generate_buf();
		}
	});
	if (recompute_ec) {
		log_error(cat("expected recompute failed: ", recompute_ec.message()));
		return static_cast<int>(Status::libtorrent_error);
	}
	lt::add_torrent_params expected_loaded;
	try {
		expected_loaded = lt::load_torrent_buffer(lt::span<char const>(expected_bytes.data(), static_cast<std::ptrdiff_t>(expected_bytes.size())));
	} catch (const lt::system_error& e) {
		log_error(cat("expected torrent parse failed: ", e.what()));
		return static_cast<int>(Status::libtorrent_error);
	}
	if (!expected_loaded.ti) {
		log_error("expected torrent could not be parsed back");
		return static_cast<int>(Status::libtorrent_error);
	}
	const std::shared_ptr<lt::torrent_info> expected = expected_loaded.ti;

	bool ok = true;

	// Structural fields must agree exactly.
	const auto structure = [&]() {
		bool fine = true;
		fine &= ours->piece_length() == expected->piece_length();
		fine &= ours->total_size() == expected->total_size();
		fine &= ours->num_files() == expected->num_files();
		fine &= ours->num_pieces() == expected->num_pieces();
		return fine;
	}();
	ok &= structure;
	log_info(cat("verify-torrent: name=", ours->name(), " size=", ours->total_size(),
		" piece=", ours->piece_length(), " files=", ours->num_files(),
		" pieces=", ours->num_pieces(), " structure=", structure ? "match" : "MISMATCH"));

	// v2: per-file merkle roots (pieces root in the file tree) are
	// order-independent and must be byte-identical. NOTE: info_hashes().v2 is
	// the info-dict hash, not the merkle root, so the roots are read from the
	// bencoded file trees with libtorrent's own bdecode.
	if (ours->info_hashes().has_v2()) {
		std::ifstream ours_file(options.torrent_file.string(), std::ios::binary);
		const std::vector<char> ours_bytes((std::istreambuf_iterator<char>(ours_file)),
			std::istreambuf_iterator<char>());
		const std::vector<std::pair<std::int64_t, lt::sha256_hash>> ours_roots = file_roots(ours_bytes);
		const std::vector<std::pair<std::int64_t, lt::sha256_hash>> expected_roots = file_roots(expected_bytes);
		bool roots_ok = ours_roots.size() == expected_roots.size();
		if (roots_ok) {
			for (std::size_t i = 0; i < ours_roots.size(); ++i) {
				if (ours_roots[i] != expected_roots[i]) {
					roots_ok = false;
					log_error(cat("v2 root ", i, " mismatch: size ", ours_roots[i].first, " vs ",
						expected_roots[i].first, " root ", sha256_hex(ours_roots[i].second), " vs ",
						sha256_hex(expected_roots[i].second)));
				}
			}
		} else {
			log_error(cat("v2 file count mismatch: ours ", ours_roots.size(), " expected ",
				expected_roots.size()));
		}
		ok &= roots_ok;
		log_info(cat("v2: files=", ours_roots.size(), " match=", roots_ok ? "yes" : "NO"));
	}

	// v1: piece stream order follows file order, so byte comparison is only
	// meaningful for single-file torrents (our corpora are single-file).
	if (ours->info_hashes().has_v1() && ours->num_files() == 1) {
		bool pieces_ok = true;
		std::size_t compared = 0;
		for (lt::piece_index_t index : ours->piece_range()) {
			const lt::sha1_hash got = ours->hash_for_piece(index);
			const lt::sha1_hash want = expected->hash_for_piece(index);
			if (got != want) {
				pieces_ok = false;
				log_error(cat("v1 piece ", static_cast<int>(index), " mismatch: got ",
					sha1_hex(got), " want ", sha1_hex(want)));
			}
			++compared;
		}
		ok &= pieces_ok;
		log_info(cat("v1: pieces=", compared, " match=", pieces_ok ? "yes" : "NO"));
	} else if (ours->info_hashes().has_v1()) {
		log_info(cat("v1: skipped (multi-file torrent: ", ours->num_files(), " files)"));
	}

	// Piece layers: every multi-piece file must carry a well-formed layer entry
	// and single-piece files must not carry one. Entry CONTENT must also be
	// byte-identical to libtorrent's own computed layers.
	if (ours->info_hashes().has_v2()) {
		lt::error_code layers_ec;
		std::ifstream file(options.torrent_file.string(), std::ios::binary);
		std::vector<char> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
		const LayerCheck layers = check_piece_layers(bytes);
		ok &= layers.ok;
		log_info(cat("layers: ", layers.ok ? "match" : "MISMATCH", " (", layers.detail, ")"));

		const lt::bdecode_node ours_root = lt::bdecode(
			lt::span<char const>(bytes.data(), static_cast<std::ptrdiff_t>(bytes.size())), layers_ec);
		const lt::bdecode_node expected_root = lt::bdecode(
			lt::span<char const>(expected_bytes.data(), static_cast<std::ptrdiff_t>(expected_bytes.size())), layers_ec);
		if (ours_root.type() == lt::bdecode_node::dict_t
			&& expected_root.type() == lt::bdecode_node::dict_t) {
			const lt::bdecode_node ours_layers = ours_root.dict_find("piece layers");
			const lt::bdecode_node expected_layers = expected_root.dict_find("piece layers");
			bool content_ok = ours_layers.type() == lt::bdecode_node::dict_t
				&& expected_layers.type() == lt::bdecode_node::dict_t
				&& ours_layers.dict_size() == expected_layers.dict_size();
			if (content_ok) {
				for (int i = 0; i < ours_layers.dict_size() && content_ok; ++i) {
					const lt::bdecode_node our_entry = ours_layers.dict_at(i).second;
					const lt::bdecode_node want_entry = expected_layers.dict_find(ours_layers.dict_at(i).first);
					if (want_entry.type() != lt::bdecode_node::string_t
						|| our_entry.type() != lt::bdecode_node::string_t
						|| our_entry.string_length() != want_entry.string_length()
						|| std::memcmp(our_entry.string_ptr(), want_entry.string_ptr(),
							   static_cast<std::size_t>(our_entry.string_length())) != 0) {
						content_ok = false;
					}
				}
			}
			ok &= content_ok;
			log_info(cat("layer-content: ", content_ok ? "match" : "MISMATCH",
				" entries=", ours_layers.dict_size()));
		}
	}

	std::cout << "verify-torrent: " << (ok ? "PASS" : "FAIL") << " bits=" << ours->total_size()
			  << " pieces=" << ours->num_pieces() << " v2=" << ours->info_hashes().has_v2()
			  << " v1=" << ours->info_hashes().has_v1() << '\n';
	return ok ? static_cast<int>(Status::ok) : static_cast<int>(Status::assertion_failed);
}

int run_gen_corpus(const GenCorpusOptions& options)
{
	if (options.path.empty() || options.size < 0) {
		log_error("gen-corpus requires --path and --size");
		return static_cast<int>(Status::usage_error);
	}
	std::error_code ec;
	fs::create_directories(options.path.parent_path(), ec);
	write_deterministic_file(options.path, options.seed, options.size);
	log_info(cat("gen-corpus: wrote ", options.path.string(), " (", options.size, " bytes, seed ",
		options.seed, ')'));
	return static_cast<int>(Status::ok);
}

} // namespace torrentino::harness
