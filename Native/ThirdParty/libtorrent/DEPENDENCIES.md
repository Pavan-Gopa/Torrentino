# libtorrent dependency lock — WP-01

Authoritative record of what the engine is built from. Machine-readable pins
live in [`../versions.lock`](../versions.lock); `build.sh` refuses to build
anything whose SHA-256 does not match them.

Verified on: macOS 26.5 (25F84), Apple M-series (arm64), Xcode 26.6
(Apple clang 21.0.0), CMake 4.4.0, 2026-08-01. Pins refreshed to the
2026-08-10 hardening releases under SEC-2 (WP-13) and rebuilt 2026-08-22
(Xcode 26.6 / Apple clang 21.0.0 clang-2100.1.1.101, CMake 4.4.2, SDK 26.5 —
see `.build/manifest-*.json`).

## 1. Engine — libtorrent

| Field | Primary | Fallback candidate |
|---|---|---|
| Version | **2.1.1** | 2.0.14 |
| Tag | `v2.1.1` | `v2.0.14` |
| Commit | `56ae8caba38bf154ffc210403cb23f91d0ecaa49` | `aab2a10e2f60d9eac78e885a696736d043527794` |
| Released | 2026-08-10 | 2026-08-10 |
| Branch | `RC_2_1` | `RC_2_0` (maintenance) |
| Archive | `libtorrent-rasterbar-2.1.1.tar.gz` | `libtorrent-rasterbar-2.0.14.tar.gz` |
| SHA-256 | `0f163516ecef2e3331500266751de3098835a3c3ae0c2290448046c632bc0e93` | `1b0b21b9755b5fbec23ca9ba2d2d10434ecb6711c39f37f5fc9d5aa25cf369c9` |
| License | BSD-3-Clause | BSD-3-Clause |
| Source | <https://github.com/arvidn/libtorrent/releases> | same |

Hashes were cross-checked against the `digest` field GitHub publishes for the
release assets, not only computed locally.

**Why 2.1.1 is the primary.** It is the newest stable 2.x release and the branch
upstream develops on. **Why 2.0.14 stays pinned.** It is the maintenance branch
most other clients ship; the harness builds and passes against both, so a
regression in 2.1.x can be answered by flipping `LT_DEFAULT_VERSION` instead of
by an emergency port. **SEC-2 (WP-13).** Both pins were moved up one release
(2.1.0→2.1.1, 2.0.13→2.0.14) to pick up upstream's un-CVE'd memory-safety
hardening (DHT canonical-string salt limit, i2p SAM stack buffer, merkle tree
validation); same hardening delta on both branches.

Bakeoff result (same harness, same machine; sizes below are the shipped
static archives of the refreshed prefixes):

| | 2.1.1 | 2.0.14 |
|---|---|---|
| Builds arm64 static | yes | yes |
| `libtorrent-rasterbar.a` | 17 112 744 B | 15 971 200 B |
| API delta handled | `create_torrent(std::vector<create_file_entry>)` | `create_torrent(file_storage&)` |

The only version-dependent code in the whole harness is guarded by
`LIBTORRENT_VERSION_NUM` in `torrent_factory.cpp`.

## 2. Boost

| Field | Value |
|---|---|
| Version | 1.91.0 (released 2026-04-15) |
| Commit | `1a80576db6b70828803819fb6925132193bc5d0e` |
| Archive | `boost_1_91_0.tar.bz2` |
| SHA-256 | `de5e6b0e4913395c6bdfa90537febd9028ea4c0735d2cdb0cd9b45d5f51264f5` |
| License | BSL-1.0 |
| Source | <https://archives.boost.io/release/1.91.0/source/> |
| Usage | **headers only** (Asio, System, Config, Pool, CRC, …) |

Boost.System has been header-only since 1.69, and libtorrent 2.x links no
compiled Boost library, so `build.sh` installs the header tree and never runs
`b2`. That also sidesteps a real blocker: `bootstrap.sh` writes an unquoted
`--prefix` into `project-config.jam` and cannot bootstrap from a path containing
a space (this repository lives in `.../AI Projects/...`).

## 3. OpenSSL

| Field | Value |
|---|---|
| Version | 3.5.7 (LTS branch, supported until 2030-04-08) |
| Tag | `openssl-3.5.7` |
| Archive | `openssl-3.5.7.tar.gz` |
| SHA-256 | `a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8` |
| License | Apache-2.0 |
| Source | <https://github.com/openssl/openssl/releases> |
| Usage | static `libssl.a` + `libcrypto.a`, HTTPS trackers and SSL torrents |

Configured with `no-shared no-legacy no-apps no-docs no-tests`. `no-legacy`
matters: the legacy provider is the only artifact OpenSSL installs as a
`.dylib`, and libtorrent never calls EVP ciphers (it hashes through libcrypto
and implements MSE itself), so dropping it keeps the prefix 100 % static.

