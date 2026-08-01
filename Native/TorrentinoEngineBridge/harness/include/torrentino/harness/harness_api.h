/*
 * Torrentino engine harness — C ABI boundary (WP-01).
 *
 * Role:     the single entry point of the harness process. It models the
 *           boundary that the ObjC++ PIMPL facade will have in WP-04: a plain
 *           C signature, integer status codes, no C++ types and — critically —
 *           no exception may propagate through it.
 * Contract: returns 0 on success, a torrentino_harness_status value otherwise.
 *           Never throws, never terminates on a C++ exception raised below it.
 */
#ifndef TORRENTINO_HARNESS_API_H
#define TORRENTINO_HARNESS_API_H

#ifdef __cplusplus
extern "C" {
#endif

/* Keep in sync with torrentino::harness::Status in support.hpp. */
enum torrentino_harness_status {
	TORRENTINO_HARNESS_OK = 0,
	TORRENTINO_HARNESS_ASSERTION_FAILED = 1,
	TORRENTINO_HARNESS_LIBTORRENT_ERROR = 2,
	TORRENTINO_HARNESS_STD_EXCEPTION = 3,
	TORRENTINO_HARNESS_UNKNOWN_EXCEPTION = 4,
	TORRENTINO_HARNESS_TIMEOUT = 5,
	TORRENTINO_HARNESS_USAGE_ERROR = 6,
	TORRENTINO_HARNESS_IO_ERROR = 7
};

/*
 * Runs the harness command line. Exception firewall: every C++ exception
 * raised by libtorrent or by scenario code is caught here and translated into
 * a status code, exactly like the future bridge will translate into a Swift
 * error DTO.
 */
int torrentino_harness_main(int argc, char *const argv[]);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* TORRENTINO_HARNESS_API_H */
