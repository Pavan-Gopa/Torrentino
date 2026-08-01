# Third-party licenses — Torrentino (WP-01 draft SBOM)

Everything Torrentino links is listed here. Exact versions and hashes:
[`versions.lock`](versions.lock) and
[`libtorrent/DEPENDENCIES.md`](libtorrent/DEPENDENCIES.md).

Status: draft for WP-01. The shipped `Credits`/`Acknowledgements` panel and the
release SBOM are produced from this file in a later WP.

## 1. Linked into the product

| Component | Version | License | SPDX | Linkage | Attribution required |
|---|---|---|---|---|---|
| libtorrent (rasterbar) | 2.1.0 | BSD 3-Clause | `BSD-3-Clause` | static | yes — copyright + disclaimer |
| Boost | 1.91.0 | Boost Software License 1.0 | `BSL-1.0` | headers only | no for binaries, yes for source redistribution |
| OpenSSL (libssl, libcrypto) | 3.5.7 | Apache License 2.0 | `Apache-2.0` | static | yes — license text + NOTICE |
| ed25519 (bundled in libtorrent `src/ed25519`) | as shipped in libtorrent 2.1.0 | public domain + zlib-style grant | `Zlib` | static, via libtorrent | courtesy attribution |
| try_signal (bundled in libtorrent `deps/try_signal`) | as shipped in libtorrent 2.1.0 | BSD 3-Clause | `BSD-3-Clause` | static, via libtorrent | yes |

All of these are permissive. None is copyleft, so static linking imposes no
source-disclosure obligation on Torrentino.

## 2. Present in a dependency's source tree but NOT built

Explicitly disabled so they never reach a shipped binary — this is why the
build flags in `DEPENDENCIES.md` §5 are part of the licensing story:

| Component | License | Why excluded |
|---|---|---|
| libdatachannel (+ plog, libjuice, usrsctp) — `deps/libdatachannel` | MPL-2.0 and others | WebTorrent support; disabled with `-Dwebtorrent=OFF` |
| asio-gnutls — `deps/asio-gnutls` | BSL-1.0 | GnuTLS backend; unused, we build against OpenSSL |
| libsimulator — `simulation/` | BSD-3-Clause | upstream test-only |
| OpenSSL legacy provider | Apache-2.0 | disabled with `no-legacy`; would be the only `.dylib` in the prefix |

If WebTorrent is ever enabled, MPL-2.0 obligations (source availability for
modified MPL files) must be reviewed **before** shipping.

## 3. Build-time only (never distributed)

CMake (BSD-3-Clause), Ninja (Apache-2.0), Xcode / Apple clang (Apple SLA),
Perl (Artistic/GPL, used by OpenSSL's `Configure`). These produce artifacts but
are not part of them, so they carry no distribution obligation.

## 4. System frameworks (dynamically linked, provided by macOS)

`CoreFoundation`, `SystemConfiguration`, `libc++`, `libSystem` — Apple platform
libraries, used under the macOS SDK terms. This is the complete dynamic
dependency set of the engine binaries:

```
$ otool -L torrentino-harness
    /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
    /System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration
    /usr/lib/libc++.1.dylib
    /usr/lib/libSystem.B.dylib
```

No `/opt/homebrew`, no `/usr/local`, no `@rpath` entries: the product runs on a
clean macOS 13+ machine with no developer tools installed.

## 5. License texts

Full texts live in the pinned source archives and are re-fetched byte-identically
by `libtorrent/build.sh`:

| Component | Path inside the archive |
|---|---|
| libtorrent | `LICENSE`, `COPYING` |
| ed25519 | `src/ed25519/LICENSE` |
| try_signal | `deps/try_signal/LICENSE` |
| Boost | `LICENSE_1_0.txt` |
| OpenSSL | `LICENSE.txt` (Apache-2.0) |

Copies must be bundled into `Torrentino.app/Contents/Resources/Licenses/` when
the .dmg is assembled (packaging WP).

## 6. Obligations checklist for the release

- [ ] BSD-3-Clause (libtorrent, try_signal): reproduce copyright notice, the
      condition list and the disclaimer in the app's Acknowledgements.
- [ ] Apache-2.0 (OpenSSL): include the license text and any `NOTICE` content.
- [ ] BSL-1.0 (Boost): include the license text if source is redistributed.
- [ ] No GPL/LGPL/MPL component is linked (verify again on every pin bump).
- [ ] Regenerate this file whenever `versions.lock` changes.