macOS ships no usable OpenSSL headers — `/usr/lib/libcrypto.dylib` is a private
LibreSSL fork with no public headers and is explicitly not for third-party use.
Building our own is therefore the only self-contained option.

## 4. Build-time tools (developer machine only — never shipped)

| Tool | Required | Verified with |
|---|---|---|
| macOS | 13.0+ | 26.5 |
| Xcode / Command Line Tools | 14+ | Xcode 26.6, Apple clang 21.0.0 |
| CMake | ≥ 3.20 (libtorrent 2.1 requires it) | 4.4.0 |
| Ninja | optional (Make is the fallback) | 1.13 |
| Perl | system `/usr/bin/perl` (OpenSSL Configure) | 5.x |

CMake and Ninja may come from Homebrew: they run at build time only. What is
forbidden is a Homebrew artifact ending up **inside** a produced binary, which
`build.sh` and `scripts/verify_no_homebrew.sh` both check.

## 5. Build configuration

`bash Native/ThirdParty/libtorrent/build.sh [--flavor release|asan] [--lt-version X]`

Output prefix: `Native/ThirdParty/.build/prefix/libtorrent-<version>-<flavor>/`
(git-ignored; fully reproducible from the pins above).

Feature flags chosen for v1 and the reason each one is set:

| Flag | Value | Why |
|---|---|---|
| `BUILD_SHARED_LIBS` | OFF | one static archive, nothing to ship next to the app |
| `CMAKE_OSX_ARCHITECTURES` | `arm64` | Apple Silicon only target |
| `CMAKE_OSX_DEPLOYMENT_TARGET` | `13.0` | product minimum |
| `CMAKE_CXX_STANDARD` | 17 | libtorrent 2.x baseline |
| `dht`, `encryption`, `exceptions`, `logging` | ON | required product features / diagnosability |
| `deprecated-functions` | ON (`TORRENT_ABI_VERSION=2`) | keeps the library on its best-tested configuration; new code is still kept clean because the harness compiles with `-Werror=deprecated-declarations` |
| `i2p` | OFF | not a v1 feature, smaller attack surface |
| `webtorrent` (2.1 only) | OFF | would pull in libdatachannel (MPL-2.0) + a WebRTC stack |
| `build_tests/examples/tools`, `python-bindings` | OFF | not shipped |
| `CMAKE_IGNORE_PREFIX_PATH` | `/opt/homebrew;/usr/local` | hard guard against picking up a system Boost/OpenSSL |
| `CMAKE_POLICY_DEFAULT_CMP0167` | OLD | keeps the `FindBoost` module, which supports our header-only Boost layout |

## 6. Verification evidence

WP-01 original bakeoff (2026-08-01, pins 2.1.0/2.0.13): 11/11 harness
scenarios on both, ASan+UBSan flavor of the 2.1.x build with zero sanitizer
reports; harness `otool -L` showed only system frameworks/libc++/libSystem
(no /opt/homebrew, no /usr/local, no rpath).

SEC-2 pin refresh (2026-08-22, pins 2.1.1/2.0.14): both release prefixes were
rebuilt clean from lock-verified archives —
`bash Native/ThirdParty/libtorrent/build.sh --flavor release` verified
`libtorrent-rasterbar-2.1.1.tar.gz` (sha256 `0f163516…`) and
`libtorrent-rasterbar-2.0.14.tar.gz` (sha256 `1b0b21b9…`) against
`versions.lock` before compiling (a mismatch is a hard failure), passed the
arm64/min-os artifact verification, and recorded
`.build/manifest-2.1.1-release.json` / `.build/manifest-2.0.14-release.json`.
Per §8, a refreshed pin adoption re-runs the harness scenario suites before
release sign-off.

## 7. Upstream sharp edges found during the bakeoff

1. **`session_proxy` must be destroyed, not assigned over.** Only
   `~session_proxy()` joins libtorrent's network thread; move-assigning over a
   live proxy destroys a still-joinable `std::thread` and aborts the process.
   Clean shutdown therefore has to let the proxy leave scope
   (`Session::shutdown()` in the harness). WP-04 must keep this shape.
2. **Default `add_torrent_params::flags` contain `paused` *and* `auto_managed`.**
   A torrent added as-is never starts its hash check. The engine owns desired
   state, so both flags are cleared explicitly (`apply_deterministic_flags`).
3. **libtorrent 2.1 changed torrent creation.** `create_torrent(file_storage&)`
   and `add_files()` are deprecated in favour of `list_files()` +
   `create_torrent(std::vector<create_file_entry>)`. Isolated behind one
   `#if LIBTORRENT_VERSION_NUM >= 20100` block.

## 8. Updating a pin

1. Edit `../versions.lock` (tag, commit, archive, SHA-256 published upstream).
2. Re-run `build.sh` for both flavors — a hash mismatch is a hard failure.
3. Re-run `scripts/run_tests.sh`, `scripts/run_sanitizers.sh` and a soak.
4. Update this file, `../LICENSES.md` and the numbers in §6.
